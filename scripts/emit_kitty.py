#!/usr/bin/env python3
"""emit_kitty.py -- wire-exact OpenTUI-compatible Kitty graphics emitter.

Single-file Python 3 stdlib implementation of the Kitty graphics protocol as
OpenTUI emits it from packages/native/src/terminal-image.zig and
kitty-transport.zig.

Default flow:
    probe (a=q, i=31337) -> transmit (a=t, f=24|32|100, q=2) -> CSI cursor
    move -> place (a=p, C=1, z=..) -> optional delete (a=d).

The probe is byte-identical to
    ansi.ANSI.kittyGraphicsQuery
    ESC _ G i=31337,s=1,v=1,a=q,t=d,f=24;AAAA ESC \\

Transmit control ordering follows terminal-image.zig exactly:
    PNG   a=t,f=100,i=ID,m=M,q=2
    RGB   a=t,f=24,s=W,v=H,i=ID,o=z?,m=M,q=2
    RGBA  a=t,f=32,s=W,v=H,i=ID,o=z?,m=M,q=2
Continuation chunks are only m=M,q=2 (OpenTUI does NOT repeat i=).

Chunking: by default this reproduces OpenTUI exactly - 3072 raw bytes per
APC, base64-encoded to at most 4096 characters (kitty's limit).  Use
--b64-chunking to split the base64 text every 3072 characters instead.

Exit codes: 0 success, 2 usage/validation, 1 I/O/encode/verify, 3 reply
timeout or mismatch.  No prompts ever.
"""

from __future__ import annotations

import argparse
import base64
import binascii
import hashlib
import json
import math
import os
import re
import select
import struct
import sys
import time
import zlib
from dataclasses import dataclass, field
from typing import Optional

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

ST = b"\x1b\\"
BEL = b"\x07"

PROBE_ID = 31337
PROBE_CONTROL = (
    ("i", "31337"),
    ("s", "1"),
    ("v", "1"),
    ("a", "q"),
    ("t", "d"),
    ("f", "24"),
)
PROBE_PAYLOAD_B64 = "AAAA"
# ansi.ANSI.kittyGraphicsQuery (packages/native/src/ansi.zig:352)
OPENTUI_PROBE_ST = b"\x1b_Gi=31337,s=1,v=1,a=q,t=d,f=24;AAAA\x1b\\"

CHUNK_B64 = 3072          # default: max base64 characters per APC
OPENTUI_CHUNK_RAW = 3072  # OpenTUI: raw payload bytes per APC (=> 4096 b64)
MAX_PAYLOAD = 64 * 1024 * 1024  # KITTY_PREPARE_BYTES_MAX
MAX_PIXELS = 16_000_000
INT32_MIN = -(2 ** 31)
INT32_MAX = 2 ** 31 - 1
KITTY_Z_BASE = -1073741824  # INT32_MIN / 2, see kittyPlacementZ()
OPENTUI_IMAGE_ID_MASK = 0x03FFFFFF
PNG_SIG = b"\x89PNG\r\n\x1a\n"

CSI_CURSOR_RE = re.compile(rb"\x1b\[(\d+);(\d+)H")


class UsageError(Exception):
    """Validation failure mapped to exit code 2."""


class EmitError(Exception):
    """I/O or encoding failure mapped to exit code 1."""


# ---------------------------------------------------------------------------
# Data model
# ---------------------------------------------------------------------------


@dataclass
class Record:
    """One wire element: an APC or a CSI cursor move."""

    kind: str
    control: tuple  # ordered (key, value) pairs, strings
    b64: str
    wire: bytes
    chunk_index: int = 0
    chunk_count: int = 1
    flow: int = 1


@dataclass
class Flow:
    index: int
    probe: Record
    transmit: list
    cursor: Optional[Record]
    placement: Optional[Record]
    delete: Optional[Record]

    def records(self):
        yield self.probe
        yield from self.transmit
        if self.cursor is not None:
            yield self.cursor
        if self.placement is not None:
            yield self.placement
        if self.delete is not None:
            yield self.delete


@dataclass
class Prepared:
    kind: str          # png | rgb | rgba
    fmt: int           # 100 | 24 | 32
    width: int
    height: int
    data: bytes        # image payload before optional compression
    wire: bytes        # bytes actually base64-encoded into the APCs
    compressed: bool
    notes: list = field(default_factory=list)


# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------


def control_string(control) -> str:
    return ",".join("%s=%s" % (k, v) for k, v in control)


def apc_bytes(control, payload_b64: str, term: bytes) -> bytes:
    body = control_string(control).encode("ascii")
    if payload_b64:
        body += b";" + payload_b64.encode("ascii")
    return b"\x1b_G" + body + term


def b64(data: bytes) -> str:
    return base64.b64encode(data).decode("ascii")


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def dim_type(text: str):
    m = re.fullmatch(r"([0-9]{1,6})x([0-9]{1,6})", text.strip())
    if not m:
        raise argparse.ArgumentTypeError("expected WxH (for example 40x20)")
    w, h = int(m.group(1)), int(m.group(2))
    if not (1 <= w <= 65535 and 1 <= h <= 65535):
        raise argparse.ArgumentTypeError("width and height must be in 1..65535")
    if w * h > MAX_PIXELS:
        raise argparse.ArgumentTypeError(
            "image too large: %dx%d exceeds %d pixels" % (w, h, MAX_PIXELS)
        )
    return (w, h)


def color_type(text: str):
    if not re.fullmatch(r"[0-9a-fA-F]{6}", text):
        raise argparse.ArgumentTypeError("expected RRGGBB hex (for example 3366cc)")
    return bytes.fromhex(text)


