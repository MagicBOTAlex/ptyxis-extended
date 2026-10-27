#!/usr/bin/env python3
"""Thin CLI adapter over the Kitty wire emitter used by kitty-e2e.sh.

Loads `kitty_emit.py` from $KITTY_EMITTER_DIR (if set) or from this directory,
and writes raw APC bytes to stdout / --out.  Keeping every scenario behind this
adapter means the harness can switch to the shared team emitter without changing
any scenario code.

Subcommands:
  png FILE --image-id N [--action t|T] [--chunk N] [--placement-id P]
      [--columns C] [--rows R] [--src X,Y,W,H] [--z Z] [--no-move] [--out F]
  raw --width W --height H --format 24|32 --file RAW --image-id N [--zlib]
      [--action t|T] [--out F]
  place --image-id N [--placement-id P] [--columns C] [--rows R]
      [--src X,Y,W,H] [--z Z] [--no-move] [--out F]
  delete --mode i|I|p|a [--image-id N] [--placement-id P] [--out F]
  query [--image-id N] [--out F]
  count-frames FILE     print the number of APC frames (ESC _ G) in FILE
  dump FILE             escaped dump of FILE (for logs)
"""
import argparse
import importlib.util
import os
import sys


def load_emitter():
    here = os.path.dirname(os.path.abspath(__file__))
    candidates = []
    env = os.environ.get("KITTY_EMITTER_DIR")
    if env:
        candidates.append(os.path.join(env, "kitty_emit.py"))
        candidates.append(os.path.join(env, "scripts", "lib", "kitty_emit.py"))
    candidates.append(os.path.join(here, "kitty_emit.py"))
    for path in candidates:
        if os.path.isfile(path):
            spec = importlib.util.spec_from_file_location("kitty_emit", path)
            mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(mod)
            return mod, path
    raise SystemExit("kitty_wire: kitty_emit.py not found (tried: %s)" % ", ".join(candidates))


def src_tuple(value):
    parts = [int(x) for x in value.split(",")]
    if len(parts) != 4:
        raise argparse.ArgumentTypeError("expected X,Y,W,H")
    return parts


def q_value(a):
    if getattr(a, "q", None) is not None:
        return str(a.q)
    return "2" if getattr(a, "quiet", False) else None


def placement_kwargs(a):
    kw = {}
    if a.placement_id is not None:
        kw["placement_id"] = a.placement_id
    if a.columns is not None:
        kw["columns"] = a.columns
    if a.rows is not None:
        kw["rows"] = a.rows
    if a.src is not None:
        x, y, w, h = a.src
        kw.update(src_x=x, src_y=y, src_w=w, src_h=h)
    if a.z is not None:
        kw["z"] = a.z
    if a.no_move:
        kw["no_cursor_move"] = True
    return kw


def write_out(data, path):
    if path:
        with open(path, "wb") as fh:
            fh.write(data)
    else:
        sys.stdout.buffer.write(data)
        sys.stdout.buffer.flush()


def main(argv):
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("png")
    p.add_argument("--quiet", action="store_true")
    p.add_argument("--q", type=int, choices=(0, 1, 2))
    p.add_argument("file")
    p.add_argument("--image-id", type=int, required=True)
    p.add_argument("--action", default="t")
    p.add_argument("--chunk", type=int, default=4096)
    p.add_argument("--placement-id", type=int)
    p.add_argument("--columns", type=int)
    p.add_argument("--rows", type=int)
    p.add_argument("--src", type=src_tuple)
    p.add_argument("--z", type=int)
    p.add_argument("--no-move", action="store_true")
    p.add_argument("--out")

    p = sub.add_parser("raw")
    p.add_argument("--quiet", action="store_true")
    p.add_argument("--q", type=int, choices=(0, 1, 2))
    p.add_argument("--chunk", type=int, default=4096)
    p.add_argument("--width", type=int, required=True)
    p.add_argument("--height", type=int, required=True)
    p.add_argument("--format", type=int, choices=(24, 32), required=True)
    p.add_argument("--file", required=True)
    p.add_argument("--image-id", type=int, required=True)
    p.add_argument("--zlib", action="store_true")
    p.add_argument("--action", default="t")
    p.add_argument("--out")

    p = sub.add_parser("place")
    p.add_argument("--quiet", action="store_true")
    p.add_argument("--q", type=int, choices=(0, 1, 2))
    p.add_argument("--image-id", type=int, required=True)
    p.add_argument("--placement-id", type=int)
    p.add_argument("--columns", type=int)
    p.add_argument("--rows", type=int)
    p.add_argument("--src", type=src_tuple)
    p.add_argument("--z", type=int)
    p.add_argument("--no-move", action="store_true")
    p.add_argument("--out")

    p = sub.add_parser("delete")
    p.add_argument("--quiet", action="store_true")
    p.add_argument("--q", type=int, choices=(0, 1, 2))
    p.add_argument("--mode", required=True, choices=("i", "I", "p", "a"))
    p.add_argument("--image-id", type=int)
    p.add_argument("--placement-id", type=int)
    p.add_argument("--out")

    p = sub.add_parser("query")
    p.add_argument("--image-id", type=int, default=31337)
    p.add_argument("--out")

    p = sub.add_parser("count-frames")
    p.add_argument("file")

    p = sub.add_parser("dump")
    p.add_argument("file")

    a = ap.parse_args(argv)
    if a.cmd == "count-frames":
        data = open(a.file, "rb").read()
        print(data.count(b"\x1b_G"))
        return 0
    if a.cmd == "dump":
        data = open(a.file, "rb").read()
        out = data.replace(b"\x1b", b"\\e").replace(b"\x07", b"\\a")
        sys.stdout.buffer.write(out[:4000])
        if len(out) > 4000:
            sys.stdout.buffer.write(b"...(%d bytes total)" % len(data))
        sys.stdout.buffer.write(b"\n")
        return 0

    k, _path = load_emitter()
    if a.cmd == "png":
        extra = placement_kwargs(a)
        qv = q_value(a)
        if qv is not None:
            extra["q"] = qv
        data = k.png_frames(a.file, action=a.action, image_id=a.image_id,
                            chunk_size=a.chunk, extra=extra or None,
                            **({"placement_id": a.placement_id} if a.placement_id is not None else {}))
        write_out(data, a.out)
        return 0
    if a.cmd == "raw":
        raw = open(a.file, "rb").read()
        data = k.raw_frames(a.width, a.height, raw, a.format, action=a.action,
                            image_id=a.image_id, zlib_compress=a.zlib,
                            chunk_size=a.chunk,
                            extra=({"q": q_value(a)} if q_value(a) else None))
        write_out(data, a.out)
        return 0
    if a.cmd == "place":
        kw = placement_kwargs(a)
        if q_value(a):
            kw["extra"] = {"q": q_value(a)}
        data = k.placement(image_id=a.image_id, **kw)
        write_out(data, a.out)
        return 0
    if a.cmd == "delete":
        kw = {}
        if a.image_id is not None:
            kw["image_id"] = a.image_id
        if a.placement_id is not None:
            kw["placement_id"] = a.placement_id
        if q_value(a):
            kw["extra"] = {"q": q_value(a)}
        data = k.delete(mode=a.mode, **kw)
        write_out(data, a.out)
        return 0
    if a.cmd == "query":
        data = k.query(image_id=a.image_id)
        write_out(data, a.out)
        return 0
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
