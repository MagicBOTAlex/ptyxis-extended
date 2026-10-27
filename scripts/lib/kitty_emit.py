#!/usr/bin/env python3
"""Byte-exact emitter for the Kitty graphics protocol (APC G).

Standalone: python3 standard library only.  ``png`` needs Pillow; nothing else
does.

Wire format::

    ESC _ G <control-data> ; <base64 payload> ESC \\

``control-data`` is a comma-separated ``key=value`` list in insertion order.
Frames without a payload (``a=p``, ``a=d``) omit the ``;`` and the payload.
Payloads are standard base64 without newlines and are split into chunks of at
most *chunk_size* base64 characters:

* the first chunk carries the caller's control data plus ``m=1`` when more
  chunks follow;
* continuation chunks carry only ``m=1`` (middle) or ``m=0`` (last) plus their
  base64 chunk;
* a payload that fits in one chunk gets no ``m`` key at all.

Usage:
    kitty_emit.py png FILE --image-id N [--action t|T] [--placement-id P]
                  [--columns C] [--rows R] [--chunk-size N] [--out FILE]
    kitty_emit.py raw --width W --height H --format 24|32 --rgb RRGGBB
                  [--alpha A] --image-id N [--zlib] [--out FILE]
    kitty_emit.py place --image-id N [--placement-id P] [--columns C]
                  [--rows R] [--src x,y,w,h] [--z Z] [--no-cursor-move]
                  [--out FILE]
    kitty_emit.py delete --mode i|I|p|a [--image-id N] [--placement-id P]
                  [--out FILE]
    kitty_emit.py query [--image-id N] [--out FILE]
    kitty_emit.py selftest

Raw bytes go to stdout unless ``--out`` is given.  Exit codes: 0 = ok,
2 = usage/argument error (also when the emitted stream fails its own checks).
"""

import argparse
import base64
import io
import sys
import zlib

__all__ = [
    "apc",
    "build",
    "png_frames",
    "raw_frames",
    "placement",
    "delete",
    "query",
    "parse_reply",
    "has_ok_reply",
    "ESC",
    "APC_START",
    "APC_END",
]

ESC = b"\x1b"
APC_START = b"\x1b_G"
APC_END = b"\x1b\\"

DEFAULT_CHUNK_SIZE = 4096

# Characters that would corrupt a control-data section or the framing.
_FORBIDDEN_KEY_CHARS = set("=,;")
_FORBIDDEN_VALUE_CHARS = set(",;")


class ArgError(Exception):
    """User-facing argument/protocol error; maps to exit code 2."""


# --------------------------------------------------------------------------
# control-data helpers
# --------------------------------------------------------------------------

def _text(value):
    """Render an int/str control value as wire text."""
    if isinstance(value, bool):
        return "1" if value else "0"
    if isinstance(value, (int, str)):
        return str(value)
    raise ArgError("control value must be int or str, got %r" % (value,))


def _check_control(control):
    for key, value in control.items():
        if not isinstance(key, str) or not key:
            raise ArgError("control key must be a non-empty string: %r" % (key,))
        if any(ch in _FORBIDDEN_KEY_CHARS or ch in "\r\n" for ch in key):
            raise ArgError("invalid character in control key %r" % (key,))
        rendered = _text(value)
        if any(ch in _FORBIDDEN_VALUE_CHARS or ch in "\r\n" for ch in rendered):
            raise ArgError("invalid character in control value %r=%r" % (key, rendered))


def _control_bytes(control):
    _check_control(control)
    return ",".join("%s=%s" % (key, _text(value))
                    for key, value in control.items()).encode("ascii")


def _base(control, key, value):
    """Append ``key=value`` to a control dict when *value* is not None."""
    if value is not None:
        control[key] = _text(value)


def _merge_extra(control, extra):
    if not extra:
        return control
    merged = dict(control)
    for key, value in extra.items():
        if value is None:
            continue
        merged[key] = _text(value)
    return merged


# --------------------------------------------------------------------------
# framing
# --------------------------------------------------------------------------

def apc(control, payload_b64=""):
    """Emit one APC frame.

    ``control`` is the already-formatted control-data string (or bytes).
    ``payload_b64`` is the already-base64-encoded payload; when empty the
    ``;`` separator is omitted.
    """
    if isinstance(control, str):
        control = control.encode("ascii")
    if isinstance(payload_b64, str):
        payload_b64 = payload_b64.encode("ascii")
    if payload_b64:
        return APC_START + control + b";" + payload_b64 + APC_END
    return APC_START + control + APC_END