def src_type(text: str):
    parts = text.split(",")
    if len(parts) != 4:
        raise argparse.ArgumentTypeError("expected x,y,w,h")
    try:
        values = tuple(int(p, 10) for p in parts)
    except ValueError:
        raise argparse.ArgumentTypeError("expected four integers x,y,w,h")
    if any(v < 0 for v in values):
        raise argparse.ArgumentTypeError("x,y,w,h must be non-negative")
    if values[2] == 0 or values[3] == 0:
        raise argparse.ArgumentTypeError("w and h must be positive")
    return values


def png_chunk(tag: bytes, data: bytes) -> bytes:
    return (
        struct.pack(">I", len(data))
        + tag
        + data
        + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
    )


def make_png(width: int, height: int, rgb: bytes) -> bytes:
    """Deterministic 8-bit RGB PNG, no external dependencies."""

    ihdr = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    row = b"\x00" + rgb * width
    raw = row * height
    return (
        PNG_SIG
        + png_chunk(b"IHDR", ihdr)
        + png_chunk(b"IDAT", zlib.compress(raw, 9))
        + png_chunk(b"IEND", b"")
    )


def parse_png_size(data: bytes):
    if len(data) >= 24 and data.startswith(PNG_SIG) and data[12:16] == b"IHDR":
        w, h = struct.unpack(">II", data[16:24])
        return int(w), int(h)
    return None


# ---------------------------------------------------------------------------
# Payload preparation
# ---------------------------------------------------------------------------


def _compress_if_smaller(data: bytes, notes: list):
    """OpenTUI compresses only when the encoded payload actually shrinks."""
    comp = zlib.compress(data, 1)  # Zig flate .fastest
    if len(b64(comp)) + len(",o=z") < len(b64(data)):
        return comp, True
    notes.append("zlib payload did not shrink; OpenTUI parity: fall back to raw")
    return data, False


def prepare_payload(args) -> Prepared:
    notes = []
    path = args.file_path

    if path is not None:
        try:
            raw = open(path, "rb").read()
        except OSError as exc:
            raise EmitError("cannot read %s: %s" % (path, exc))
        if len(raw) > MAX_PAYLOAD:
            raise UsageError("file exceeds %d bytes" % MAX_PAYLOAD)
        if raw.startswith(PNG_SIG):
            if args.raw_rgb is not None or args.raw_rgba is not None:
                raise UsageError("PNG FILE does not take --raw-rgb/--raw-rgba layout flags")
            size = parse_png_size(raw)
            if size is None:
                raise UsageError("FILE has a PNG signature but no valid IHDR")
            width, height = size
            kind, fmt = "png", 100
        else:
            if args.raw_rgb is not None and args.raw_rgba is not None:
                raise UsageError("use only one of --raw-rgb/--raw-rgba")
            if args.raw_rgba is not None:
                width, height = args.raw_rgba
                kind, fmt, channels = "rgba", 32, 4
            elif args.raw_rgb is not None:
                width, height = args.raw_rgb
                kind, fmt, channels = "rgb", 24, 3
            else:
                raise UsageError(
                    "FILE is not a PNG; pass --raw-rgb WxH or --raw-rgba WxH "
                    "to declare the raw pixel layout"
                )
            expected = width * height * channels
            if len(raw) != expected:
                raise UsageError(
                    "raw FILE length %d does not match %dx%d %s (%d bytes)"
                    % (len(raw), width, height, kind.upper(), expected)
                )
        data = raw
    elif args.png is not None:
        width, height = args.png
        kind, fmt = "png", 100
        data = make_png(width, height, args.png_color)
    elif args.raw_rgba is not None:
        width, height = args.raw_rgba
        kind, fmt = "rgba", 32
        px = args.png_color + b"\xff"
        data = px * (width * height)
    elif args.raw_rgb is not None:
        width, height = args.raw_rgb
        kind, fmt = "rgb", 24
        data = args.png_color * (width * height)
    else:
        raise UsageError("no image source")

    if len(data) > MAX_PAYLOAD:
        raise UsageError("payload exceeds %d bytes" % MAX_PAYLOAD)

    wire = data
    compressed = False
    if args.zlib:
        if fmt == 100:
            notes.append("OpenTUI does not zlib-compress PNG payloads; --zlib ignored for f=100")
        else:
            wire, compressed = _compress_if_smaller(data, notes)

    return Prepared(
        kind=kind,
        fmt=fmt,
        width=width,
        height=height,
        data=data,
        wire=wire,
        compressed=compressed,
        notes=notes,
    )


# ---------------------------------------------------------------------------
# Stream construction
# ---------------------------------------------------------------------------


def build_probe(term: bytes) -> Record:
    return Record(
        kind="probe",
        control=PROBE_CONTROL,
        b64=PROBE_PAYLOAD_B64,
        wire=apc_bytes(PROBE_CONTROL, PROBE_PAYLOAD_B64, term),
        chunk_index=0,
        chunk_count=1,
    )


def split_payload(payload: bytes, opentui_chunking: bool):
    """Return base64 chunks.

    Default (opentui_chunking=True): split 3072 raw bytes first, exactly like
    terminal-image.zig's 3072-byte loop (base64 chunks up to 4096 chars).
    False: split the base64 text into 3072-character chunks (2304 raw bytes).
    """

    if opentui_chunking:
        chunks = [
            b64(payload[off : off + OPENTUI_CHUNK_RAW])
            for off in range(0, len(payload), OPENTUI_CHUNK_RAW)
        ]
    else:
        encoded = b64(payload)
        chunks = [encoded[i : i + CHUNK_B64] for i in range(0, len(encoded), CHUNK_B64)]
    return chunks or [""]


