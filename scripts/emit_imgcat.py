#!/usr/bin/env python3
"""emit_imgcat.py -- build iTerm2 OSC 1337 inline-image sequences.

Wire format (all on one logical line unless --newline is given):

    ESC ] 1337 ; File=<key>=<value>[;<key>=<value> ...] : <base64 payload> ST

* The parameter list starts immediately after ``File=`` and is joined with
  ``;``.  The colon that introduces the payload follows the last parameter
  directly (``File=:<payload>`` when there are no parameters).
* The payload is the raw image bytes, base64 encoded, with no line breaks.
* ST is ``ESC \\`` (0x1b 0x5c) by default; ``--terminator bel`` uses BEL
  (0x07) instead.
* Nothing else is written to stdout: no banner, no trailing newline unless
  ``--newline`` is passed.  Human-readable matrix labels go to stderr.

This tool is intentionally stdlib-only and non-interactive.  It never
prompts and never needs a TTY.

Exit codes: 0 success, 2 usage/validation error, 1 I/O or decode error.
"""

from __future__ import annotations

import argparse
import base64
import binascii
import hashlib
import math
import os
import re
import struct
import sys
import time
import zlib
from dataclasses import dataclass
from typing import List, Optional, Sequence, Tuple

ESC = b"\x1b"
BEL = b"\x07"
ST = b"\x1b\\"
OSC_PREFIX = b"\x1b]1337;File="

#: FILE values accepted (and ignored) alongside --png/--raw-bytes.  These are
#: really "write the wire to stdout" markers; keeping them accepted makes
#: shell one-liners such as ``--png 80x40 --inline 1 /dev/stdout`` work.
STDOUT_ALIASES = frozenset({"-", "/dev/stdout", "/dev/fd/1"})

DIMENSION_RE = re.compile(r"^(?:auto|[0-9]+(?:px|%)?)$")
PNG_SIZE_RE = re.compile(r"^([0-9]+)[xX]([0-9]+)$")
COLOR_RE = re.compile(r"^#?([0-9a-fA-F]{6})$")
UNSIGNED_RE = re.compile(r"^[0-9]+$")

MAX_PNG_SIDE = 10000
MAX_PNG_PIXELS = 25_000_000

PROTOCOL_HELP = """\
protocol
  ESC ] 1337 ; File=<args> : <base64 payload> ST

  <args> is a semicolon-separated list of key=value pairs.  The colon before
  the payload is literal and is written even when <args> is empty.  The
  payload is base64 of the raw file bytes (no wrapping, no whitespace).  ST is
  ESC \\ by default; BEL (0x07) is used with --terminator bel.  No trailing
  newline is emitted unless --newline is given.

  Supported parameters (each is omitted from the wire unless explicitly set):
    name=...                 base64 of the UTF-8 name by default
                             (--name-encoding raw|base64|none)
    size=...                 size metadata in bytes; --size auto uses the
                             actual payload length
    width=...                N cells, Npx, N%, or auto
    height=...               N cells, Npx, N%, or auto
    preserveAspectRatio=0|1
    inline=0|1
    doNotMoveCursor=1

inputs
  FILE                       image file to read; omit or use '-' for stdin
  --png WIDTHxHEIGHT         generate a solid-colour PNG (stdlib only)
  --raw-bytes N              N deterministic payload bytes (0 <= N)

modes
  --matrix                   emit all protocol cases as raw wire bytes on
                             stdout, with case labels on stderr
  --matrix-emit              same byte stream without labels (labels stay off
                             stderr); combine with --matrix as well
  --dry-run                  print a stable key=value report with Python byte
                             reprs and payload metadata instead of raw bytes
  --verify                   re-parse each built sequence and assert that the
                             base64 payload decodes to the input bytes

exit codes
  0 success, 2 usage/validation error, 1 I/O or decode error

examples
  emit_imgcat.py --png 80x40 --width 10 --inline 1 > /tmp/out.bin
  emit_imgcat.py --png 80x40 --width 10 --inline 1 /dev/stdout | cat -v
  emit_imgcat.py pic.png --name 'café.png' --size auto --terminator bel
  emit_imgcat.py --raw-bytes 1024 --dry-run
  emit_imgcat.py --matrix --matrix-emit > /tmp/matrix.bin

matrix notes
  In matrix mode labels are diagnostics, never payload: they go to stderr.
  Raw byte cases are newline-separated on stdout so line-oriented tools can
  split them.  Matrix mode ignores --count/--delay/--newline/--terminator and
  the normal input flags; each case defines those itself.  --matrix-emit
  suppresses labels even when --matrix is also present.
"""


