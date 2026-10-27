#!/usr/bin/env python3
"""Self-tests for scripts/lib/pixels.py (plain python3, no pytest).

Run:  python3 scripts/lib/test_pixels.py
Fixtures are generated with PIL inside a temporary directory.
"""

import json
import os
import subprocess
import sys
import tempfile
import time

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
CLI = os.path.join(HERE, "pixels.py")

RED = (255, 0, 0)
GREEN = (0, 255, 0)
BLUE = (0, 0, 255)
BLACK = (0, 0, 0)

TESTS = []


def test(fn):
    TESTS.append(fn)
    return fn


def run(*args):
    proc = subprocess.run(
        [sys.executable, CLI] + list(args),
        capture_output=True,
        text=True,
    )
    try:
        payload = json.loads(proc.stdout.strip() or "{}")
    except json.JSONDecodeError:
        raise AssertionError(
            "non-JSON stdout (exit %d): %r / stderr %r"
            % (proc.returncode, proc.stdout, proc.stderr)
        )
    return proc.returncode, payload


def solid(path, color, size=(100, 100), mode="RGB"):
    Image.new(mode, size, color).save(path)


def eq(actual, expected, label=""):
    if actual != expected:
        raise AssertionError("%s expected %r, got %r" % (label or "value", expected, actual))


def close(actual, expected, label=""):
    if abs(float(actual) - float(expected)) > 1e-9:
        raise AssertionError("%s expected %r, got %r" % (label or "value", expected, actual))


# -- 1. solid image count/fraction -----------------------------------------

@test
def test_solid_count(tmp):
    path = os.path.join(tmp, "red.png")
    solid(path, RED)
    code, out = run("--image", path, "--color", "#FF0000", "count")
    eq(code, 0, "exit")
    eq(out["command"], "count")
    eq(out["count"], 10000, "count")
    eq(out["total"], 10000, "total")
    close(out["fraction"], 1.0, "fraction")
    eq(out["color"], "#FF0000", "color")
    eq(out["region"], [0, 0, 100, 100], "region")

    # lowercase hex and R,G,B forms must match too
    _, lower = run("--image", path, "--color", "#ff0000", "count")
    eq(lower["count"], 10000, "lowercase count")
    _, csv = run("--image", path, "--color", "255,0,0", "count")
    eq(csv["count"], 10000, "r,g,b count")


# -- 2. half split ----------------------------------------------------------

@test
def test_half_split(tmp):
    path = os.path.join(tmp, "split.png")
    image = Image.new("RGB", (100, 100), BLUE)
    for y in range(100):
        for x in range(50):
            image.putpixel((x, y), RED)
    image.save(path)
    code, out = run("--image", path, "--color", "#FF0000", "count")
    eq(code, 0, "exit")
    eq(out["count"], 5000, "count")
    eq(out["total"], 10000, "total")
    close(out["fraction"], 0.5, "fraction")
    eq(type(out["fraction"]).__name__, "float", "fraction is float")
    _, bbox = run("--image", path, "--color", "#FF0000", "bbox")
    eq(bbox["found"], True, "found")
    eq((bbox["x"], bbox["y"], bbox["w"], bbox["h"]), (0, 0, 50, 100), "bbox")


# -- 3. bbox with region offset (absolute coordinates) ---------------------

@test
def test_bbox_region_offset(tmp):
    path = os.path.join(tmp, "offset.png")
    image = Image.new("RGB", (100, 100), BLACK)
    for y in range(30, 50):
        for x in range(60, 80):
            image.putpixel((x, y), RED)
    image.save(path)
    code, out = run("--image", path, "--color", "#FF0000",
                    "--region", "50,20,50,50", "bbox")
    eq(code, 0, "exit")
    eq(out["found"], True, "found")
    eq([out["x"], out["y"], out["w"], out["h"]], [60, 30, 20, 20], "absolute bbox")
    eq(out["count"], 400, "count")
    close(out["fraction_in_bbox"], 1.0, "fraction_in_bbox")
    eq(out["region"], [50, 20, 50, 50], "region")

    _, count = run("--image", path, "--color", "#FF0000",
                   "--region", "50,20,50,50", "count")
    eq(count["count"], 400, "region count")
    close(count["fraction"], 0.16, "region fraction")

    # not found -> found=false, w=h=0, exit 0
    code, missing = run("--image", path, "--color", "#00FF00", "bbox")
    eq(code, 0, "missing exit")
    eq(missing["found"], False, "missing found")
    eq((missing["w"], missing["h"]), (0, 0), "missing size")
    eq(missing["count"], 0, "missing count")