def build_transmit(prepared: Prepared, args, term: bytes) -> list:
    chunks = split_payload(prepared.wire, args.opentui_chunking)
    count = len(chunks)
    records = []
    for index, chunk in enumerate(chunks):
        more = index < count - 1
        if index == 0:
            control = [("a", "t"), ("f", str(prepared.fmt))]
            if prepared.fmt != 100:
                control.append(("s", str(prepared.width)))
                control.append(("v", str(prepared.height)))
            control.append(("i", str(args.id)))
            if prepared.compressed:
                control.append(("o", "z"))
            control.append(("m", "1" if more else "0"))
            control.append(("q", "2"))
        else:
            # terminal-image.zig: continuation chunks carry only m and q.
            control = [("m", "1" if more else "0"), ("q", "2")]
        records.append(
            Record(
                kind="transmit",
                control=tuple(control),
                b64=chunk,
                wire=apc_bytes(control, chunk, term),
                chunk_index=index,
                chunk_count=count,
            )
        )
    return records


def build_placement(args, term: bytes):
    control = [
        ("a", "p"),
        ("i", str(args.id)),
        ("p", str(args.placement_id)),
        ("c", str(args.cols)),
        ("r", str(args.rows)),
    ]
    if args.src is not None:
        x, y, w, h = args.src
        control.extend(
            [("x", str(x)), ("y", str(y)), ("w", str(w)), ("h", str(h))]
        )
    control.extend([("C", "1"), ("z", str(args.z)), ("q", "2")])

    cursor = None
    if not getattr(args, "at_cursor", False):
        cursor = Record(
            kind="cursor", control=(), b64="", wire=b"\x1b[1;1H", flow=args._flow
        )
    placement = Record(
        kind="placement",
        control=tuple(control),
        b64="",
        wire=apc_bytes(control, "", term),
        flow=args._flow,
    )
    return cursor, placement


def build_delete(args, term: bytes) -> Optional[Record]:
    if args.delete == "none":
        return None
    if args.delete in ("i", "I"):
        control = [
            ("a", "d"),
            ("d", args.delete),
            ("i", str(args.id)),
            ("q", "2"),
        ]
    else:  # --delete p: remove this placement (d=p is a cell delete in the spec)
        control = [
            ("a", "d"),
            ("d", "i"),
            ("i", str(args.id)),
            ("p", str(args.placement_id)),
            ("q", "2"),
        ]
    return Record(
        kind="delete",
        control=tuple(control),
        b64="",
        wire=apc_bytes(control, "", term),
        flow=args._flow,
    )


def build_flows(args, prepared: Optional[Prepared], term: bytes) -> list:
    flows = []
    count = 1 if args.probe_only else args.count
    for index in range(count):
        args._flow = index + 1
        flow = Flow(
            index=index + 1,
            probe=build_probe(term),
            transmit=[],
            cursor=None,
            placement=None,
            delete=None,
        )
        if not args.probe_only:
            flow.transmit = build_transmit(prepared, args, term)
            flow.cursor, flow.placement = build_placement(args, term)
            flow.delete = build_delete(args, term)
        flows.append(flow)
    return flows


def stream_bytes(flows) -> bytes:
    return b"".join(record.wire for flow in flows for record in flow.records())


# ---------------------------------------------------------------------------
# Parsing / verification
# ---------------------------------------------------------------------------


def parse_cursor_gap(gap: bytes):
    records = []
    pos = 0
    for match in CSI_CURSOR_RE.finditer(gap):
        if match.start() != pos:
            return False, records
        records.append(
            {
                "type": "cursor",
                "row": int(match.group(1)),
                "col": int(match.group(2)),
                "wire": match.group(0),
            }
        )
        pos = match.end()
    return pos == len(gap), records


def parse_stream(stream: bytes):
    """Parse APCs and CSI cursor moves; returns (items, errors)."""

    items = []
    errors = []
    pos = 0
    while pos < len(stream):
        start = stream.find(b"\x1b_G", pos)
        if start < 0:
            ok, cursors = parse_cursor_gap(stream[pos:])
            items.extend(cursors)
            if not ok:
                errors.append(
                    "unexpected trailing bytes at offset %d: %r"
                    % (pos, stream[pos : pos + 32])
                )
            break
        if start > pos:
            gap = stream[pos:start]
            ok, cursors = parse_cursor_gap(gap)
            items.extend(cursors)
            if not ok:
                errors.append(
                    "unexpected bytes at offset %d: %r" % (pos, gap[:32])
                )

        st = stream.find(b"\x1b\\", start + 3)
        bel = stream.find(b"\x07", start + 3)
        if st != -1 and (bel == -1 or st < bel):
            end, term = st, ST
        elif bel != -1:
            end, term = bel, BEL
        else:
            errors.append("unterminated APC at offset %d" % start)
            break

        body = stream[start + 3 : end]
        try:
            text = body.decode("ascii")
        except UnicodeDecodeError:
            errors.append("non-ASCII APC body at offset %d" % start)
            break
        if ";" in text:
            control_text, payload = text.split(";", 1)
        else:
            control_text, payload = text, ""
        control = []
        for field_text in control_text.split(",") if control_text else []:
            if "=" not in field_text:
                errors.append(
                    "APC control field without '=' at offset %d: %r"
                    % (start, field_text)
                )
                continue
            key, value = field_text.split("=", 1)
            control.append((key, value))

        items.append(
            {
                "type": "apc",
                "wire": stream[start : end + len(term)],
                "term": term,
                "control": control,
                "payload": payload,
                "offset": start,
            }
        )
        pos = end + len(term)
    return items, errors


