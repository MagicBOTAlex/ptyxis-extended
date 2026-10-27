#!/usr/bin/env python3
"""Self-tests for scripts/lib/kitty_probe.py (plain python3, no pytest).

Run:  python3 scripts/lib/test_kitty_probe.py

A real terminal is never touched: every test uses one end of
``pty.openpty()``, either through ``run_probe_fd`` / ``run_probe(tty_path=...)``
or through the CLI with ``--tty``.
"""

import os
import pty
import select
import subprocess
import sys
import tempfile
import termios
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
CLI = os.path.join(HERE, "kitty_probe.py")

sys.dont_write_bytecode = True
sys.path.insert(0, HERE)
import kitty_probe  # noqa: E402

PROBE = kitty_probe.DEFAULT_PROBE
OK_REPLY = b"\x1b_Gi=31337;OK\x1b\\"
ERR_REPLY = b"\x1b_Gi=31337;EINVAL:bad image data\x1b\\"

TESTS = []


def test(fn):
    TESTS.append(fn)
    return fn


def eq(actual, expected, label=""):
    if actual != expected:
        raise AssertionError("%s expected %r, got %r" % (label or "value", expected, actual))


class Emulator(threading.Thread):
    """Reads the probe from the master side and optionally replies."""

    def __init__(self, master, reply, timeout=3.0):
        super().__init__(daemon=True)
        self.master = master
        self.reply = reply
        self.timeout = timeout
        self.received = b""
        self.error = None

    def run(self):
        deadline = time.time() + self.timeout
        try:
            while time.time() < deadline:
                ready, _, _ = select.select([self.master], [], [], 0.05)
                if not ready:
                    continue
                chunk = os.read(self.master, 4096)
                if not chunk:
                    break
                self.received += chunk
                # The default probe always ends with ESC\, so stop there;
                # otherwise keep draining briefly for late fragments.
                if self.received.endswith(b"\x1b\\"):
                    break
            if self.reply is not None:
                os.write(self.master, self.reply)
        except Exception as exc:  # noqa: BLE001 - surfaced by the test
            self.error = exc


def with_pty(fn, reply=OK_REPLY):
    """Run ``fn(master, slave)`` with an emulator on the master side."""
    master, slave = pty.openpty()
    worker = Emulator(master, reply)
    worker.start()
    try:
        fn(master, slave)
    finally:
        worker.join(timeout=5)
        eq(worker.error, None, "emulator error")
        try:
            os.close(master)
        except OSError:
            pass
        try:
            os.close(slave)
        except OSError:
            pass
    return worker


def run_cli(args, reply=OK_REPLY, timeout=5):
    """Run the CLI against a pty slave via --tty; return (proc, captured)."""
    master, slave = pty.openpty()
    slave_path = os.ttyname(slave)
    worker = Emulator(master, reply)
    worker.start()
    try:
        proc = subprocess.run(
            [sys.executable, CLI, "--tty", slave_path] + list(args),
            capture_output=True, timeout=timeout)
    finally:
        worker.join(timeout=5)
        for fd in (master, slave):
            try:
                os.close(fd)
            except OSError:
                pass
    return proc, worker


# -- 1. probe bytes are written byte-exact and the reply is captured exact ----

@test
def test_probe_and_reply_exact(tmp):
    captured = {}

    def body(master, slave):
        captured["reply"] = kitty_probe.run_probe_fd(
            slave, timeout=1.0, raw_mode=True)

    worker = with_pty(body, reply=OK_REPLY)
    eq(worker.received, PROBE, "probe bytes on pty")
    eq(captured["reply"], OK_REPLY, "reply bytes")


# -- 2. custom probe bytes are sent verbatim --------------------------------

@test
def test_custom_probe_bytes(tmp):
    custom = b"\x1b_Gi=7,s=1,v=1,a=q;QQ==\x1b\\"
    captured = {}

    def body(master, slave):
        captured["reply"] = kitty_probe.run_probe_fd(
            slave, timeout=1.0, probe_bytes=custom, raw_mode=True)

    worker = with_pty(body, reply=b"\x1b_Gi=7;OK\x1b\\")
    eq(worker.received, custom, "custom probe bytes")
    eq(captured["reply"], b"\x1b_Gi=7;OK\x1b\\", "custom reply")


# -- 3. silent terminal returns empty after ~timeout ------------------------

@test
def test_silent_timeout(tmp):
    master, slave = pty.openpty()
    try:
        started = time.time()
        reply = kitty_probe.run_probe_fd(slave, timeout=0.3, raw_mode=True)
        elapsed = time.time() - started
    finally:
        os.close(master)
        os.close(slave)
    eq(reply, b"", "silent reply")
    if not 0.2 <= elapsed < 2.0:
        raise AssertionError("timeout took %.2fs, expected ~0.3s" % elapsed)


# -- 4. termios is restored after a probe -----------------------------------

@test
def test_termios_restored(tmp):
    master, slave = pty.openpty()
    worker = Emulator(master, OK_REPLY)
    worker.start()
    try:
        before = termios.tcgetattr(slave)
        reply = kitty_probe.run_probe_fd(slave, timeout=1.0, raw_mode=True)
        after = termios.tcgetattr(slave)
    finally:
        worker.join(timeout=5)
        os.close(master)
        os.close(slave)
    eq(reply, OK_REPLY, "reply")
    eq(after, before, "termios restored")


# -- 5. run_probe(tty_path=...) opens and closes the tty itself --------------