def _chunks(text, chunk_size):
    if not isinstance(chunk_size, int) or isinstance(chunk_size, bool) or chunk_size < 4:
        raise ArgError("chunk_size must be an integer >= 4")
    if chunk_size % 4:
        # Kitty's base64 chunks are conventionally multiples of four.
        raise ArgError("chunk_size must be a multiple of 4, got %d" % chunk_size)
    return [text[i:i + chunk_size] for i in range(0, len(text), chunk_size)]


def build(control, payload, *, chunk_size=DEFAULT_CHUNK_SIZE):
    """Encode *payload*, split it, and return the concatenated APC frames."""
    if not isinstance(control, dict):
        raise ArgError("control must be a dict")
    b64 = base64.b64encode(payload or b"").decode("ascii")
    if not b64:
        return apc(_control_bytes(control))

    chunks = _chunks(b64, chunk_size)
    if len(chunks) == 1:
        return apc(_control_bytes(control), chunks[0])

    first = dict(control)
    first["m"] = "1"
    out = [apc(_control_bytes(first), chunks[0])]
    last = len(chunks) - 1
    for index, chunk in enumerate(chunks[1:], start=1):
        out.append(apc("m=0" if index == last else "m=1", chunk))
    return b"".join(out)


# --------------------------------------------------------------------------
# image sources
# --------------------------------------------------------------------------

def _png_payload(path):
    try:
        from PIL import Image
    except ImportError:  # pragma: no cover - environment guard
        raise ArgError("Pillow (PIL) is required for the png command")
    buf = io.BytesIO()
    with Image.open(path) as image:
        image.save(buf, format="PNG")
    return buf.getvalue()


def png_frames(path, *, action="t", image_id, placement_id=None, extra=None,
               chunk_size=DEFAULT_CHUNK_SIZE):
    """Transmit a PNG file (``f=100,t=d``) as one or more APC frames."""
    control = {"a": action, "f": "100", "t": "d", "i": _text(image_id)}
    _base(control, "p", placement_id)
    control = _merge_extra(control, extra)
    return build(control, _png_payload(path), chunk_size=chunk_size)