def classify(item) -> str:
    control = dict(item["control"])
    action = control.get("a")
    if action == "q":
        return "probe"
    if action == "t":
        return "transmit"
    if action == "p":
        return "placement"
    if action == "d":
        return "delete"
    keys = set(control)
    if "m" in keys and keys <= {"m", "q"}:
        return "continuation"
    return "unknown"


def verify_stream(
    stream: bytes,
    prepared: Optional[Prepared],
    flows: list,
    term: bytes,
    chunk_limit: int,
    probe_only: bool,
) -> list:
    """Re-parse our own output and check every byte-level invariant."""

    errors = []
    items, parse_errors = parse_stream(stream)
    errors.extend(parse_errors)

    apcs = [item for item in items if item["type"] == "apc"]
    expected_records = [record for flow in flows for record in flow.records()]
    expected_apcs = [record for record in expected_records if record.kind != "cursor"]
    expected_cursors = [record for record in expected_records if record.kind == "cursor"]

    if len(apcs) != len(expected_apcs):
        errors.append(
            "APC count %d != expected %d" % (len(apcs), len(expected_apcs))
        )
    for index, (item, record) in enumerate(zip(apcs, expected_apcs)):
        if item["term"] != term:
            errors.append(
                "APC %d terminator %r != %r" % (index, item["term"], term)
            )
        if item["wire"] != record.wire:
            errors.append(
                "APC %d wire mismatch (expected %s)" % (index, record.kind)
            )
        if tuple(item["control"]) != record.control:
            errors.append(
                "APC %d control %r != %r"
                % (index, item["control"], list(record.control))
            )

    cursors = [item for item in items if item["type"] == "cursor"]
    if len(cursors) != len(expected_cursors):
        errors.append(
            "cursor count %d != expected %d" % (len(cursors), len(expected_cursors))
        )

    # Group items into flows by probe.
    groups = []
    for item in items:
        if item["type"] == "cursor":
            if not groups:
                errors.append("cursor move before any probe")
            else:
                groups[-1]["cursors"].append(item)
            continue
        kind = classify(item)
        if kind == "probe":
            groups.append(
                {"probe": item, "transmit": [], "placements": [], "deletes": [], "cursors": []}
            )
            continue
        if not groups:
            errors.append("APC before probe: %r" % (item["control"],))
            continue
        target = groups[-1]
        if kind in ("transmit", "continuation"):
            target["transmit"].append(item)
        elif kind == "placement":
            target["placements"].append(item)
        elif kind == "delete":
            target["deletes"].append(item)
        else:
            errors.append("unknown APC action: %r" % (item["control"],))

    if len(groups) != len(flows):
        errors.append("flow count %d != expected %d" % (len(groups), len(flows)))

    for flow_index, group in enumerate(groups):
        expected_flow = flows[flow_index] if flow_index < len(flows) else None
        probe = group["probe"]
        if tuple(probe["control"]) != PROBE_CONTROL:
            errors.append("flow %d: probe control order/content mismatch" % (flow_index + 1,))
        if probe["payload"] != PROBE_PAYLOAD_B64:
            errors.append("flow %d: probe payload != AAAA" % (flow_index + 1,))
        if term == ST and probe["wire"] != OPENTUI_PROBE_ST:
            errors.append(
                "flow %d: probe bytes differ from ansi.kittyGraphicsQuery"
                % (flow_index + 1,)
            )

        chunks = group["transmit"]
        if probe_only:
            if chunks or group["placements"] or group["deletes"]:
                errors.append("probe-only stream contains more than the probe")
            continue
        if not chunks:
            errors.append("flow %d: no transmit APC" % (flow_index + 1,))
            continue
        if expected_flow is not None and len(chunks) != len(expected_flow.transmit):
            errors.append(
                "flow %d: chunk count %d != expected %d"
                % (flow_index + 1, len(chunks), len(expected_flow.transmit))
            )

        joined = ""
        for index, chunk in enumerate(chunks):
            payload = chunk["payload"]
            if len(payload) > chunk_limit:
                errors.append(
                    "flow %d chunk %d: %d base64 chars > %d"
                    % (flow_index + 1, index, len(payload), chunk_limit)
                )
            if index < len(chunks) - 1:
                if len(payload) != chunk_limit:
                    errors.append(
                        "flow %d chunk %d: non-final length %d != %d"
                        % (flow_index + 1, index, len(payload), chunk_limit)
                    )
                if len(payload) % 4 != 0:
                    errors.append(
                        "flow %d chunk %d: non-final length not a multiple of 4"
                        % (flow_index + 1, index)
                    )
            joined += payload
            expected_m = "0" if index == len(chunks) - 1 else "1"
            control = dict(chunk["control"])
            if control.get("m") != expected_m:
                errors.append(
                    "flow %d chunk %d: m=%r != %r"
                    % (flow_index + 1, index, control.get("m"), expected_m)
                )
            if index > 0:
                if tuple(chunk["control"]) != (("m", expected_m), ("q", "2")):
                    errors.append(
                        "flow %d chunk %d: continuation control must be m,q only; got %r"
                        % (flow_index + 1, index, chunk["control"])
                    )
                if any(key == "i" for key, _ in chunk["control"]):
                    errors.append(
                        "flow %d chunk %d: continuation repeats i= (OpenTUI does not)"
                        % (flow_index + 1, index)
                    )

        raw = None
        if joined:
            try:
                raw = base64.b64decode(joined, validate=True)
            except (binascii.Error, ValueError) as exc:
                errors.append(
                    "flow %d: base64 decode failed: %s" % (flow_index + 1, exc)
                )
        if raw is not None:
            if b64(raw) != joined:
                errors.append("flow %d: base64 round-trip mismatch" % (flow_index + 1,))
            if prepared is not None and raw != prepared.wire:
                errors.append(
                    "flow %d: reassembled sha256 %s != source sha256 %s"
                    % (flow_index + 1, sha256(raw), sha256(prepared.wire))
                )
            if prepared is not None and prepared.compressed:
                try:
                    inflated = zlib.decompress(raw)
                except zlib.error as exc:
                    errors.append(
                        "flow %d: zlib decompress failed: %s" % (flow_index + 1, exc)
                    )
                else:
                    if inflated != prepared.data:
                        errors.append(
                            "flow %d: decompressed payload != source image"
                            % (flow_index + 1,)
                        )

        if not group["placements"]:
            errors.append("flow %d: missing placement" % (flow_index + 1,))
        expects_cursor = expected_flow is not None and expected_flow.cursor is not None
        if expects_cursor and not group["cursors"]:
            errors.append("flow %d: missing CSI cursor move" % (flow_index + 1,))
        if not expects_cursor and group["cursors"]:
            errors.append("flow %d: unexpected CSI cursor move" % (flow_index + 1,))
        if expected_flow is not None:
            if len(group["deletes"]) != (1 if expected_flow.delete else 0):
                errors.append(
                    "flow %d: delete count %d != expected %d"
                    % (
                        flow_index + 1,
                        len(group["deletes"]),
                        1 if expected_flow.delete else 0,
                    )
                )

    return errors


