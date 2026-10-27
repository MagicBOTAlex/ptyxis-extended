#!/usr/bin/env python3
"""Self-tests for scripts/lib/kitty_emit.py (plain python3, no pytest).

Run:  python3 scripts/lib/test_kitty_emit.py
"""

import base64
import os
import subprocess
import sys
import tempfile
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
CLI = os.path.join(HERE, "kitty_emit.py")
sys.path.insert(0, HERE)

import kitty_emit as ke  # noqa: E402

ESC = b"\x1b"
APC_START = b"\x1b_G"
APC_END = b"\x1b\\"

TESTS = []


def test(fn):
    TESTS.append(fn)
    return fn


def eq(actual, expected, label=""):
    if actual != expected:
        raise AssertionError("%s expected %r, got %r" % (label or "value", expected, actual))


def truth(value, label=""):
    if not value:
        raise AssertionError("%s expected truthy, got %r" % (label or "value", value))


def frames(data):
    """Split a byte stream into (control dict, payload text, raw frame) tuples."""
    out = []
    pos = 0
    while True:
        start = data.find(APC_START, pos)
        if start < 0:
            break
        end = data.find(APC_END, start + len(APC_START))
        if end < 0:
            raise AssertionError("unterminated frame at %d in %r" % (start, data[start:start + 40]))
        body = data[start + len(APC_START):end]
        if b";" in body:
            control, payload = body.split(b";", 1)
        else:
            control, payload = body, None
        fields = {}
        for part in control.decode("ascii").split(","):
            if not part:
                continue
            key, _, value = part.partition("=")
            fields[key] = value
        out.append((fields, payload.decode("ascii") if payload is not None else None,
                    data[start:end + len(APC_END)]))
        pos = end + len(APC_END)
    return out


def run(*args):
    proc = subprocess.run([sys.executable, CLI] + list(args), capture_output=True)
    return proc.returncode, proc.stdout, proc.stderr


# -- 1. single-frame exact bytes -------------------------------------------

@test
def test_single_frame_exact():
    eq(ke.apc("a=t,f=24,i=1", "AAAA"),
       b"\x1b_Ga=t,f=24,i=1;AAAA\x1b\\", "tiny payload frame")
    eq(ke.build({"a": "t", "f": "24", "i": "1"}, b"\x00\x00\x00"),
       b"\x1b_Ga=t,f=24,i=1;AAAA\x1b\\", "build single frame")


@test
def test_query_exact():
    literal = b"\x1b_Gi=31337,s=1,v=1,a=q,t=d,f=24;AAAA\x1b\\"
    eq(ke.query(), literal, "default query")
    eq(ke.query(), literal, "probe literal is stable")
    eq(ke.query(5), b"\x1b_Gi=5,s=1,v=1,a=q,t=d,f=24;AAAA\x1b\\", "query id")


@test
def test_no_payload_frames():
    eq(ke.apc("a=d,d=a"), b"\x1b_Ga=d,d=a\x1b\\", "apc no payload")
    eq(ke.build({"a": "d", "d": "a"}, b""), b"\x1b_Ga=d,d=a\x1b\\", "build empty payload")
    truth(b";" not in ke.apc("a=d,d=a"), "no separator")


# -- 2. chunking ------------------------------------------------------------

@test
def test_chunking_large():
    payload = bytes((i * 37 + 11) % 256 for i in range(100000))
    data = ke.build({"a": "t", "f": "24", "i": "42"}, payload)
    parsed = frames(data)
    truth(len(parsed) > 1, "multiple frames")
    chunks = []
    for index, (fields, chunk, raw) in enumerate(parsed):
        truth(chunk is not None, "frame %d has payload" % index)
        truth(len(chunk) <= 4096, "frame %d chunk <=4096 (%d)" % (index, len(chunk)))
        chunks.append(chunk)
    truth(len(chunks[-1]) <= 4096, "last chunk size")
    for index in range(len(parsed) - 1):
        eq(parsed[index][0].get("m"), "1", "frame %d m" % index)
    eq(parsed[-1][0].get("m"), "0", "last m")
    eq(parsed[-1][0], {"m": "0"}, "last frame control is m only")
    for index in range(1, len(parsed) - 1):
        eq(parsed[index][0], {"m": "1"}, "middle frame %d control" % index)
    eq(parsed[0][0], {"a": "t", "f": "24", "i": "42", "m": "1"}, "first frame control")
    decoded = base64.b64decode("".join(chunks))
    eq(decoded, payload, "decoded payload")
    truth(not data.endswith(b"\n"), "no trailing newline")


