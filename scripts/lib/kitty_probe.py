#!/usr/bin/env python3
"""Probe a terminal for Kitty graphics protocol support via /dev/tty.

The headless Ptyxis/VTE harness runs bash snippets as the terminal's foreground
process through a FIFO, so stdin is *not* the pty.  This helper therefore talks
to ``/dev/tty`` directly (with ``/dev/console`` as a fallback), puts the tty in
raw mode so no line discipline mangles the reply, sends the Kitty capability
query and collects the answer.

Usage:
    kitty_probe.py --timeout 1.5 [--probe-bytes HEX [--literal]]
                   [--raw-out FILE] [--expect-ok ID] [--verbose] [--stdout]

``--literal`` makes ``--probe-bytes`` an escaped text payload instead of hex
(so ``--probe-bytes '\\e_Gi=1;...\\e\\\\' --literal`` works in a shell).

Exit codes:
    0  a reply was received (and --expect-ok, if given, matched)
    2  setup error (no usable tty, bad arguments, terminal misbehaviour)
    3  nothing was received before the timeout
    4  --expect-ok ID was given but ``ESC_Gi=<ID>;OK ESC\\`` was absent

The module is also importable; ``run_probe`` and ``extract_replies`` are the
stable seams used by ``test_kitty_probe.py``.  Tests exercise the same core
through ``run_probe_fd`` with one end of ``pty.openpty()`` instead of ``/dev/tty``.
"""

import argparse
import errno
import os
import re
import select
import sys
import termios
import time
import tty

# Exact Kitty graphics capability query used by OpenTUI: a query (a=q) of a
# 1x1 RGB (f=24) image with an id, payload "AAAA" (one transparent-ish pixel).
DEFAULT_PROBE = b"\x1b_Gi=31337,s=1,v=1,a=q,t=d,f=24;AAAA\x1b\\"

EXIT_OK = 0
EXIT_SETUP = 2
EXIT_NO_REPLY = 3
EXIT_EXPECT_FAILED = 4

_MAX_REPLY = 1 << 20  # 1 MiB: never buffer an unbounded terminal stream

_ESC_G_RE = re.compile(rb"\x1b_G(.*?)\x1b\\", re.DOTALL)


class ProbeError(Exception):
    """Fatal setup/IO problem; maps to exit code 2."""


# --------------------------------------------------------------------------
# reply parsing
# --------------------------------------------------------------------------

def _parse_control(text):
    """Parse a Kitty graphics control string ("i=1,a=q,s=1") into a dict.

    Keys are single letters; values stay strings.  Unknown/malformed pairs are
    kept verbatim under their key so callers can inspect them.
    """
    control = {}
    for field in text.split(","):
        if not field:
            continue
        if "=" in field:
            key, value = field.split("=", 1)
            control[key.strip()] = value
        else:
            # Bare flags (rare, e.g. "q") are recorded with an empty value.
            control[field.strip()] = ""
    return control


def extract_replies(data):
    """Return ``[(control_dict, message), ...]`` for every APC ``ESC_G ... ESC\\``.

    ``message`` is the bytes between the ``;`` separator and the terminator, or
    ``b""`` for control-only replies such as ``ESC_Gi=1;OK ESC\\`` (where OK is
    the message) -- see note below.  Non-APC bytes and incomplete trailing
    escapes are ignored.

    Kitty replies look like ``ESC_Gi=31337;OK ESC\\`` or
    ``ESC_Gi=31337;EINVAL:... ESC\\``.  The control is everything before the
    first ``;``; the message is everything after it.
    """
    replies = []
    if not data:
        return replies
    if isinstance(data, str):
        data = data.encode("utf-8", "surrogateescape")
    for match in _ESC_G_RE.finditer(data):
        body = match.group(1)
        if b";" in body:
            raw_control, message = body.split(b";", 1)
        else:
            raw_control, message = body, b""
        control = _parse_control(raw_control.decode("ascii", "replace"))
        replies.append((control, message))
    return replies


