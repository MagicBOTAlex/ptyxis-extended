#!/usr/bin/env python3
"""Run a command on a pty, relaying the real tty's input (terminal replies
included) into it and copying its output back to the tty while capturing it.

OpenTUI reads the Kitty probe reply from stdin. `script(1)` does not forward the
terminal's replies, so the demo falls back to Unicode blocks. This relay runs in
the foreground of the terminal (so it may read the tty), spawns the demo on a
new pty, and copies both directions. The raw child output is saved for
assertions (APC query/transmit/placement frames).

Usage: pty_tee.py --out FILE --timeout SEC [--cwd DIR] -- CMD [ARGS...]
Exit 0 if output was captured, 1 otherwise.
"""
import argparse
import fcntl
import os
import pty
import select
import signal
import subprocess
import sys
import termios
import time
import tty


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--timeout", type=float, default=10.0)
    ap.add_argument("--cwd", default=None)
    ap.add_argument("--max-capture", type=int, default=32 * 1024 * 1024)
    ap.add_argument("cmd", nargs=argparse.REMAINDER)
    a = ap.parse_args(argv)
    cmd = a.cmd[1:] if a.cmd and a.cmd[0] == "--" else a.cmd
    if not cmd:
        print("pty_tee: no command", file=sys.stderr)
        return 2
    if not os.isatty(0):
        print("pty_tee: stdin is not a tty", file=sys.stderr)
        return 2

    old = termios.tcgetattr(0)
    master, slave = pty.openpty()
    proc = None
    try:
        try:
            fcntl.ioctl(slave, termios.TIOCSWINSZ,
                        fcntl.ioctl(0, termios.TIOCGWINSZ, b"\0" * 8))
        except OSError:
            pass
        proc = subprocess.Popen(cmd, stdin=slave, stdout=slave, stderr=slave,
                                cwd=a.cwd, preexec_fn=os.setsid, close_fds=True)
        os.close(slave)
        tty.setraw(0, when=termios.TCSANOW)  # keep any queued terminal replies
        capture = bytearray()
        deadline = time.time() + a.timeout
        while time.time() < deadline and proc.poll() is None:
            r, _, _ = select.select([0, master], [], [], 0.1)
            if 0 in r:
                try:
                    data = os.read(0, 65536)
                except OSError:
                    data = b""
                if data:
                    try:
                        os.write(master, data)
                    except OSError:
                        pass
            if master in r:
                try:
                    data = os.read(master, 65536)
                except OSError:
                    data = b""
                if not data:
                    break
                if len(capture) < a.max_capture:
                    capture.extend(data[: a.max_capture - len(capture)])
                try:
                    os.write(1, data)
                except OSError:
                    pass
    finally:
        termios.tcsetattr(0, termios.TCSADRAIN, old)
        if proc is not None:
            try:
                os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
            except (OSError, ProcessLookupError):
                pass
        try:
            os.close(master)
        except OSError:
            pass

    with open(a.out, "wb") as fh:
        fh.write(capture)
    print("pty_tee: captured %d bytes" % len(capture), file=sys.stderr)
    return 0 if capture else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