@test
def test_chunking_small():
    payload = bytes(range(256)) * 7 + b"\x00" * (2000 - 1792)
    eq(len(payload), 2000, "fixture size")
    data = ke.build({"a": "t", "i": "3"}, payload)
    parsed = frames(data)
    eq(len(parsed), 1, "exactly one frame")
    truth("m" not in parsed[0][0], "no m key")
    eq(base64.b64decode(parsed[0][1]), payload, "payload roundtrip")


@test
def test_chunking_exact_multiple():
    raw = b"\xaa" * 3072  # base64 -> 4096 chars, exactly one chunk
    data = ke.build({"a": "t", "i": "1"}, raw)
    eq(len(frames(data)), 1, "exact 4096 b64 is one chunk")
    raw = b"\xaa" * 3073  # base64 -> 4100 chars -> 2 chunks (4096 + 4)
    data = ke.build({"a": "t", "i": "1"}, raw)
    parsed = frames(data)
    eq(len(parsed), 2, "one byte over splits")
    eq(len(parsed[1][1]), 4, "tail chunk length")
    eq(base64.b64decode(parsed[0][1] + parsed[1][1]), raw, "roundtrip")


# -- 3. raw RGB / RGBA ------------------------------------------------------

@test
def test_raw_rgb():
    rgb = bytes([255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 0])  # 2x2
    parsed = frames(ke.raw_frames(2, 2, rgb, 24, image_id=11))
    eq(len(parsed), 1, "single frame")
    fields, chunk, raw = parsed[0]
    eq(fields, {"a": "t", "f": "24", "s": "2", "v": "2", "t": "d", "i": "11"},
       "rgb control")
    eq(base64.b64decode(chunk), rgb, "rgb payload")
    eq(raw[:3], b"\x1b_G", "start")


@test
def test_raw_rgba():
    rgba = bytes([1, 2, 3, 4]) * 6  # 2x3
    parsed = frames(ke.raw_frames(2, 3, rgba, 32, image_id="9"))
    fields, chunk, _ = parsed[0]
    eq(fields, {"a": "t", "f": "32", "s": "2", "v": "3", "t": "d", "i": "9"},
       "rgba control")
    eq(base64.b64decode(chunk), rgba, "rgba payload")


@test
def test_raw_zlib():
    rgb = bytes([7, 8, 9]) * (64 * 64)
    parsed = frames(ke.raw_frames(64, 64, rgb, 24, image_id=1, zlib_compress=True))
    fields, chunk, _ = parsed[0]
    eq(fields.get("o"), "z", "o=z key")
    eq(zlib.decompress(base64.b64decode(chunk)), rgb, "zlib roundtrip")


@test
def test_raw_validation():
    for label, args in [
        ("short payload", (2, 2, b"\x00" * 11, 24)),
        ("long payload", (1, 1, b"\x00" * 4, 24)),
        ("bad format", (1, 1, b"\x00" * 3, 25)),
        ("zero width", (0, 1, b"", 24)),
    ]:
        try:
            ke.raw_frames(*args, image_id=1)
        except ke.ArgError:
            pass
        else:
            raise AssertionError("%s did not raise" % label)


# -- 4. placement / delete --------------------------------------------------

@test
def test_placement():
    eq(ke.placement(7), b"\x1b_Ga=p,i=7\x1b\\", "minimal placement")
    eq(ke.placement(7, placement_id=3, columns=10, rows=5, src_x=1, src_y=2,
                    src_w=30, src_h=40, z=5, no_cursor_move=True),
       b"\x1b_Ga=p,i=7,p=3,c=10,r=5,x=1,y=2,w=30,h=40,z=5,C=1\x1b\\",
       "full placement key order")
    eq(ke.placement(7, rows=2, columns=1),
       b"\x1b_Ga=p,i=7,c=1,r=2\x1b\\", "columns before rows")
    eq(ke.placement(7, extra={"X": 4, "Y": 5}),
       b"\x1b_Ga=p,i=7,X=4,Y=5\x1b\\", "extra keys appended")