@test
def test_run_probe_tty_path(tmp):
    master, slave = pty.openpty()
    path = os.ttyname(slave)
    worker = Emulator(master, OK_REPLY)
    worker.start()
    try:
        reply = kitty_probe.run_probe(timeout=1.0, tty_path=path)
    finally:
        worker.join(timeout=5)
        os.close(master)
        os.close(slave)
    eq(reply, OK_REPLY, "reply via tty_path")


# -- 6. extract_replies: OK and error frames --------------------------------

@test
def test_extract_replies(tmp):
    replies = kitty_probe.extract_replies(OK_REPLY)
    eq(len(replies), 1, "one reply")
    control, message = replies[0]
    eq(control.get("i"), "31337", "control id")
    eq(message, b"OK", "message")

    replies = kitty_probe.extract_replies(b"noise" + ERR_REPLY + b"trailing")
    eq(len(replies), 1, "one error reply")
    control, message = replies[0]
    eq(control.get("i"), "31337", "error control id")
    eq(message, b"EINVAL:bad image data", "error message")

    eq(kitty_probe.extract_replies(b""), [], "empty input")
    eq(kitty_probe.extract_replies(b"\x1b_Gi=1;OK"), [], "unterminated frame")


# -- 7. reply_is_ok / --expect-ok semantics ---------------------------------

@test
def test_reply_is_ok(tmp):
    eq(kitty_probe.reply_is_ok(OK_REPLY), True, "plain OK")
    eq(kitty_probe.reply_is_ok(OK_REPLY, 31337), True, "matching id")
    eq(kitty_probe.reply_is_ok(OK_REPLY, 999), False, "wrong id")
    eq(kitty_probe.reply_is_ok(ERR_REPLY), False, "error reply")
    eq(kitty_probe.reply_is_ok(b""), False, "empty")
    # Multiple frames: the OK for the requested id must be found.
    both = b"\x1b_Gi=1;EINVAL:no\x1b\\" + OK_REPLY
    eq(kitty_probe.reply_is_ok(both, 31337), True, "OK after error")


# -- 8. CLI: success, --raw-out, --stdout, --expect-ok ----------------------

@test
def test_cli_ok(tmp):
    raw_out = os.path.join(tmp, "reply.bin")
    proc, worker = run_cli(["--timeout", "1.0", "--raw-out", raw_out,
                            "--stdout", "--expect-ok", "31337"])
    eq(worker.received, PROBE, "cli probe bytes")
    eq(proc.returncode, 0, "exit")
    eq(proc.stdout, OK_REPLY, "stdout raw reply")
    with open(raw_out, "rb") as handle:
        eq(handle.read(), OK_REPLY, "raw-out contents")


# -- 9. CLI: --expect-ok mismatch exits 4 -----------------------------------

@test
def test_cli_expect_ok_mismatch(tmp):
    proc, _ = run_cli(["--timeout", "1.0", "--expect-ok", "4242"])
    eq(proc.returncode, 4, "exit")


# -- 10. CLI: error reply without --expect-ok is still a reply (exit 0) -----

@test
def test_cli_error_reply_is_reply(tmp):
    proc, _ = run_cli(["--timeout", "1.0"], reply=ERR_REPLY)
    eq(proc.returncode, 0, "exit")
    eq(proc.stdout, b"", "quiet by default")


# -- 11. CLI: silence exits 3 ----------------------------------------------

@test
def test_cli_silence(tmp):
    proc, _ = run_cli(["--timeout", "0.2", "--expect-ok", "31337"], reply=None)
    eq(proc.returncode, 3, "exit")


# -- 12. CLI: argument validation ------------------------------------------

@test
def test_cli_bad_args(tmp):
    cases = [
        (["--timeout", "abc"], "non-numeric timeout"),
        (["--timeout", "-1"], "negative timeout"),
        (["--timeout", "0"], "zero timeout"),
        (["--timeout"], "missing timeout value"),
        (["--probe-bytes", "xyz"], "bad hex"),
        (["--probe-bytes", "abc"], "odd hex digits"),
        (["--literal"], "--literal without --probe-bytes"),
    ]
    for args, label in cases:
        proc = subprocess.run([sys.executable, CLI] + args,
                              capture_output=True, timeout=10)
        eq(proc.returncode, 2, "%s exit" % label)


# -- 13. CLI: --literal payload is decoded --------------------------------

@test
def test_cli_literal(tmp):
    payload = r"\e_Gi=55;QQ==\e\\"
    proc, worker = run_cli(["--timeout", "1.0", "--literal",
                            "--probe-bytes", payload],
                           reply=b"\x1b_Gi=55;OK\x1b\\")
    eq(worker.received, b"\x1b_Gi=55;QQ==\x1b\\", "literal probe bytes")
    eq(proc.returncode, 0, "exit")


# -- 14. CLI: --verbose writes a dump to stderr only -----------------------

@test
def test_cli_verbose(tmp):
    proc, _ = run_cli(["--timeout", "1.0", "--verbose"])
    eq(proc.returncode, 0, "exit")
    eq(proc.stdout, b"", "stdout stays clean")
    if b"reply" not in proc.stderr or b"hex:" not in proc.stderr:
        raise AssertionError("verbose dump missing from stderr: %r" % proc.stderr)


def main():
    failures = 0
    started = time.time()
    with tempfile.TemporaryDirectory(prefix="kitty-probe-test-") as tmp:
        for fn in TESTS:
            try:
                fn(tmp)
            except Exception as exc:  # noqa: BLE001 - test harness
                failures += 1
                print("FAIL %s: %s" % (fn.__name__, exc))
            else:
                print("ok   %s" % fn.__name__)
    elapsed = time.time() - started
    passed = len(TESTS) - failures
    print("\n%d passed, %d failed in %.2fs" % (passed, failures, elapsed))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