class UsageError(Exception):
    """Raised for CLI validation failures (exit status 2)."""


@dataclass(frozen=True)
class Case:
    """One self-contained matrix case."""

    label: str
    payload: bytes
    args: Tuple[str, ...]
    terminator: str


# --------------------------------------------------------------------------
# small pure helpers
# --------------------------------------------------------------------------


def b64(data: bytes) -> bytes:
    """Return standard base64 (with padding, no line breaks)."""
    return base64.b64encode(data)


def terminator_bytes(name: str) -> bytes:
    """Map a CLI terminator name to its byte sequence."""
    if name == "bel":
        return BEL
    if name == "st":
        return ST
    raise UsageError(f"unknown terminator {name!r} (expected bel or st)")


def parse_dimension(flag: str, value: str) -> str:
    """Validate a width/height value: N, Npx, N%, or auto."""
    if not DIMENSION_RE.fullmatch(value):
        raise UsageError(
            f"{flag}: invalid value {value!r} "
            "(expected N cells, Npx, N%, or auto)"
        )
    return value


def parse_size(value: str) -> str:
    """Validate --size: non-negative integer bytes, or 'auto'."""
    if value == "auto":
        return value
    if not UNSIGNED_RE.fullmatch(value):
        raise UsageError(
            f"--size: invalid value {value!r} (expected non-negative bytes or auto)"
        )
    return value


def parse_count(value: str) -> int:
    if not UNSIGNED_RE.fullmatch(value):
        raise UsageError(f"--count: invalid value {value!r} (expected non-negative integer)")
    return int(value)


def parse_delay(value: str) -> float:
    try:
        seconds = float(value)
    except ValueError as exc:
        raise UsageError(f"--delay: invalid value {value!r} (expected seconds)") from exc
    if not math.isfinite(seconds) or seconds < 0:
        raise UsageError(f"--delay: invalid value {value!r} (expected finite seconds >= 0)")
    return seconds


def parse_png_size(value: str) -> Tuple[int, int]:
    match = PNG_SIZE_RE.fullmatch(value)
    if not match:
        raise UsageError(f"--png: invalid size {value!r} (expected WIDTHxHEIGHT, e.g. 80x40)")
    width, height = int(match.group(1)), int(match.group(2))
    if width <= 0 or height <= 0:
        raise UsageError(f"--png: width and height must be positive (got {value!r})")
    if width > MAX_PNG_SIDE or height > MAX_PNG_SIDE:
        raise UsageError(f"--png: dimensions must be <= {MAX_PNG_SIDE} per side")
    if width * height > MAX_PNG_PIXELS:
        raise UsageError(f"--png: image is too large ({width * height} pixels)")
    return width, height


def parse_color(value: str) -> Tuple[int, int, int]:
    match = COLOR_RE.fullmatch(value)
    if not match:
        raise UsageError(f"--png-color: invalid colour {value!r} (expected RRGGBB)")
    digits = match.group(1)
    return int(digits[0:2], 16), int(digits[2:4], 16), int(digits[4:6], 16)