@test
def test_delete():
    eq(ke.delete(mode="a"), b"\x1b_Ga=d,d=a\x1b\\", "delete all")
    eq(ke.delete(mode="i", image_id=7), b"\x1b_Ga=d,d=i,i=7\x1b\\", "delete image")
    eq(ke.delete(mode="I", image_id=7), b"\x1b_Ga=d,d=I,i=7\x1b\\", "delete placements")
    eq(ke.delete(mode="p", placement_id=4),
       b"\x1b_Ga=d,d=p,p=4\x1b\\", "delete placement")
    try:
        ke.delete(mode="x", image_id=1)
    except ke.ArgError:
        pass
    else:
        raise AssertionError("bad delete mode did not raise")


# -- 5. reply parsing -------------------------------------------------------

@test
def test_parse_reply_ok():
    data = b"\x1b_Gi=31337;OK\x1b\\"
    eq(ke.parse_reply(data), [{"i": "31337", "message": "OK"}], "ok reply")
    truth(ke.has_ok_reply(data, 31337), "has_ok int")
    truth(ke.has_ok_reply(data, "31337"), "has_ok str")
    truth(not ke.has_ok_reply(data, 31338), "wrong id")
    truth(not ke.has_ok_reply(b"\x1b_Gi=31337;EINVAL: bad\x1b\\", 31337),
          "error is not ok")


@test
def test_parse_reply_error():
    data = b"\x1b_Gi=7;EINVAL: invalid argument\x1b\\"
    eq(ke.parse_reply(data),
       [{"i": "7", "message": "EINVAL: invalid argument"}], "error reply")


@test
def test_parse_reply_multiple():
    data = (b"noise\x1b_Gi=1;OK\x1b\\"
            b"\x1b_Gi=2;ENOTSUPPORTED: nope\x1b\\")
    replies = ke.parse_reply(data)
    eq(len(replies), 2, "two replies")
    eq(replies[0], {"i": "1", "message": "OK"}, "first")
    eq(replies[1], {"i": "2", "message": "ENOTSUPPORTED: nope"}, "second")
    truth(ke.has_ok_reply(data, 1), "first ok")
    truth(not ke.has_ok_reply(data, 2), "second not ok")


@test
def test_parse_reply_no_message():
    eq(ke.parse_reply(b"\x1b_Gi=1\x1b\\"), [{"i": "1", "message": ""}],
       "reply without message")
    eq(ke.parse_reply(b""), [], "empty input")
    eq(ke.parse_reply(b"garbage"), [], "no frames")


# -- 6. framing invariants --------------------------------------------------

@test
def test_framing_invariants():
    streams = [
        ke.apc("a=d,d=a"),
        ke.query(),
        ke.placement(1, columns=2, rows=2),
        ke.delete(mode="a"),
        ke.raw_frames(2, 2, b"\x00" * 12, 24, image_id=1),
        ke.build({"a": "t", "i": "1"}, bytes(range(256)) * 200),
    ]
    for index, data in enumerate(streams):
        truth(not data.endswith(b"\n"), "stream %d no trailing newline" % index)
        truth(data.startswith(APC_START), "stream %d starts with APC" % index)
        truth(data.endswith(APC_END), "stream %d ends with ST" % index)
        for _, _, raw in frames(data):
            truth(b"\n" not in raw, "stream %d frame has no newline" % index)


# -- 7. CLI -----------------------------------------------------------------

@test
def test_cli_query():
    code, out, err = run("query")
    eq(code, 0, "exit")
    eq(out, b"\x1b_Gi=31337,s=1,v=1,a=q,t=d,f=24;AAAA\x1b\\", "stdout probe")
    eq(err, b"", "stderr empty")
    code, out, _ = run("query", "--image-id", "5")
    eq(code, 0, "exit")
    truth(out.startswith(b"\x1b_Gi=5,"), "custom id")