# ---------------------------------------------------------------------------
# Reply handling
# ---------------------------------------------------------------------------


def scan_replies(buffer: bytes, expected_id: int, allow_bel: bool = False):
    """Return ('ok', msg) / ('error', msg) / None (need more bytes).

    OpenTUI discards BEL-terminated graphics replies, so BEL is ignored unless
    allow_bel is set.
    """

    pos = 0
    while True:
        start = buffer.find(b"\x1b_G", pos)
        if start < 0:
            return None
        st = buffer.find(b"\x1b\\", start + 3)
        bel = buffer.find(b"\x07", start + 3)
        if st != -1 and (bel == -1 or st < bel):
            end, term_len = st, 2
        elif bel != -1:
            if not allow_bel:
                pos = bel + 1
                continue
            end, term_len = bel, 1
        else:
            return None

        body = buffer[start + 3 : end]
        pos = end + term_len
        if b";" not in body:
            continue
        control_text, message = body.split(b";", 1)
        fields = {}
        for field_bytes in control_text.split(b","):
            if b"=" in field_bytes:
                key, value = field_bytes.split(b"=", 1)
                fields[key] = value
        if fields.get(b"i") != str(expected_id).encode("ascii"):
            continue
        try:
            text = message.decode("ascii")
        except UnicodeDecodeError:
            text = repr(message)
        if text == "OK":
            return ("ok", text)
        return ("error", text)


def wait_for_reply(expected_id: int, hold: float):
    """Wait up to `hold` seconds for i=<id>;OK on stdin.  Never prompts."""

    deadline = time.monotonic() + hold
    buffer = b""
    fd = sys.stdin.fileno()
    while True:
        remaining = max(0.0, deadline - time.monotonic())
        try:
            readable, _, _ = select.select([fd], [], [], remaining)
        except (OSError, ValueError) as exc:
            return False, "cannot select on stdin: %s" % (exc,)
        if not readable:
            return False, (
                "timeout after %.1fs waiting for \\x1b_Gi=%d;OK\\x1b\\"
                % (hold, expected_id)
            )
        try:
            chunk = os.read(fd, 65536)
        except OSError as exc:
            return False, "stdin read failed: %s" % (exc,)
        if not chunk:
            return False, "stdin closed before i=%d;OK" % (expected_id,)
        buffer += chunk
        result = scan_replies(buffer, expected_id)
        if result is not None:
            return result[0] == "ok", result[1]
        if time.monotonic() >= deadline:
            return False, (
                "timeout after %.1fs waiting for \\x1b_Gi=%d;OK\\x1b\\"
                % (hold, expected_id)
            )


# ---------------------------------------------------------------------------
# Reports
# ---------------------------------------------------------------------------


def json_control(control) -> str:
    return json.dumps({k: v for k, v in control}, separators=(",", ":"))


def transmit_summary(prepared: Prepared, flow: Flow) -> list:
    chunks = flow.transmit
    joined = "".join(record.b64 for record in chunks)
    decoded = base64.b64decode(joined, validate=True)
    lines = [
        "transmit.%d.source_bytes=%d" % (flow.index, len(prepared.data)),
        "transmit.%d.wire_bytes=%d" % (flow.index, len(prepared.wire)),
        "transmit.%d.compressed=%s"
        % (flow.index, "true" if prepared.compressed else "false"),
        "transmit.%d.chunks=%d" % (flow.index, len(chunks)),
        "transmit.%d.reassembled_sha256=%s" % (flow.index, sha256(decoded)),
        "transmit.%d.source_sha256=%s" % (flow.index, sha256(prepared.wire)),
        "transmit.%d.base64_roundtrip=%s"
        % (flow.index, "true" if b64(decoded) == joined else "false"),
    ]
    if prepared.compressed:
        lines.append(
            "transmit.%d.decompressed_sha256=%s"
            % (flow.index, sha256(zlib.decompress(decoded)))
        )
    return lines


