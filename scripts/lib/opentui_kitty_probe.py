#!/usr/bin/env python3
"""opentui_kitty_probe.py - prove OpenTUI's Kitty-graphics client path in a pty.

Runs an OpenTUI demo in a pseudo-terminal, watches for the Kitty graphics probe
(`ESC _ G i=31337,s=1,v=1,a=q,t=d,f=24;AAAA ST`), optionally answers it with
`ESC _ G i=31337;OK ST`, then captures and classifies the graphics APC sequences.

This simulates the terminal side, so it does not need a Kitty-capable terminal
and does not need X. It is the evidence generator for
scripts/opentui-kitty-findings.md; use opentui_kitty_demo.sh when a real
Ptyxis/VTE window is available.

Usage:
  scripts/lib/opentui_kitty_probe.py --demo-dir DIR [--entry FILE]
                                     [--duration SEC] [--no-answer]
                                     [--out FILE]

Exit status: 0 when the expected traffic was observed (`a=t` + `a=p` with
--answer, no transmit/placement with --no-answer), 1 otherwise, 2 on usage or
spawn errors. Prints one JSON object; the raw pty bytes go to --out.
"""

import argparse
import fcntl
import json
import os
import pty
import re
import select
import signal
import struct
import subprocess
import sys
import termios
import time

KITTY_QUERY = b"\x1b_Gi=31337,s=1,v=1,a=q,t=d,f=24;AAAA\x1b\\"
BLOCK_GLYPHS = ["▀", "▄", "▛", "▜", "▙", "▟", "▘", "▝"]


def escape(data: bytes) -> str:
    out = []
    for byte in data:
        if byte == 0x1B:
            out.append("\\x1b")
        elif 32 <= byte < 127:
            out.append(chr(byte))
        elif byte == 10:
            out.append("\\n")
        elif byte == 13:
            out.append("\\r")
        else:
            out.append("\\x%02x" % byte)
    return "".join(out)


def classify(data: bytes):
    counts = {"query": 0, "transmit": 0, "placement": 0, "delete": 0, "chunk": 0}
    first = {}
    for match in re.finditer(rb"\x1b_G[\s\S]*?\x1b\\", data):
        seq = match.group(0)
        body = seq[3:-2]
        if b"a=q" in body:
            name = "query"
        elif b"a=t" in body:
            name = "transmit"
        elif b"a=p" in body:
            name = "placement"
        elif b"a=d" in body:
            name = "delete"
        else:
            name = "chunk"
        counts[name] += 1
        first.setdefault(name, (match.start(), seq))

    blocks = sum(data.count(glyph.encode()) for glyph in BLOCK_GLYPHS)
    return {
        "bytes": len(data),
        "counts": counts,
        "block_glyphs": blocks,
        "first": {
            name: {"offset": offset, "escaped": escape(seq[:160])}
            for name, (offset, seq) in first.items()
        },
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--demo-dir", required=True, help="dir containing the demo entry and node_modules")
    ap.add_argument("--entry", default="src/native-image-demo.ts")
    ap.add_argument("--bun", default=os.environ.get("BUN", "/home/metal/.bun/bin/bun"))
    ap.add_argument("--duration", type=float, default=4.0)
    ap.add_argument("--no-answer", action="store_true", help="do not answer the Kitty probe")
    ap.add_argument("--out", default="/tmp/opencode/opentui-kitty-probe.bin")
    args = ap.parse_args()

    if not os.path.isfile(os.path.join(args.demo_dir, args.entry)):
        print(json.dumps({"error": f"entry not found: {args.demo_dir}/{args.entry}"}))
        return 2
    if not os.path.isfile(args.bun):
        print(json.dumps({"error": f"bun not found: {args.bun}"}))
        return 2

    env = dict(os.environ)
    env["TERM"] = "xterm-256color"
    env["COLORTERM"] = "truecolor"
    env.pop("TERM_PROGRAM", None)
    env.pop("KITTY_WINDOW_ID", None)
    runtime = "/tmp/opencode/xdg-runtime"
    os.makedirs(runtime, exist_ok=True)
    os.chmod(runtime, 0o700)
    env["XDG_RUNTIME_DIR"] = runtime

    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
    proc = subprocess.Popen(
        [args.bun, args.entry],
        cwd=args.demo_dir,
        env=env,
        stdin=slave,
        stdout=slave,
        stderr=slave,
        preexec_fn=os.setsid,
        close_fds=True,
    )
    os.close(slave)
    os.set_blocking(master, False)

    buf = bytearray()
    answered = {"kitty": 0, "da1": 0, "dsr": 0, "pixel": 0}
    seen = 0
    deadline = time.time() + args.duration

    def reply(payload: bytes) -> None:
        try:
            os.write(master, payload)
        except OSError:
            pass

    while time.time() < deadline:
        ready, _, _ = select.select([master], [], [], 0.005)
        if master in ready:
            try:
                chunk = os.read(master, 1 << 20)
            except (OSError, BlockingIOError):
                chunk = b""
            if chunk:
                buf.extend(chunk)
        window = bytes(buf[seen:])
        if not args.no_answer:
            if b"a=q,t=d,f=24;AAAA\x1b\\" in window and answered["kitty"] == 0:
                reply(b"\x1b_Gi=31337;OK\x1b\\")
                answered["kitty"] += 1
            # DA1 marks the end of OpenTUI's startup reply batch.
            if b"\x1b[c" in window and answered["da1"] == 0:
                reply(b"\x1b[?62;22;52c")
                answered["da1"] += 1
            if b"\x1b[6n" in window and answered["dsr"] < 8:
                reply(b"\x1b[1;1R")
                answered["dsr"] += 1
            if b"\x1b[14t" in window and answered["pixel"] == 0:
                reply(b"\x1b[4;480;800t")
                answered["pixel"] += 1
        seen = len(buf)

    try:
        os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
    except OSError:
        pass
    time.sleep(0.2)
    try:
        os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
    except OSError:
        pass
    try:
        proc.wait(timeout=3)
    except subprocess.TimeoutExpired:
        pass

    os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)
    with open(args.out, "wb") as fh:
        fh.write(buf)

    result = classify(bytes(buf))
    result.update({
        "demo_dir": args.demo_dir,
        "entry": args.entry,
        "answered": answered,
        "kitty_query": result["counts"]["query"] > 0,
        "kitty_path": result["counts"]["transmit"] > 0 and result["counts"]["placement"] > 0,
        "raw_capture": args.out,
    })
    if args.no_answer:
        ok = result["counts"]["transmit"] == 0 and result["counts"]["placement"] == 0
    else:
        ok = result["kitty_path"]
    result["verdict"] = "PASS" if ok else "FAIL"
    print(json.dumps(result, indent=2))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