def reply_is_ok(data, image_id=None):
    """True if ``data`` contains an ``OK`` reply, optionally for ``image_id``."""
    wanted = None if image_id is None else str(image_id)
    for control, message in extract_replies(data):
        if message.strip() != b"OK":
            continue
        if wanted is None or control.get("i") == wanted:
            return True
    return False


# --------------------------------------------------------------------------
# core probe
# --------------------------------------------------------------------------

def _read_available(read_fn, fd, deadline, idle_timeout):
    """Read until ``idle_timeout`` passes without data or ``deadline`` is hit.

    Returns the accumulated bytes.  EINTR/EAGAIN are treated as "try again";
    EOF (b"") stops the loop because the peer is gone.
    """
    chunks = []
    total = 0
    last = time.monotonic()
    while total < _MAX_REPLY:
        now = time.monotonic()
        if now >= deadline:
            break
        wait = min(idle_timeout - (now - last), deadline - now)
        if wait <= 0:
            break
        try:
            ready, _, _ = select.select([fd], [], [], wait)
        except InterruptedError:  # EINTR
            continue
        except OSError as exc:
            if exc.errno == errno.EINTR:
                continue
            raise ProbeError("select on tty failed: %s" % exc)
        if not ready:
            # Idle timeout with no new byte: stop.
            break
        try:
            chunk = read_fn(fd, 4096)
        except InterruptedError:
            continue
        except BlockingIOError:
            continue
        except OSError as exc:
            if exc.errno in (errno.EINTR, errno.EAGAIN):
                continue
            raise ProbeError("read from tty failed: %s" % exc)
        if not chunk:
            break  # EOF: nothing more will arrive
        if isinstance(chunk, str):
            chunk = chunk.encode("utf-8", "surrogateescape")
        chunks.append(chunk)
        total += len(chunk)
        last = time.monotonic()
    return b"".join(chunks)


def run_probe_fd(fd, timeout=1.5, probe_bytes=DEFAULT_PROBE,
                 write_fn=None, read_fn=None, raw_mode=False):
    """Probe on an already-open fd.

    ``raw_mode`` is opt-in so that the function can be pointed at a pipe
    without fighting termios.  A pty needs it: in canonical mode a reply
    without a newline would never become readable.  The CLI always passes
    ``raw_mode=True`` for the terminal it opens.

    Returns the raw reply bytes (b"" if none arrived).
    """
    if timeout is None or timeout <= 0:
        raise ProbeError("timeout must be > 0")
    if isinstance(probe_bytes, str):
        probe_bytes = probe_bytes.encode("utf-8", "surrogateescape")
    write_fn = write_fn or _write_all
    read_fn = read_fn or (lambda f, size: os.read(f, size))

    saved = None
    try:
        if raw_mode:
            try:
                saved = termios.tcgetattr(fd)
                tty.setraw(fd)
                # Echo is cleared by setraw; this is belt-and-braces for the
                # (unusual) case of a platform where it is not.
                attrs = termios.tcgetattr(fd)
                attrs[3] &= ~(termios.ECHO | termios.ECHONL)
                termios.tcsetattr(fd, termios.TCSANOW, attrs)
            except termios.error as exc:
                raise ProbeError("cannot configure tty: %s" % exc)

        _flush_input(fd)

        try:
            write_fn(fd, probe_bytes)
        except InterruptedError:
            write_fn(fd, probe_bytes)
        except OSError as exc:
            raise ProbeError("write to tty failed: %s" % exc)

        deadline = time.monotonic() + 3.0 * timeout
        return _read_available(read_fn, fd, deadline, timeout)
    finally:
        if saved is not None:
            try:
                termios.tcsetattr(fd, termios.TCSANOW, saved)
            except termios.error:
                pass