def dry_run_report(
    args,
    prepared: Optional[Prepared],
    flows,
    term: bytes,
    term_name: str,
    chunk_limit: int,
    verify_errors,
) -> str:
    lines = ["emit_kitty dry-run 1", "terminator=%s" % term_name]
    lines.append("terminator_hex=%s" % term.hex())
    lines.append("flow_count=%d" % len(flows))
    lines.append("chunk_limit=%d" % chunk_limit)
    lines.append(
        "chunking=%s"
        % ("opentui-raw-3072" if args.opentui_chunking else "base64-3072")
    )
    lines.append("probe_only=%s" % ("true" if args.probe_only else "false"))
    if prepared is not None:
        lines.extend(
            [
                "image.kind=%s" % prepared.kind,
                "image.width=%d" % prepared.width,
                "image.height=%d" % prepared.height,
                "image.format=%d" % prepared.fmt,
                "image.source_bytes=%d" % len(prepared.data),
                "image.wire_bytes=%d" % len(prepared.wire),
                "image.compressed=%s"
                % ("true" if prepared.compressed else "false"),
                "image.source_sha256=%s" % sha256(prepared.data),
            ]
        )
    probe = flows[0].probe
    lines.extend(
        [
            "probe.bytes=%r" % (probe.wire,),
            "probe.control=%s" % json_control(probe.control),
            "probe.payload_b64=%s" % probe.b64,
            "probe.payload_len=%d" % len(base64.b64decode(probe.b64)),
            "probe.chunks=1",
            "probe.opentui_equal=%s"
            % ("true" if probe.wire == OPENTUI_PROBE_ST else "false"),
        ]
    )

    seq = 0
    apc_count = 0
    for flow in flows:
        for record in flow.records():
            prefix = "seq.%d" % seq
            lines.append("%s.flow=%d" % (prefix, flow.index))
            lines.append("%s.kind=%s" % (prefix, record.kind))
            lines.append("%s.apc=%s" % (prefix, "false" if record.kind == "cursor" else "true"))
            lines.append("%s.control=%s" % (prefix, json_control(record.control)))
            if record.b64:
                payload_len = len(base64.b64decode(record.b64))
            else:
                payload_len = 0
            lines.append("%s.payload_len=%d" % (prefix, payload_len))
            lines.append(
                "%s.chunks=%d" % (prefix, record.chunk_count if record.kind == "transmit" else (1 if record.kind == "probe" else 0))
            )
            lines.append("%s.bytes=%r" % (prefix, record.wire))
            if record.kind != "cursor":
                apc_count += 1
            seq += 1
    lines.append("apc_count=%d" % apc_count)

    if prepared is not None:
        for flow in flows:
            lines.extend(transmit_summary(prepared, flow))

    lines.append("stream.bytes=%d" % len(stream_bytes(flows)))
    lines.append("stream.sha256=%s" % sha256(stream_bytes(flows)))
    lines.append("verify.requested=%s" % ("true" if args.verify else "false"))
    if args.verify:
        lines.append("verify.ok=%s" % ("false" if verify_errors else "true"))
        for index, error in enumerate(verify_errors):
            lines.append("verify.error.%d=%s" % (index, error))
    return "\n".join(lines) + "\n"


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


class Parser(argparse.ArgumentParser):
    def error(self, message):
        raise UsageError(message)


HELP_EPILOG = """\
examples:
  emit_kitty.py --png 40x20 --cols 10 --rows 5 --dry-run
  emit_kitty.py --png 40x20 --cols 10 --rows 5 > image.bin
  emit_kitty.py --raw-rgba 16x16 --cols 2 --rows 1 --zlib --verify > out.bin
  emit_kitty.py --probe-only --expect-reply --hold 1.0 | cat -v
  emit_kitty.py --file shot.png --delete i --count 1

wire shape:
  probe     ESC _ G i=31337,s=1,v=1,a=q,t=d,f=24;AAAA ESC \\
  transmit  ESC _ G a=t,f=100,i=ID,m=M,q=2;<b64 chunk> ESC \\   (PNG)
            ESC _ G a=t,f=24|32,s=W,v=H,i=ID,o=z?,m=M,q=2;<b64> ESC \\
  cont.     ESC _ G m=M,q=2;<b64 chunk> ESC \\   (i= is NOT repeated)
  place     CSI row;col H then ESC _ G a=p,i=ID,p=PID,c=C,r=R[,x,y,w,h],C=1,z=Z,q=2 ESC \\
  delete    ESC _ G a=d,d=i|I,i=ID,q=2 ESC \\  or  a=d,d=i,i=ID,p=PID,q=2

exit codes:
  0  success
  2  usage / validation error
  1  I/O, encoding, or --verify mismatch
  3  reply timeout / mismatch (--expect-reply)

notes:
  * transmit chunks carry q=2 in OpenTUI and m is always present (m=0 for a
    single chunk).
  * --zlib only compresses raw RGB/RGBA payloads; OpenTUI leaves PNG (f=100)
    uncompressed, and falls back to raw when zlib output does not shrink.
  * Default chunking is OpenTUI's: 3072 raw bytes per APC (base64 up to
    4096 chars). --b64-chunking instead splits the base64 text every 3072 chars.
  * --expect-reply reads reply bytes from stdin after the probe of the first
    flow only; later flows are emitted without waiting.
"""