# -- 4. assert pass / fail -------------------------------------------------

@test
def test_assert_pass(tmp):
    path = os.path.join(tmp, "red.png")
    solid(path, RED)
    code, out = run("--image", path, "--color", "#FF0000", "assert",
                    "--min-fraction", "1.0", "--max-fraction", "1.0",
                    "--min-count", "10000",
                    "--bbox-max-w", "100", "--bbox-max-h", "100")
    eq(code, 0, "exit")
    eq(out["pass"], True, "pass")
    for name in ("min_fraction", "max_fraction", "min_count",
                 "bbox_max_w", "bbox_max_h"):
        eq(out["checks"][name]["pass"], True, "%s pass" % name)
    eq(out["bbox"]["w"], 100, "bbox w")
    eq(out["bbox"]["h"], 100, "bbox h")


@test
def test_assert_fail(tmp):
    path = os.path.join(tmp, "red.png")
    solid(path, RED)
    code, out = run("--image", path, "--color", "#FF0000", "assert",
                    "--min-count", "10001")
    eq(code, 1, "exit")
    eq(out["pass"], False, "pass")
    eq(out["checks"]["min_count"]["pass"], False, "min_count fail")
    eq(out["checks"]["min_count"]["required"], 10001, "required")
    eq(out["checks"]["min_count"]["actual"], 10000, "actual")

    # fraction failure path too
    code, out = run("--image", path, "--color", "#FF0000", "assert",
                    "--min-fraction", "1.0", "--max-fraction", "0.5")
    eq(code, 2, "conflicting bounds -> error exit 2")
    eq("error" in out, True, "conflicting bounds error JSON")


# -- 5. fuzz ----------------------------------------------------------------

@test
def test_fuzz_near_boundary(tmp):
    path = os.path.join(tmp, "red.png")
    solid(path, RED)
    code, out = run("--image", path, "--color", "#FE0000", "--fuzz", "0", "count")
    eq(code, 0, "exit")
    eq(out["count"], 0, "exact mismatch")
    _, out = run("--image", path, "--color", "#FE0000", "--fuzz", "1", "count")
    eq(out["count"], 10000, "fuzz 1 matches")
    close(out["fraction"], 1.0, "fuzz fraction")
    _, out = run("--image", path, "--color", "#FA0000", "--fuzz", "1", "count")
    eq(out["count"], 0, "fuzz 1 rejects delta 5")
    _, out = run("--image", path, "--color", "250,0,0", "--fuzz", "5", "count")
    eq(out["count"], 10000, "fuzz 5 accepts delta 5")


# -- 6. diff ----------------------------------------------------------------

@test
def test_diff(tmp):
    a = os.path.join(tmp, "a.png")
    b = os.path.join(tmp, "b.png")
    c = os.path.join(tmp, "c.png")
    solid(a, BLACK)
    solid(b, BLACK)
    Image.open(b).copy().save(c)
    image = Image.open(c)
    image.putpixel((5, 5), (255, 255, 255))
    image.save(c)

    code, out = run("--image", a, "--image-b", b, "diff")
    eq(code, 0, "identical exit")
    eq(out["changed_pixels"], 0, "identical changed")
    eq(out["total"], 10000, "total")
    close(out["fraction"], 0.0, "identical fraction")
    eq(out["pass"], True, "identical pass")

    code, out = run("--image", a, "--image-b", c, "diff")
    eq(code, 0, "one pixel exit (default max 1.0)")
    eq(out["changed_pixels"], 1, "one pixel changed")
    close(out["fraction"], 0.0001, "one pixel fraction")
    eq(out["pass"], True, "one pixel pass by default")

    code, out = run("--image", a, "--image-b", c, "diff",
                    "--max-changed-fraction", "0.00005")
    eq(code, 1, "strict exit")
    eq(out["pass"], False, "strict pass")

    # fuzz absorbs a small channel delta
    d = os.path.join(tmp, "d.png")
    image = Image.open(a)
    image.putpixel((0, 0), (0, 0, 2))
    image.save(d)
    _, out = run("--image", a, "--image-b", d, "--fuzz", "2", "diff")
    eq(out["changed_pixels"], 0, "fuzz absorbs diff")

    # a bound above 1.0 is allowed and can never fail
    code, out = run("--image", a, "--image-b", c, "diff",
                    "--max-changed-fraction", "1.5")
    eq(code, 0, "lenient bound exit")
    eq(out["pass"], True, "lenient bound pass")