def _write_all(fd, data, retry=3):
    """Write every byte, tolerating EINTR and short writes."""
    view = memoryview(data)
    attempts = 0
    while view:
        try:
            written = os.write(fd, view)
        except InterruptedError:
            attempts += 1
            if attempts >= retry:
                raise
            continue
        if written <= 0:
            raise OSError(errno.EIO, "short write to tty")
        view = view[written:]


def _flush_input(fd):
    """Discard pending input so stale bytes are not mistaken for the reply."""
    try:
        termios.tcflush(fd, termios.TCIFLUSH)
    except (termios.error, OSError):
        pass


def open_tty():
    """Open ``/dev/tty`` (or ``/dev/console``) read-write.

    Raises ProbeError with a clear message when neither is usable.
    """
    failures = []
    for path in ("/dev/tty", "/dev/console"):
        try:
            return path, os.open(path, os.O_RDWR | os.O_NOCTTY)
        except OSError as exc:
            failures.append("%s: %s" % (path, exc.strerror or exc))
    raise ProbeError("no usable controlling terminal (%s)" % "; ".join(failures))


def run_probe(timeout=1.5, probe_bytes=DEFAULT_PROBE, tty_path=None,
              write_fn=None, read_fn=None, raw_mode=True):
    """Open a tty, probe it, restore its state and close it.

    ``tty_path`` overrides the ``/dev/tty`` / ``/dev/console`` search, which is
    the seam tests use (they pass a pty slave path).  Returns the reply bytes.
    """
    if tty_path is not None:
        try:
            fd = os.open(tty_path, os.O_RDWR | os.O_NOCTTY)
        except OSError as exc:
            raise ProbeError("cannot open %s: %s" % (tty_path, exc.strerror or exc))
    else:
        _, fd = open_tty()
    try:
        return run_probe_fd(fd, timeout=timeout, probe_bytes=probe_bytes,
                            write_fn=write_fn, read_fn=read_fn,
                            raw_mode=raw_mode)
    finally:
        os.close(fd)


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------

def _parse_hex(text):
    """Parse a hex byte string; tolerate ``\\x1b``-style text via --literal."""
    cleaned = re.sub(r"[\s:_-]", "", text)
    if cleaned[:2].lower() == "0x":
        cleaned = cleaned[2:]
    if not cleaned:
        raise argparse.ArgumentTypeError("--probe-bytes must not be empty")
    if len(cleaned) % 2:
        raise argparse.ArgumentTypeError(
            "--probe-bytes needs an even number of hex digits, got %d" % len(cleaned))
    try:
        return bytes.fromhex(cleaned)
    except ValueError:
        raise argparse.ArgumentTypeError(
            "--probe-bytes is not valid hex: %r" % text)


def _positive_float(text):
    try:
        value = float(text)
    except (TypeError, ValueError):
        raise argparse.ArgumentTypeError("timeout must be a number, got %r" % text)
    if value <= 0:
        raise argparse.ArgumentTypeError("timeout must be > 0, got %r" % text)
    return value


def _literal_escapes(text):
    """Decode common backslash escapes so shell-friendly probes still work."""
    out = bytearray()
    i = 0
    raw = text.encode("utf-8", "surrogateescape")
    while i < len(raw):
        char = raw[i:i + 1]
        if char == b"\\" and i + 1 < len(raw):
            nxt = raw[i + 1:i + 2]
            mapping = {b"e": b"\x1b", b"n": b"\n", b"r": b"\r",
                       b"t": b"\t", b"\\": b"\\", b"0": b"\x00"}
            if nxt == b"x" and i + 4 <= len(raw):
                hexpart = raw[i + 2:i + 4]
                try:
                    out.append(int(hexpart, 16))
                    i += 4
                    continue
                except ValueError:
                    pass
            if nxt in mapping:
                out.extend(mapping[nxt])
                i += 2
                continue
        out.extend(char)
        i += 1
    return bytes(out)