def deterministic_bytes(length: int) -> bytes:
    """Deterministic payload of exactly *length* bytes (fast, stdlib only)."""
    if length < 0:
        raise UsageError("--raw-bytes: length must be non-negative")
    base = bytes(range(256))
    return (base * ((length // len(base)) + 1))[:length]


def build_args(
    *,
    name: Optional[str] = None,
    name_encoding: str = "base64",
    size: Optional[int] = None,
    width: Optional[str] = None,
    height: Optional[str] = None,
    preserve_aspect_ratio: Optional[str] = None,
    inline: Optional[str] = None,
    do_not_move_cursor: bool = False,
) -> List[str]:
    """Build the ordered ``key=value`` parameter list for the wire.

    Every optional parameter is omitted when it is None/False.  ``size`` is
    already resolved to bytes by the caller (payload length for --size auto).
    """
    args: List[str] = []

    if name is not None and name_encoding != "none":
        if name_encoding == "base64":
            value = b64(name.encode("utf-8")).decode("ascii")
        elif name_encoding == "raw":
            if any(ch in name for ch in ";:\r\n\x00"):
                raise UsageError(
                    "--name: raw names cannot contain ';', ':', CR, LF, or NUL; "
                    "use --name-encoding base64"
                )
            value = name
        else:
            raise UsageError(f"--name-encoding: unknown value {name_encoding!r}")
        args.append(f"name={value}")

    if size is not None:
        args.append(f"size={size}")

    if width is not None:
        args.append(f"width={width}")

    if height is not None:
        args.append(f"height={height}")

    if preserve_aspect_ratio is not None:
        args.append(f"preserveAspectRatio={preserve_aspect_ratio}")

    if inline is not None:
        args.append(f"inline={inline}")

    if do_not_move_cursor:
        args.append("doNotMoveCursor=1")

    return args


def emit_sequence(
    args: Sequence[str],
    payload: bytes,
    terminator: str = "st",
    newline: bool = False,
) -> bytes:
    """Render one complete OSC 1337 File sequence (no trailing newline by default)."""
    head = OSC_PREFIX + ";".join(args).encode("utf-8") + b":" + b64(payload)
    wire = head + terminator_bytes(terminator)
    if newline:
        wire += b"\n"
    return wire


def verify_sequence(seq: bytes, payload: bytes, terminator: str) -> Optional[str]:
    """Parse *seq* and compare its decoded payload with *payload*.

    Returns None on success, or a human-readable problem string.
    """
    suffix = terminator_bytes(terminator)
    if not seq.startswith(OSC_PREFIX):
        return "sequence does not start with ESC ] 1337 ; File="
    if not seq.endswith(suffix):
        return "sequence does not end with the requested terminator"
    body = seq[len(OSC_PREFIX) : -len(suffix)]
    if b":" not in body:
        return "sequence has no ':' separating args from payload"
    arg_blob, payload_b64 = body.split(b":", 1)
    try:
        arg_blob.decode("utf-8")
    except UnicodeDecodeError:
        return "parameter list is not valid UTF-8"
    for part in arg_blob.split(b";"):
        if part and b"=" not in part:
            return f"malformed parameter {part!r}"
    try:
        decoded = base64.b64decode(payload_b64, validate=True)
    except binascii.Error as exc:
        return f"payload is not valid base64: {exc}"
    if decoded != payload:
        return (
            "payload mismatch: decoded "
            f"{len(decoded)} bytes, expected {len(payload)} bytes"
        )
    return None


def make_png(width: int, height: int, color: Tuple[int, int, int]) -> bytes:
    """Create a solid-colour 8-bit RGB PNG using only zlib and struct."""
    red, green, blue = color
    row = b"\x00" + bytes((red, green, blue)) * width
    raw = row * height

    def chunk(tag: bytes, data: bytes) -> bytes:
        return (
            struct.pack(">I", len(data))
            + tag
            + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
        )

    ihdr = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", ihdr)
        + chunk(b"IDAT", zlib.compress(raw, 9))
        + chunk(b"IEND", b"")
    )


# --------------------------------------------------------------------------
# matrix
# --------------------------------------------------------------------------


def matrix_cases() -> List[Case]:
    """Return the protocol coverage cases used by --matrix/--matrix-emit."""
    png = make_png(4, 4, (0x33, 0x66, 0x99))
    empty = b""
    oversized = deterministic_bytes(1024 * 1024)

    def args_for(**kwargs: object) -> Tuple[str, ...]:
        return tuple(build_args(**kwargs))  # type: ignore[arg-type]

    full_name = "diagram.png"
    unicode_name = "caf\u00e9 \u2603.png"

    return [
        Case("minimal (payload only, ST)", png, (), "st"),
        Case(
            "full args (name, size, width, height, preserve, inline, no-move)",
            png,
            args_for(
                name=full_name,
                size=len(png),
                width="10",
                height="5",
                preserve_aspect_ratio="1",
                inline="1",
                do_not_move_cursor=True,
            ),
            "st",
        ),
        Case("width in cells (width=20)", png, args_for(width="20"), "st"),
        Case("width in pixels (width=200px)", png, args_for(width="200px"), "st"),
        Case("width percent (width=50%)", png, args_for(width="50%"), "st"),
        Case("height only (height=8)", png, args_for(height="8"), "st"),
        Case(
            "preserveAspectRatio=0",
            png,
            args_for(width="10", preserve_aspect_ratio="0"),
            "st",
        ),
        Case(
            "preserveAspectRatio=1",
            png,
            args_for(width="10", preserve_aspect_ratio="1"),
            "st",
        ),
        Case("inline=0", png, args_for(inline="0"), "st"),
        Case(
            "doNotMoveCursor=1",
            png,
            args_for(do_not_move_cursor=True),
            "st",
        ),
        Case(
            "name with non-ASCII (base64 name)",
            png,
            args_for(name=unicode_name, size=len(png)),
            "st",
        ),
        Case("terminator BEL", png, args_for(size=len(png)), "bel"),
        Case("terminator ST", png, args_for(size=len(png)), "st"),
        Case("zero-size image (empty payload)", empty, args_for(size=0), "st"),
        Case(
            "oversized image (1 MiB payload)",
            oversized,
            args_for(size=len(oversized), width="auto", height="auto"),
            "st",
        ),
    ]


# --------------------------------------------------------------------------
# output
# --------------------------------------------------------------------------


def print_dry_run(
    core: bytes,
    args: Sequence[str],
    payload: bytes,
    terminator: str,
    count: int,
    delay: float,
    newline: bool,
    *,
    case_index: int = 0,
    case_total: int = 0,
    case_label: str = "",
) -> None:
    """Print a stable, parseable description of the bytes that would be written."""
    full = core * count
    if newline and count:
        full += b"\n"
    encoded = b64(payload)
    roundtrip = base64.b64decode(encoded, validate=True) == payload
    case_value = (
        f"{case_index}/{case_total} {case_label}".rstrip()
        if case_total
        else "normal"
    )
    lines = [
        "emit_imgcat_dry_run=1",
        f"case={case_value}",
        f"terminator={terminator}",
        f"terminator_hex={terminator_bytes(terminator).hex()}",
        f"args={';'.join(args)}",
        f"arg_count={len(args)}",
        f"payload_len={len(payload)}",
        f"payload_b64_len={len(encoded)}",
        f"payload_sha256={hashlib.sha256(payload).hexdigest()}",
        f"payload_base64_roundtrip={'true' if roundtrip else 'false'}",
        f"count={count}",
        f"delay={delay:g}",
        f"newline={'true' if newline else 'false'}",
        f"sequence_len={len(core)}",
        f"wire_len={len(full)}",
        f"wire_sha256={hashlib.sha256(full).hexdigest()}",
        f"sequence_repr={core!r}",
        f"wire_repr={full!r}",
        "dry_run=ok",
    ]
    sys.stdout.buffer.write(("\n".join(lines) + "\n").encode("utf-8"))
    sys.stdout.buffer.flush()


def write_matrix(
    cases: Sequence[Case],
    *,
    dry_run: bool,
    verify: bool,
    labels: bool,
    quiet: bool,
) -> int:
    total = len(cases)
    for index, case in enumerate(cases, 1):
        core = emit_sequence(case.args, case.payload, case.terminator)
        if verify:
            problem = verify_sequence(core, case.payload, case.terminator)
            if problem is not None:
                sys.stderr.write(f"emit_imgcat: verify failed for case {index}: {problem}\n")
                return 1
            if not quiet:
                sys.stderr.write(
                    f"verify ok: case={index} payload_len={len(case.payload)} "
                    f"sha256={hashlib.sha256(case.payload).hexdigest()}\n"
                )
        if labels:
            sys.stderr.write(f"case {index:02d}/{total:02d}: {case.label}\n")
        if dry_run:
            print_dry_run(
                core,
                case.args,
                case.payload,
                case.terminator,
                1,
                0.0,
                False,
                case_index=index,
                case_total=total,
                case_label=case.label,
            )
            sys.stdout.buffer.write(b"\n")
        else:
            sys.stdout.buffer.write(core + b"\n")
    if not dry_run:
        sys.stdout.buffer.flush()
    return 0


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="emit_imgcat.py",
        description=(
            "Emit iTerm2 OSC 1337 inline-image sequences "
            "(ESC ] 1337 ; File=<args> : <base64> ST)."
        ),
        epilog=PROTOCOL_HELP,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )

    parser.add_argument(
        "file",
        nargs="?",
        metavar="FILE",
        help=(
            "image file to read; omit or pass '-' to read image bytes from stdin. "
            "With --png/--raw-bytes, '-' and /dev/stdout are accepted as a "
            "no-op output marker."
        ),
    )

    source = parser.add_argument_group("payload source")
    source.add_argument(
        "--png",
        metavar="WIDTHxHEIGHT",
        help="generate a solid-colour PNG (zlib/struct only); makes FILE unnecessary",
    )
    source.add_argument(
        "--png-color",
        metavar="RRGGBB",
        default=None,
        help="PNG colour for --png (default 000000; accepts optional '#')",
    )
    source.add_argument(
        "--raw-bytes",
        metavar="N",
        default=None,
        help="generate N deterministic bytes instead of reading an image",
    )

    params = parser.add_argument_group("wire parameters (all omitted unless set)")
    params.add_argument(
        "--name",
        metavar="NAME",
        default=None,
        help="image name parameter (base64 of UTF-8 by default)",
    )
    params.add_argument(
        "--name-encoding",
        choices=("raw", "base64", "none"),
        default="base64",
        help="how --name is encoded: base64 (default), raw, or none (omit name)",
    )
    params.add_argument(
        "--size",
        metavar="BYTES|auto",
        default=None,
        help="size metadata; 'auto' uses the actual payload byte length",
    )
    params.add_argument(
        "--width",
        metavar="VALUE",
        default=None,
        help="width parameter: N cells, Npx, N%%, or auto",
    )
    params.add_argument(
        "--height",
        metavar="VALUE",
        default=None,
        help="height parameter: N cells, Npx, N%%, or auto",
    )
    params.add_argument(
        "--preserve-aspect-ratio",
        choices=("0", "1"),
        default=None,
        dest="preserve_aspect_ratio",
        help="emit preserveAspectRatio=0|1 (default: omit)",
    )
    params.add_argument(
        "--no-preserve-aspect-ratio",
        action="store_const",
        const="0",
        dest="preserve_aspect_ratio",
        help="alias for --preserve-aspect-ratio 0",
    )
    params.add_argument(
        "--inline",
        choices=("0", "1"),
        default=None,
        help="emit inline=0|1 (default: omit)",
    )
    params.add_argument(
        "--no-inline",
        action="store_const",
        const="0",
        dest="inline",
        help="alias for --inline 0",
    )
    params.add_argument(
        "--do-not-move-cursor",
        action="store_true",
        dest="do_not_move_cursor",
        help="emit doNotMoveCursor=1",
    )
    params.add_argument(
        "--no-move-cursor",
        action="store_true",
        dest="do_not_move_cursor",
        help="alias for --do-not-move-cursor",
    )

    framing = parser.add_argument_group("framing and repetition")
    framing.add_argument(
        "--terminator",
        choices=("bel", "st"),
        default="st",
        help="sequence terminator: st = ESC backslash (default), bel = 0x07",
    )
    framing.add_argument(
        "--count",
        metavar="N",
        default="1",
        help="repeat the sequence N times (default 1)",
    )
    framing.add_argument(
        "--delay",
        metavar="SECONDS",
        default="0",
        help="sleep between repetitions; fractional seconds allowed (default 0)",
    )
    framing.add_argument(
        "--newline",
        action="store_true",
        help="append one trailing newline to stdout after all repetitions",
    )

    modes = parser.add_argument_group("modes")
    modes.add_argument(
        "--matrix",
        action="store_true",
        help="emit the built-in protocol matrix (labels to stderr, bytes to stdout)",
    )
    modes.add_argument(
        "--matrix-emit",
        action="store_true",
        help="emit matrix bytes without labels (implies matrix mode)",
    )
    modes.add_argument(
        "--dry-run",
        action="store_true",
        help="print byte reprs and payload metadata instead of raw bytes",
    )
    modes.add_argument(
        "--verify",
        action="store_true",
        help="re-parse the sequence and compare the decoded payload with the input",
    )
    modes.add_argument(
        "--quiet",
        action="store_true",
        help="suppress non-error diagnostics (matrix labels, verify notes)",
    )
    return parser


def _check_file_allowed(args: argparse.Namespace) -> None:
    if args.file is not None and args.file not in STDOUT_ALIASES:
        raise UsageError(
            f"FILE {args.file!r} cannot be combined with --png/--raw-bytes; "
            "the payload is generated"
        )


def load_payload(args: argparse.Namespace) -> bytes:
    """Resolve the payload source: --png, --raw-bytes, FILE, or stdin."""
    if args.png_color is not None and args.png is None:
        raise UsageError("--png-color requires --png")

    if args.png is not None:
        if args.raw_bytes is not None:
            raise UsageError("--png and --raw-bytes are mutually exclusive")
        _check_file_allowed(args)
        width, height = parse_png_size(args.png)
        color = parse_color(args.png_color) if args.png_color is not None else (0, 0, 0)
        return make_png(width, height, color)

    if args.raw_bytes is not None:
        _check_file_allowed(args)
        if not UNSIGNED_RE.fullmatch(args.raw_bytes):
            raise UsageError(
                f"--raw-bytes: invalid value {args.raw_bytes!r} "
                "(expected non-negative integer)"
            )
        return deterministic_bytes(int(args.raw_bytes))

    if args.file is None or args.file == "-":
        return sys.stdin.buffer.read()

    if args.file in ("/dev/stdout", "/dev/fd/1"):
        raise UsageError(
            "cannot read image bytes from /dev/stdout; omit FILE or use '-' for stdin"
        )

    with open(args.file, "rb") as handle:
        return handle.read()


def run(args: argparse.Namespace) -> int:
    count = parse_count(args.count)
    delay = parse_delay(args.delay)

    # Validate parameters before touching stdin/FILE so bad usage fails fast.
    if args.width is not None:
        parse_dimension("--width", args.width)
    if args.height is not None:
        parse_dimension("--height", args.height)
    if args.size is not None:
        parse_size(args.size)
    if args.raw_bytes is not None and not UNSIGNED_RE.fullmatch(args.raw_bytes):
        raise UsageError(
            f"--raw-bytes: invalid value {args.raw_bytes!r} "
            "(expected non-negative integer)"
        )
    if args.png is not None:
        parse_png_size(args.png)
        if args.png_color is not None:
            parse_color(args.png_color)
    if args.name is not None and args.name_encoding == "raw":
        if any(ch in args.name for ch in ";:\r\n\x00"):
            raise UsageError(
                "--name: raw names cannot contain ';', ':', CR, LF, or NUL; "
                "use --name-encoding base64"
            )

    if args.matrix or args.matrix_emit:
        if args.file is not None:
            raise UsageError("FILE is not used with --matrix/--matrix-emit")
        labels = bool(args.matrix and not args.matrix_emit and not args.quiet)
        return write_matrix(
            matrix_cases(),
            dry_run=args.dry_run,
            verify=args.verify,
            labels=labels,
            quiet=args.quiet,
        )

    payload = load_payload(args)

    size: Optional[int] = None
    if args.size == "auto":
        size = len(payload)
    elif args.size is not None:
        size = int(args.size)

    wire_args = build_args(
        name=args.name,
        name_encoding=args.name_encoding,
        size=size,
        width=args.width,
        height=args.height,
        preserve_aspect_ratio=args.preserve_aspect_ratio,
        inline=args.inline,
        do_not_move_cursor=args.do_not_move_cursor,
    )

    core = emit_sequence(wire_args, payload, args.terminator)

    if args.verify:
        problem = verify_sequence(core, payload, args.terminator)
        if problem is not None:
            sys.stderr.write(f"emit_imgcat: verify failed: {problem}\n")
            return 1
        if not args.quiet:
            sys.stderr.write(
                f"verify ok: payload_len={len(payload)} "
                f"sha256={hashlib.sha256(payload).hexdigest()}\n"
            )

    if args.dry_run:
        print_dry_run(
            core,
            wire_args,
            payload,
            args.terminator,
            count,
            delay,
            args.newline,
        )
        return 0

    if count == 0:
        return 0

    try:
        if delay == 0:
            # Write in bounded chunks so very large --count values do not
            # require count * len(core) bytes of memory.
            repetitions_per_chunk = max(
                1, min(count, (8 * 1024 * 1024) // max(1, len(core)))
            )
            remaining = count
            while remaining > 0:
                this_chunk = min(remaining, repetitions_per_chunk)
                sys.stdout.buffer.write(core * this_chunk)
                remaining -= this_chunk
            if args.newline:
                sys.stdout.buffer.write(b"\n")
        else:
            for index in range(count):
                sys.stdout.buffer.write(core)
                sys.stdout.buffer.flush()
                if index < count - 1:
                    time.sleep(delay)
            if args.newline:
                sys.stdout.buffer.write(b"\n")
        sys.stdout.buffer.flush()
    except BrokenPipeError:
        # Be quiet when the consumer closed the pipe (e.g. `| head`).
        try:
            devnull = os.open(os.devnull, os.O_WRONLY)
            os.dup2(devnull, sys.stdout.fileno())
        except OSError:
            pass
        return 0
    except MemoryError:
        sys.stderr.write("emit_imgcat: I/O error: out of memory while writing\n")
        return 1
    return 0


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return run(args)
    except UsageError as exc:
        sys.stderr.write(f"emit_imgcat: error: {exc}\n")
        return 2
    except OSError as exc:
        sys.stderr.write(f"emit_imgcat: I/O error: {exc}\n")
        return 1
    except (binascii.Error, UnicodeError) as exc:
        sys.stderr.write(f"emit_imgcat: decode error: {exc}\n")
        return 1


if __name__ == "__main__":
    sys.exit(main())
