#!/usr/bin/env python3
"""Tiny /dev/tty helpers for the Kitty e2e harness (stdlib only).

  kitty_tty.py cursor [--timeout 0.6]   -> prints "<row> <col>" from DSR (ESC[6n)
  kitty_tty.py probe  [--timeout 1.5] [--raw-out FILE]
                                        -> writes the Kitty capability probe and
                                           saves the raw reply; exit 0 if any
                                           reply was received, 3 if silent

Both temporarily switch the tty to raw/-echo and restore the previous termios,
so terminal replies never leak onto the screen and the session's echo-off state
is preserved.
"""
import argparse
import os
import re
import select
import sys
import termios
import time
import tty

PROBE = b"\x1b_Gi=31337,s=1,v=1,a=q,t=d,f=24;AAAA\x1b\\"


def open_tty():
    for path in ("/dev/tty", "/dev/console"):
        try:
            return os.open(path, os.O_RDWR | os.O_NOCTTY)
        except OSError:
            continue
    raise SystemExit("kitty_tty: cannot open /dev/tty")


def exchange(fd, payload, timeout):
    old = termios.tcgetattr(fd)
    data = b""
    try:
        tty.setraw(fd, when=termios.TCSANOW)  # TCSAFLUSH would discard queued replies
        os.write(fd, payload)
        deadline = time.time() + timeout
        while time.time() < deadline:
            r, _, _ = select.select([fd], [], [], 0.1)
            if not r:
                continue
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                break
            if not chunk:
                break
            data += chunk
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, old)
    return data


def main(argv):
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("cursor")
    p.add_argument("--timeout", type=float, default=0.6)
    p = sub.add_parser("drain")
    p.add_argument("--timeout", type=float, default=0.8)
    p.add_argument("--out")
    p = sub.add_parser("probe")
    p.add_argument("--timeout", type=float, default=1.5)
    p.add_argument("--raw-out")
    p.add_argument("--stdout", action="store_true")
    a = ap.parse_args(argv)

    fd = open_tty()
    try:
        if a.cmd == "drain":
            data = exchange(fd, b"", a.timeout)
            if a.out:
                with open(a.out, "wb") as fh:
                    fh.write(data)
            return 0
        if a.cmd == "cursor":
            data = exchange(fd, b"\x1b[6n", a.timeout)
            m = re.search(rb"\[(\d+);(\d+)R", data)
            if not m:
                sys.stderr.write("no DSR reply: %r\n" % data[:120])
                return 3
            print(m.group(1).decode(), m.group(2).decode())
            return 0
        data = exchange(fd, PROBE, a.timeout)
        if a.raw_out:
            with open(a.raw_out, "wb") as fh:
                fh.write(data)
        if a.stdout:
            sys.stdout.buffer.write(data)
            sys.stdout.buffer.flush()
        return 0 if data else 3
    finally:
        os.close(fd)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