def display_dump(data):
    """Human-readable hex + escaped-ASCII dump used by --verbose."""
    if not data:
        return "(no bytes)"
    hexpart = data.hex(" ")
    escaped = (data.replace(b"\x1b", b"\\e")
                   .decode("ascii", "backslashreplace"))
    return "%d bytes\n  hex: %s\n  esc: %s" % (len(data), hexpart, escaped)


def build_parser():
    parser = argparse.ArgumentParser(
        description="Query the controlling terminal for Kitty graphics support.")
    parser.add_argument("--timeout", type=_positive_float, default=1.5,
                        help="seconds to wait for each reply byte (default 1.5); "
                             "hard deadline is 3x this")
    parser.add_argument("--probe-bytes", metavar="HEX", default=None,
                        help="probe payload as hex (default: built-in Kitty query)")
    parser.add_argument("--literal", action="store_true",
                        help="interpret --probe-bytes as escaped text (\\e, \\x1b); "
                             "requires --probe-bytes")
    parser.add_argument("--raw-out", metavar="FILE",
                        help="write the raw reply bytes to FILE")
    parser.add_argument("--expect-ok", metavar="ID", default=None,
                        help="exit 4 unless ESC_Gi=ID;OK ESC\\ arrives")
    parser.add_argument("--stdout", action="store_true",
                        help="also write raw reply bytes to stdout (default: quiet)")
    parser.add_argument("--verbose", action="store_true",
                        help="dump the reply as hex/escaped text on stderr")
    parser.add_argument("--tty", metavar="PATH", default=None,
                        help="override the tty path (testing aid)")
    return parser


def main(argv=None):
    parser = build_parser()
    args = parser.parse_args(argv)

    probe = DEFAULT_PROBE
    if args.probe_bytes is not None:
        if args.literal:
            probe = _literal_escapes(args.probe_bytes)
        else:
            try:
                probe = _parse_hex(args.probe_bytes)
            except argparse.ArgumentTypeError as exc:
                parser.error(str(exc))
    elif args.literal:
        # --literal without --probe-bytes is a usage error; be explicit.
        parser.error("--literal requires --probe-bytes HEX")

    try:
        reply = run_probe(timeout=args.timeout, probe_bytes=probe,
                          tty_path=args.tty)
    except ProbeError as exc:
        print("kitty_probe: error: %s" % exc, file=sys.stderr)
        return EXIT_SETUP
    except Exception as exc:  # noqa: BLE001 - any unexpected setup failure
        print("kitty_probe: error: %s" % exc, file=sys.stderr)
        return EXIT_SETUP

    if args.verbose:
        print("kitty_probe: probe %s" % display_dump(probe), file=sys.stderr)
        print("kitty_probe: reply %s" % display_dump(reply), file=sys.stderr)
        for index, (control, message) in enumerate(extract_replies(reply)):
            print("kitty_probe: reply[%d] control=%r message=%r"
                  % (index, control, message), file=sys.stderr)

    if args.raw_out:
        try:
            with open(args.raw_out, "wb") as handle:
                handle.write(reply)
        except OSError as exc:
            print("kitty_probe: error: cannot write %s: %s"
                  % (args.raw_out, exc), file=sys.stderr)
            return EXIT_SETUP

    if args.stdout:
        try:
            sys.stdout.buffer.write(reply)
            sys.stdout.buffer.flush()
        except OSError as exc:
            print("kitty_probe: error: cannot write stdout: %s" % exc,
                  file=sys.stderr)
            return EXIT_SETUP

    if args.expect_ok is not None:
        if not reply_is_ok(reply, args.expect_ok):
            if not reply:
                return EXIT_NO_REPLY
            return EXIT_EXPECT_FAILED
        return EXIT_OK

    return EXIT_OK if reply else EXIT_NO_REPLY


if __name__ == "__main__":
    sys.exit(main())