# -- 7. dominant ordering ---------------------------------------------------

@test
def test_dominant(tmp):
    path = os.path.join(tmp, "dominant.png")
    image = Image.new("RGB", (100, 100), RED)
    for y in range(100):
        for x in range(100):
            if 60 <= x < 90:
                image.putpixel((x, y), GREEN)
            elif x >= 90:
                image.putpixel((x, y), BLUE)
    image.save(path)
    code, out = run("--image", path, "dominant")
    eq(code, 0, "exit")
    colors = out["colors"]
    eq(len(colors), 3, "colors count")
    eq([c["color"] for c in colors], ["#FF0000", "#00FF00", "#0000FF"], "order")
    eq([c["count"] for c in colors], [6000, 3000, 1000], "counts")
    close(colors[0]["fraction"], 0.6, "red fraction")
    close(colors[1]["fraction"], 0.3, "green fraction")
    close(colors[2]["fraction"], 0.1, "blue fraction")

    # region narrows the histogram
    _, out = run("--image", path, "--region", "0,0,10,10", "dominant")
    eq([c["color"] for c in out["colors"]], ["#FF0000"], "region dominant")
    eq(out["colors"][0]["count"], 100, "region dominant count")


# -- 8. color parsing + mode conversion ------------------------------------

@test
def test_modes_and_color_forms(tmp):
    rgba = os.path.join(tmp, "rgba.png")
    solid(rgba, (255, 0, 0, 255), mode="RGBA")
    _, out = run("--image", rgba, "--color", "#FF0000", "count")
    eq(out["count"], 10000, "rgba count")

    paletted = os.path.join(tmp, "pal.png")
    image = Image.new("P", (100, 100), 1)
    image.putpalette([0, 0, 0, 255, 0, 0] + [0] * 762)
    image.save(paletted)
    _, out = run("--image", paletted, "--color", "255,0,0", "count")
    eq(out["count"], 10000, "palette count")


# -- 9. errors -> exit 2 JSON ----------------------------------------------

@test
def test_errors(tmp):
    path = os.path.join(tmp, "red.png")
    solid(path, RED)
    cases = [
        ("missing image", ["--image", os.path.join(tmp, "nope.png"),
                           "--color", "#FF0000", "count"]),
        ("region out of bounds", ["--image", path, "--color", "#FF0000",
                                  "--region", "90,90,20,20", "count"]),
        ("bad region", ["--image", path, "--color", "#FF0000",
                        "--region", "1,2,3", "count"]),
        ("bad color", ["--image", path, "--color", "#GG0000", "count"]),
        ("color component range", ["--image", path, "--color", "256,0,0", "count"]),
        ("missing subcommand", ["--image", path, "--color", "#FF0000"]),
        ("missing image option", ["count", "--color", "#FF0000"]),
        ("negative fuzz", ["--image", path, "--color", "#FF0000", "--fuzz", "-1", "count"]),
        ("diff missing b", ["--image", path, "diff"]),
    ]
    for label, argv in cases:
        code, out = run(*argv)
        eq(code, 2, label + " exit")
        eq(isinstance(out.get("error"), str) and bool(out["error"]), True,
           label + " error JSON")


# -- 10. --json mirror ------------------------------------------------------

@test
def test_json_file(tmp):
    path = os.path.join(tmp, "red.png")
    target = os.path.join(tmp, "out", "result.json")
    solid(path, RED)
    code, out = run("--image", path, "--color", "#FF0000",
                    "--json", target, "count")
    eq(code, 0, "exit")
    eq(os.path.isfile(target), True, "json file written")
    with open(target, encoding="utf-8") as handle:
        saved = json.load(handle)
    eq(saved, out, "json file matches stdout")


def main():
    failures = 0
    started = time.time()
    with tempfile.TemporaryDirectory(prefix="pixels-test-") as tmp:
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
