#!/usr/bin/env python3
"""Deterministic fixtures for the Kitty graphics e2e harness.

All PNGs and raw RGB/RGBA buffers are generated locally (Pillow only) so every
run uses identical pixels.  Usage:

    kitty_fixtures.py OUTDIR
    kitty_fixtures.py --selftest
"""
import json
import os
import random
import sys

MAGENTA = (255, 0, 255)
CYAN = (0, 255, 255)
RED = (255, 0, 0)
BLUE = (0, 0, 255)
GREEN = (0, 255, 0)
YELLOW = (255, 255, 0)
WHITE = (255, 255, 255)


def _noise(w, h, seed):
    rng = random.Random(seed)
    return bytes(rng.randrange(256) for _ in range(w * h * 3))


def _noise_img(w, h, seed):
    from PIL import Image
    return Image.frombytes("RGB", (w, h), _noise(w, h, seed))


def make_fixtures(outdir):
    from PIL import Image

    os.makedirs(outdir, exist_ok=True)
    created = {}

    # 1. Chunked PNG: magenta field with a cyan inset and a noise block that
    #    pushes the base64 payload well over 3072 bytes (m=1 chunking).
    img = Image.new("RGB", (480, 320), MAGENTA)
    img.paste(_noise_img(120, 120, 11), (360, 200))
    for y in range(24, 104):
        for x in range(24, 104):
            img.putpixel((x, y), CYAN)
    p = os.path.join(outdir, "chunked-480x320.png")
    img.save(p, "PNG", optimize=False)
    created[os.path.basename(p)] = os.path.getsize(p)

    # 2. ~72 kB incompressible PNG for the 100 kB chunking test.
    img = _noise_img(160, 160, 12)
    for y in range(40):
        for x in range(40):
            img.putpixel((x, y), MAGENTA)
    p = os.path.join(outdir, "chunk-100k.png")
    img.save(p, "PNG", optimize=False)
    created[os.path.basename(p)] = os.path.getsize(p)

    # 3. Source-rect image: left half red, right half blue.
    img = Image.new("RGB", (200, 100), RED)
    for y in range(100):
        for x in range(100, 200):
            img.putpixel((x, y), BLUE)
    p = os.path.join(outdir, "source-200x100.png")
    img.save(p, "PNG")
    created[os.path.basename(p)] = os.path.getsize(p)

    # 4. Solid squares used by geometry / delete / z-order scenarios.
    for name, size, colour in (
        ("red-96.png", 96, RED),
        ("blue-96.png", 96, BLUE),
        ("green-64.png", 64, GREEN),
        ("alt-64.png", 64, YELLOW),
    ):
        Image.new("RGB", (size, size), colour).save(os.path.join(outdir, name), "PNG")
        created[name] = os.path.getsize(os.path.join(outdir, name))

    # 5. Raw buffers (no PNG container) for f=24 / f=32 / o=z tests.
    raw = bytearray()
    for _y in range(64):
        for x in range(64):
            raw += bytes(MAGENTA if x < 32 else BLUE)
    p = os.path.join(outdir, "raw-rgb-64.bin")
    open(p, "wb").write(bytes(raw))
    created[os.path.basename(p)] = len(raw)

    raw = bytearray()
    for y in range(64):
        for _x in range(64):
            raw += bytes(MAGENTA + (255,)) if y < 32 else bytes(GREEN + (0,))
    p = os.path.join(outdir, "raw-rgba-64.bin")
    open(p, "wb").write(bytes(raw))
    created[os.path.basename(p)] = len(raw)

    raw = bytearray()
    for _y in range(100):
        for x in range(200):
            raw += bytes(RED if x < 100 else BLUE)
    p = os.path.join(outdir, "raw-src-200x100.bin")
    open(p, "wb").write(bytes(raw))
    created[os.path.basename(p)] = len(raw)

    raw = bytearray()
    for _y in range(64):
        for _x in range(64):
            raw += bytes(GREEN)
    p = os.path.join(outdir, "raw-green-64.bin")
    open(p, "wb").write(bytes(raw))
    created[os.path.basename(p)] = len(raw)

    return created


def selftest():
    import base64
    import tempfile
    from PIL import Image

    failures = 0
    checks = 0

    def check(cond, msg):
        nonlocal failures, checks
        checks += 1
        if not cond:
            failures += 1
            print("FAIL: " + msg)

    with tempfile.TemporaryDirectory() as td:
        created = make_fixtures(td)
        # deterministic bytes
        created2 = make_fixtures(td + "-2")
        for name in created:
            a = open(os.path.join(td, name), "rb").read()
            b = open(os.path.join(td + "-2", name), "rb").read()
            check(a == b, name + " deterministic")

        img = Image.open(os.path.join(td, "chunked-480x320.png")).convert("RGB")
        check(img.size == (480, 320), "chunked size")
        check(img.getpixel((0, 0)) == MAGENTA, "chunked magenta corner")
        check(img.getpixel((24, 24)) == CYAN, "chunked cyan inset")
        check(img.getpixel((479, 319)) != MAGENTA, "chunked noise block")
        b64 = len(base64.b64encode(open(os.path.join(td, "chunked-480x320.png"), "rb").read()))
        check(b64 > 3072, "chunked payload > 3072 (%d)" % b64)

        img = Image.open(os.path.join(td, "chunk-100k.png")).convert("RGB")
        b64 = len(base64.b64encode(open(os.path.join(td, "chunk-100k.png"), "rb").read()))
        check(b64 > 90000, "chunk-100k payload ~100k (%d)" % b64)
        check(img.getpixel((0, 0)) == MAGENTA, "chunk-100k marker")

        img = Image.open(os.path.join(td, "source-200x100.png")).convert("RGB")
        check(img.getpixel((0, 0)) == RED and img.getpixel((199, 0)) == BLUE, "source halves")

        raw = open(os.path.join(td, "raw-rgb-64.bin"), "rb").read()
        check(len(raw) == 64 * 64 * 3, "raw rgb length")
        check(tuple(raw[0:3]) == MAGENTA and tuple(raw[63 * 3:63 * 3 + 3]) == BLUE, "raw rgb halves")

        raw = open(os.path.join(td, "raw-rgba-64.bin"), "rb").read()
        check(len(raw) == 64 * 64 * 4, "raw rgba length")
        check(tuple(raw[0:4]) == MAGENTA + (255,), "raw rgba top")
        check(tuple(raw[-4:]) == GREEN + (0,), "raw rgba transparent bottom")

        check(created.get("chunked-480x320.png", 0) > 3000, "chunked png file size")
        check(created.get("chunk-100k.png", 0) > 60000, "chunk-100k png file size")

    print("%d checks, %d failures" % (checks, failures))
    return 0 if failures == 0 else 1


def main(argv):
    if len(argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    if argv[1] == "--selftest":
        return selftest()
    created = make_fixtures(argv[1])
    print(json.dumps(created, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