def _check_raw(width, height, data, fmt):
    if not isinstance(width, int) or not isinstance(height, int):
        raise ArgError("width and height must be integers")
    if width <= 0 or height <= 0:
        raise ArgError("width and height must be positive")
    if fmt not in (24, 32):
        raise ArgError("format must be 24 or 32, got %r" % (fmt,))
    expected = width * height * (fmt // 8)
    if len(data) != expected:
        raise ArgError("raw payload is %d bytes, expected %d for %dx%d f=%d"
                       % (len(data), expected, width, height, fmt))


def raw_frames(width, height, rgb_or_rgba, fmt, *, action="t", image_id,
               extra=None, chunk_size=DEFAULT_CHUNK_SIZE, zlib_compress=False):
    """Transmit raw RGB (``f=24``) or RGBA (``f=32``) pixels."""
    data = bytes(rgb_or_rgba or b"")
    _check_raw(width, height, data, fmt)
    control = {"a": action, "f": _text(fmt), "s": _text(width),
               "v": _text(height), "t": "d", "i": _text(image_id)}
    if zlib_compress:
        control["o"] = "z"
        data = zlib.compress(data)
    control = _merge_extra(control, extra)
    return build(control, data, chunk_size=chunk_size)


# --------------------------------------------------------------------------
# placement / delete / query
# --------------------------------------------------------------------------

def placement(image_id, *, placement_id=None, columns=None, rows=None,
              src_x=None, src_y=None, src_w=None, src_h=None, z=None,
              no_cursor_move=None, extra=None):
    """Build an ``a=p`` frame (no payload)."""
    control = {"a": "p", "i": _text(image_id)}
    _base(control, "p", placement_id)
    _base(control, "c", columns)
    _base(control, "r", rows)
    _base(control, "x", src_x)
    _base(control, "y", src_y)
    _base(control, "w", src_w)
    _base(control, "h", src_h)
    _base(control, "z", z)
    if no_cursor_move:
        control["C"] = "1"
    control = _merge_extra(control, extra)
    return apc(_control_bytes(control))


DELETE_MODES = ("i", "I", "p", "a")


def delete(*, mode, image_id=None, placement_id=None, extra=None):
    """Build an ``a=d`` frame with ``d=<mode>`` (no payload)."""
    mode = str(mode)
    if mode not in DELETE_MODES:
        raise ArgError("delete mode must be one of %s, got %r"
                       % (",".join(DELETE_MODES), mode))
    control = {"a": "d", "d": mode}
    _base(control, "i", image_id)
    _base(control, "p", placement_id)
    control = _merge_extra(control, extra)
    return apc(_control_bytes(control))


def query(image_id=31337, *, fmt=24, width=1, height=1,
          payload=b"\x00\x00\x00"):
    """Build the exact single-pixel capability probe."""
    control = "i=%s,s=%s,v=%s,a=q,t=d,f=%s" % (
        _text(image_id), _text(width), _text(height), _text(fmt))
    b64 = base64.b64encode(payload or b"").decode("ascii")
    return apc(control, b64)


# --------------------------------------------------------------------------
# reply parsing
# --------------------------------------------------------------------------

def parse_reply(data):
    """Parse ``ESC_G<control>;<message>ESC\\`` replies into dicts.

    Each dict holds the decoded control keys plus ``message``.  A reply
    without ``;`` yields an empty message.  Bytes before, between, or after
    replies are ignored.
    """
    if isinstance(data, str):
        data = data.encode("utf-8")
    replies = []
    pos = 0
    while True:
        start = data.find(APC_START, pos)
        if start < 0:
            break
        end = data.find(APC_END, start + len(APC_START))
        if end < 0:
            break
        body = data[start + len(APC_START):end]
        if b";" in body:
            control, message = body.split(b";", 1)
            message = message.decode("utf-8", "replace")
        else:
            control, message = body, ""
        reply = {}
        for field in control.decode("utf-8", "replace").split(","):
            if not field:
                continue
            key, sep, value = field.partition("=")
            reply[key.strip()] = value if sep else ""
        reply["message"] = message
        replies.append(reply)
        pos = end + len(APC_END)
    return replies


def has_ok_reply(data, image_id):
    """True iff a reply carries ``i=<image_id>`` and the message ``OK``."""
    wanted = _text(image_id)
    return any(reply.get("i") == wanted and reply.get("message", "").strip() == "OK"
               for reply in parse_reply(data))


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------

def _parse_src(text):
    parts = [part.strip() for part in text.split(",")]
    if len(parts) != 4 or not all(part.lstrip("-").isdigit() for part in parts):
        raise ArgError("--src must be x,y,w,h, got %r" % (text,))
    return [int(part) for part in parts]


def _parse_color(text):
    raw = text.strip().lstrip("#")
    if len(raw) != 6:
        raise ArgError("--rgb must be RRGGBB, got %r" % (text,))
    try:
        return tuple(int(raw[i:i + 2], 16) for i in (0, 2, 4))
    except ValueError:
        raise ArgError("--rgb must be RRGGBB, got %r" % (text,))


def _build_from_args(args):
    if args.command == "png":
        extra = {}
        if args.columns is not None:
            extra["c"] = args.columns
        if args.rows is not None:
            extra["r"] = args.rows
        return png_frames(args.file, action=args.action,
                          image_id=args.image_id,
                          placement_id=args.placement_id,
                          extra=extra or None,
                          chunk_size=args.chunk_size)

    if args.command == "raw":
        if args.format == 24 and args.alpha is not None:
            raise ArgError("--alpha requires --format 32")
        pixel = _parse_color(args.rgb)
        if args.format == 32:
            pixel = pixel + ((args.alpha if args.alpha is not None else 255),)
        data = bytes(pixel) * (args.width * args.height)
        return raw_frames(args.width, args.height, data, args.format,
                          image_id=args.image_id, zlib_compress=args.zlib,
                          chunk_size=args.chunk_size)

    if args.command == "place":
        src = _parse_src(args.src) if args.src else None
        return placement(
            args.image_id,
            placement_id=args.placement_id,
            columns=args.columns,
            rows=args.rows,
            src_x=src[0] if src else None,
            src_y=src[1] if src else None,
            src_w=src[2] if src else None,
            src_h=src[3] if src else None,
            z=args.z,
            no_cursor_move=args.no_cursor_move,
        )

    if args.command == "delete":
        if args.mode in ("i", "I") and args.image_id is None:
            raise ArgError("delete --mode %s requires --image-id" % args.mode)
        if args.mode == "p" and args.placement_id is None:
            raise ArgError("delete --mode p requires --placement-id")
        return delete(mode=args.mode, image_id=args.image_id,
                      placement_id=args.placement_id)

    if args.command == "query":
        return query(args.image_id)

    raise ArgError("unknown command %r" % (args.command,))


def _selftest():
    """Minimal built-in checks; the thorough suite lives in test_kitty_emit.py."""
    ok = True

    def check(label, condition):
        nonlocal ok
        if condition:
            print("ok   %s" % label)
        else:
            ok = False
            print("FAIL %s" % label)

    check("query literal",
          query() == b"\x1b_Gi=31337,s=1,v=1,a=q,t=d,f=24;AAAA\x1b\\")
    check("tiny payload",
          apc("a=t,f=24,i=1", "AAAA")
          == b"\x1b_Ga=t,f=24,i=1;AAAA\x1b\\")
    check("empty payload has no separator",
          apc("a=d,d=a") == b"\x1b_Ga=d,d=a\x1b\\")
    frames = build({"a": "t", "i": "9"}, b"x" * 9000)
    bodies = frames.split(b"\x1b\\")
    check("chunked frame count", len(bodies) == 4)
    check("chunked m flags",
          bodies[0].startswith(b"\x1b_Ga=t,i=9,m=1;")
          and bodies[1].startswith(b"\x1b_Gm=1;")
          and bodies[2].startswith(b"\x1b_Gm=0;"))
    check("reply ok", has_ok_reply(b"\x1b_Gi=5;OK\x1b\\", 5))
    return 0 if ok else 2


def build_parser():
    parser = argparse.ArgumentParser(
        prog="kitty_emit.py",
        description="Emit byte-exact Kitty graphics protocol frames.")
    sub = parser.add_subparsers(dest="command", required=True)

    png = sub.add_parser("png", help="transmit a PNG file")
    png.add_argument("file")
    png.add_argument("--image-id", type=int, required=True)
    png.add_argument("--action", choices=("t", "T"), default="t")
    png.add_argument("--placement-id", type=int)
    png.add_argument("--columns", type=int)
    png.add_argument("--rows", type=int)
    png.add_argument("--chunk-size", type=int, default=DEFAULT_CHUNK_SIZE)
    png.add_argument("--out")

    raw = sub.add_parser("raw", help="transmit solid-colour raw pixels")
    raw.add_argument("--width", type=int, required=True)
    raw.add_argument("--height", type=int, required=True)
    raw.add_argument("--format", type=int, choices=(24, 32), required=True)
    raw.add_argument("--rgb", required=True)
    raw.add_argument("--alpha", type=int)
    raw.add_argument("--image-id", type=int, required=True)
    raw.add_argument("--zlib", action="store_true")
    raw.add_argument("--chunk-size", type=int, default=DEFAULT_CHUNK_SIZE)
    raw.add_argument("--out")

    place = sub.add_parser("place", help="place an image (a=p)")
    place.add_argument("--image-id", type=int, required=True)
    place.add_argument("--placement-id", type=int)
    place.add_argument("--columns", type=int)
    place.add_argument("--rows", type=int)
    place.add_argument("--src")
    place.add_argument("--z", type=int)
    place.add_argument("--no-cursor-move", action="store_true")
    place.add_argument("--out")

    delete_p = sub.add_parser("delete", help="delete images/placements (a=d)")
    delete_p.add_argument("--mode", choices=DELETE_MODES, required=True)
    delete_p.add_argument("--image-id", type=int)
    delete_p.add_argument("--placement-id", type=int)
    delete_p.add_argument("--out")

    query_p = sub.add_parser("query", help="emit the capability probe")
    query_p.add_argument("--image-id", type=int, default=31337)
    query_p.add_argument("--out")

    sub.add_parser("selftest", help="run built-in sanity checks")
    return parser


def main(argv=None):
    args = build_parser().parse_args(argv)
    if args.command == "selftest":
        return _selftest()
    try:
        data = _build_from_args(args)
    except ArgError as exc:
        sys.stderr.write("kitty_emit: %s\n" % exc)
        return 2
    except OSError as exc:
        sys.stderr.write("kitty_emit: %s\n" % exc)
        return 2
    if getattr(args, "out", None):
        try:
            with open(args.out, "wb") as handle:
                handle.write(data)
        except OSError as exc:
            sys.stderr.write("kitty_emit: %s\n" % exc)
            return 2
    else:
        try:
            sys.stdout.buffer.write(data)
            sys.stdout.buffer.flush()
        except BrokenPipeError:  # consumer went away, e.g. piped into head
            try:
                sys.stdout.close()
            except OSError:
                pass
            return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