def build_parser() -> Parser:
    parser = Parser(
        prog="emit_kitty.py",
        description="Wire-exact OpenTUI-compatible Kitty graphics emitter.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=HELP_EPILOG,
    )
    parser.add_argument("--png", type=dim_type, metavar="WxH", help="generate a deterministic PNG of WxH")
    parser.add_argument(
        "--png-color",
        type=color_type,
        default=bytes.fromhex("3366cc"),
        metavar="RRGGBB",
        help="solid color for --png and --raw-rgb/--raw-rgba (default 3366cc)",
    )
    parser.add_argument("--raw-rgba", type=dim_type, metavar="WxH", help="generate solid RGBA pixels")
    parser.add_argument("--raw-rgb", type=dim_type, metavar="WxH", help="generate solid RGB pixels")
    parser.add_argument("--zlib", action="store_true", help="zlib-compress raw payloads (o=z)")
    parser.add_argument("--id", type=int, default=1, metavar="N", help="image id (1..4294967295, default 1)")
    parser.add_argument(
        "--placement-id", type=int, default=1, metavar="N", help="placement id (1..4294967295, default 1)"
    )
    parser.add_argument("--cols", type=int, metavar="N", help="placement columns (default ceil(width/8))")
    parser.add_argument("--rows", type=int, metavar="N", help="placement rows (default ceil(height/16))")
    parser.add_argument("--src", type=src_type, metavar="x,y,w,h", help="source rectangle in pixels")
    parser.add_argument("--z", type=int, metavar="N", help="placement z-index (default -1073741824+placement-id)")
    parser.add_argument(
        "--delete",
        choices=["none", "i", "I", "p"],
        default="none",
        help="delete after placement: i/I by image id, p removes this placement "
        "(a=d,d=i,i=ID,p=PID)",
    )
    parser.add_argument("--quiet", action="store_true", help="suppress stderr diagnostics (stdout bytes unchanged)")
    parser.add_argument(
        "--terminator",
        choices=["bel", "st"],
        default="st",
        help="APC terminator: st = ESC backslash (default), bel = 0x07",
    )
    parser.add_argument("--count", type=int, default=1, metavar="N", help="emit N complete flows (default 1)")
    parser.add_argument("--delay", type=float, default=0.0, metavar="SECONDS", help="sleep between flows")
    parser.add_argument(
        "--probe-only",
        action="store_true",
        help="emit only the probe and exit (ignores --count/--delay and any image source)",
    )
    parser.add_argument(
        "--expect-reply",
        action="store_true",
        help="read stdin until i=31337;OK (timeout --hold, exit 3 on failure)",
    )
    parser.add_argument("--dry-run", action="store_true", help="print a parseable report instead of raw bytes")
    parser.add_argument("--verify", action="store_true", help="re-parse own output and verify chunks/payload")
    parser.add_argument("--hold", type=float, default=2.0, metavar="SECONDS", help="reply wait timeout (default 2.0)")
    parser.add_argument(
        "--b64-chunking",
        action="store_true",
        help="split the base64 text into 3072-character chunks instead of OpenTUI's "
        "3072-raw-byte chunks (base64 up to 4096 chars; default)",
    )
    parser.add_argument(
        "--opentui-chunking",
        action="store_true",
        help=argparse.SUPPRESS,
    )
    parser.add_argument(
        "--at-cursor",
        action="store_true",
        help="place at the current cursor (no CSI H); default moves to 1;1 first",
    )
    parser.add_argument("--file", dest="file_path", metavar="PATH", help="payload file (PNG, or raw with layout flags)")
    parser.add_argument("file_arg", nargs="?", metavar="FILE", help="payload file (same as --file)")
    return parser


def validate_args(args) -> None:
    if args.file_path is not None and args.file_arg is not None:
        raise UsageError("use either --file PATH or positional FILE, not both")
    if args.file_arg is not None:
        args.file_path = args.file_arg

    sources = [args.png is not None, args.raw_rgb is not None, args.raw_rgba is not None]
    source_count = sum(1 for value in sources if value)
    if args.file_path is None:
        if source_count > 1:
            raise UsageError("use only one of --png/--raw-rgb/--raw-rgba")
        if source_count == 0 and not args.probe_only:
            raise UsageError("a source is required: --png WxH, --raw-rgb WxH, --raw-rgba WxH, or FILE")
    else:
        if args.png is not None:
            raise UsageError("--png and FILE are mutually exclusive")
        if args.raw_rgb is not None and args.raw_rgba is not None:
            raise UsageError("use only one of --raw-rgb/--raw-rgba")

    if not (1 <= args.id <= 0xFFFFFFFF):
        raise UsageError("--id must be in 1..4294967295")
    if not (1 <= args.placement_id <= 0xFFFFFFFF):
        raise UsageError("--placement-id must be in 1..4294967295")
    if not (1 <= args.count <= 10000):
        raise UsageError("--count must be in 1..10000")
    if not math.isfinite(args.delay) or args.delay < 0:
        raise UsageError("--delay must be a finite number >= 0")
    if not math.isfinite(args.hold) or args.hold < 0:
        raise UsageError("--hold must be a finite number >= 0")
    if args.cols is not None and not (1 <= args.cols <= 65535):
        raise UsageError("--cols must be in 1..65535")
    if args.rows is not None and not (1 <= args.rows <= 65535):
        raise UsageError("--rows must be in 1..65535")
    if args.z is not None and not (INT32_MIN <= args.z <= INT32_MAX):
        raise UsageError("--z must fit int32")
    if args.expect_reply and args.dry_run:
        raise UsageError("--expect-reply cannot be combined with --dry-run (dry-run emits nothing)")
    if args.probe_only and (args.raw_rgb is not None or args.raw_rgba is not None or args.png is not None):
        pass  # probe-only ignores the image source