@test
def test_cli_raw(tmp):
    code, out, _ = run("raw", "--width", "2", "--height", "2", "--format", "24",
                       "--rgb", "FF0000", "--image-id", "5")
    eq(code, 0, "exit")
    fields, chunk, _ = frames(out)[0]
    eq(fields["f"], "24", "format key")
    eq(base64.b64decode(chunk), b"\xff\x00\x00" * 4, "solid red payload")

    code, out, _ = run("raw", "--width", "1", "--height", "1", "--format", "32",
                       "--rgb", "010203", "--alpha", "4", "--image-id", "6",
                       "--zlib")
    eq(code, 0, "exit")
    fields, chunk, _ = frames(out)[0]
    eq(fields["f"], "32", "rgba format")
    eq(fields.get("o"), "z", "zlib key")
    eq(zlib.decompress(base64.b64decode(chunk)), b"\x01\x02\x03\x04", "rgba+zlib")
    truth(b"\n" not in out, "no newline")


@test
def test_cli_png(tmp):
    from PIL import Image
    path = os.path.join(tmp, "solid.png")
    Image.new("RGB", (3, 2), (10, 20, 30)).save(path)
    out_path = os.path.join(tmp, "frames.bin")
    code, out, err = run("png", path, "--image-id", "8", "--placement-id", "2",
                         "--columns", "4", "--rows", "2", "--out", out_path)
    eq(code, 0, "exit: %r" % err)
    eq(out, b"", "no stdout with --out")
    with open(out_path, "rb") as handle:
        data = handle.read()
    parsed = frames(data)
    eq(len(parsed), 1, "single png frame")
    fields, chunk, _ = parsed[0]
    eq(fields, {"a": "t", "f": "100", "t": "d", "i": "8", "p": "2",
                "c": "4", "r": "2"}, "png control")
    truth(base64.b64decode(chunk).startswith(b"\x89PNG\r\n\x1a\n"), "png magic")


@test
def test_cli_place_delete():
    code, out, _ = run("place", "--image-id", "1", "--placement-id", "2",
                       "--columns", "3", "--rows", "4", "--src", "1,2,30,40",
                       "--z", "5", "--no-cursor-move")
    eq(code, 0, "exit")
    eq(out, b"\x1b_Ga=p,i=1,p=2,c=3,r=4,x=1,y=2,w=30,h=40,z=5,C=1\x1b\\",
       "place bytes")
    code, out, _ = run("delete", "--mode", "i", "--image-id", "9")
    eq(code, 0, "exit")
    eq(out, b"\x1b_Ga=d,d=i,i=9\x1b\\", "delete bytes")


@test
def test_cli_errors():
    cases = [
        ("missing image id", ["raw", "--width", "1", "--height", "1",
                              "--format", "24", "--rgb", "000000"]),
        ("alpha with rgb", ["raw", "--width", "1", "--height", "1",
                            "--format", "24", "--rgb", "000000", "--alpha", "1",
                            "--image-id", "1"]),
        ("bad rgb", ["raw", "--width", "1", "--height", "1", "--format", "24",
                     "--rgb", "nope", "--image-id", "1"]),
        ("delete without id", ["delete", "--mode", "i"]),
        ("delete p without placement", ["delete", "--mode", "p"]),
        ("bad src", ["place", "--image-id", "1", "--src", "1,2,3"]),
        ("bad chunk size", ["raw", "--width", "1", "--height", "1",
                            "--format", "24", "--rgb", "000000",
                            "--image-id", "1", "--chunk-size", "6"]),
        ("missing png", ["png", "/nonexistent.png", "--image-id", "1"]),
    ]
    for label, argv in cases:
        code, out, err = run(*argv)
        eq(code, 2, label + " exit")
        eq(out, b"", label + " stdout empty")
        truth(err.strip() != b"", label + " stderr message")


@test
def test_cli_selftest():
    code, out, err = run("selftest")
    eq(code, 0, "selftest exit: %r" % err)
    truth(b"ok " in out, "selftest prints ok lines")


def main():
    failures = 0
    with tempfile.TemporaryDirectory(prefix="kitty-emit-test-") as tmp:
        for fn in TESTS:
            try:
                if fn.__code__.co_argcount:
                    fn(tmp)
                else:
                    fn()
            except Exception as exc:  # noqa: BLE001 - test harness
                failures += 1
                print("FAIL %s: %s" % (fn.__name__, exc))
            else:
                print("ok   %s" % fn.__name__)
    passed = len(TESTS) - failures
    print("\n%d passed, %d failed" % (passed, failures))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