def apply_defaults(args, prepared: Prepared) -> None:
    if args.cols is None:
        args.cols = max(1, (prepared.width + 7) // 8)
    if args.rows is None:
        args.rows = max(1, (prepared.height + 15) // 16)
    if args.src is not None:
        x, y, w, h = args.src
        if x + w > prepared.width or y + h > prepared.height:
            raise UsageError(
                "--src rect %d,%d,%d,%d exceeds image %dx%d"
                % (x, y, w, h, prepared.width, prepared.height)
            )
    if args.z is None:
        if args.placement_id > OPENTUI_IMAGE_ID_MASK:
            raise UsageError(
                "default z follows kittyPlacementZ() and requires placement id <= %d; pass --z"
                % OPENTUI_IMAGE_ID_MASK
            )
        args.z = KITTY_Z_BASE + args.placement_id
    args._flow = 1


def diagnostic(args, message: str) -> None:
    if not args.quiet:
        sys.stderr.write(message + "\n")
        sys.stderr.flush()


def run(args) -> int:
    validate_args(args)
    term = BEL if args.terminator == "bel" else ST
    chunk_limit = 4096 if args.opentui_chunking else CHUNK_B64

    if args.probe_only:
        prepared = None
        flows = build_flows(args, None, term)
    else:
        prepared = prepare_payload(args)
        apply_defaults(args, prepared)
        for note in prepared.notes:
            diagnostic(args, "note: " + note)
        flows = build_flows(args, prepared, term)

    stream = stream_bytes(flows)
    verify_errors = []
    if args.verify:
        verify_errors = verify_stream(
            stream, prepared, flows, term, chunk_limit, args.probe_only
        )

    if args.dry_run:
        sys.stdout.write(
            dry_run_report(
                args, prepared, flows, term, args.terminator, chunk_limit, verify_errors
            )
        )
        sys.stdout.flush()
        return 1 if verify_errors else 0

    if verify_errors:
        for error in verify_errors[:10]:
            diagnostic(args, "verify: " + error)
        diagnostic(args, "verify: FAILED (%d error(s))" % len(verify_errors))
        return 1
    if args.verify:
        diagnostic(args, "verify: ok (%d bytes, %d flow(s))" % (len(stream), len(flows)))

    diagnostic(
        args,
        "probe: %d bytes (a=q, i=31337%s)"
        % (len(flows[0].probe.wire), ", BEL" if term == BEL else ""),
    )

    out = sys.stdout.buffer
    paced = args.expect_reply or args.delay > 0 or len(flows) > 1

    try:
        if not paced:
            out.write(stream)
            out.flush()
        else:
            for index, flow in enumerate(flows):
                out.write(flow.probe.wire)
                out.flush()
                if args.expect_reply and index == 0:
                    ok, detail = wait_for_reply(PROBE_ID, args.hold)
                    if not ok:
                        diagnostic(
                            args,
                            "reply: FAILED: %s" % detail,
                        )
                        return 3
                    diagnostic(args, "reply: OK")
                for record in flow.records():
                    if record.kind == "probe":
                        continue
                    out.write(record.wire)
                out.flush()
                if index < len(flows) - 1 and args.delay > 0:
                    time.sleep(args.delay)
    except BrokenPipeError:
        raise EmitError("stdout closed early")

    if prepared is not None:
        diagnostic(
            args,
            "transmit: %s %dx%d f=%d, %d bytes, %s%s"
            % (
                prepared.kind,
                prepared.width,
                prepared.height,
                prepared.fmt,
                len(prepared.wire),
                "zlib " if prepared.compressed else "",
                "chunked" if len(flows[0].transmit) > 1 else "single chunk",
            ),
        )
    if prepared is not None:
        diagnostic(
            args,
            "placement: i=%d p=%d c=%d r=%d z=%d%s"
            % (
                args.id,
                args.placement_id,
                args.cols,
                args.rows,
                args.z,
                " src=%d,%d,%d,%d" % args.src if args.src else "",
            ),
        )
    if args.delete != "none":
        diagnostic(
            args,
            "delete: d=%s i=%d%s"
            % (
                args.delete,
                args.id,
                " p=%d" % args.placement_id if args.delete == "p" else "",
            ),
        )
    return 0


def main(argv) -> int:
    parser = build_parser()
    try:
        args = parser.parse_args(argv)
        # OpenTUI wire-exact chunking is the default; --b64-chunking selects
        # the alternative 3072-character-base64 split.
        args.opentui_chunking = not args.b64_chunking
    except UsageError as exc:
        quiet = "--quiet" in argv
        if not quiet:
            sys.stderr.write("emit_kitty.py: error: %s\n" % exc)
            sys.stderr.write("try --help for usage\n")
        return 2

    try:
        return run(args)
    except UsageError as exc:
        if not args.quiet:
            sys.stderr.write("emit_kitty.py: error: %s\n" % exc)
        return 2
    except EmitError as exc:
        if not args.quiet:
            sys.stderr.write("emit_kitty.py: error: %s\n" % exc)
        return 1
    except OSError as exc:
        if not args.quiet:
            sys.stderr.write("emit_kitty.py: I/O error: %s\n" % exc)
        return 1


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except BrokenPipeError:
        try:
            sys.stdout.close()
        except Exception:
            pass
        os._exit(1)
    except KeyboardInterrupt:
        os._exit(130)
