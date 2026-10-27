#!/usr/bin/env python3
"""Self-tests for scripts/lib/kitty_geometry.py (plain python3, no pytest).

Run:  python3 scripts/lib/test_kitty_geometry.py
Exit code is nonzero when any expected failure does not happen.

The interesting cases are the aspect-ratio rounding boundaries and the cell
count used for cursor advancement, since the screenshot assertions depend on
both being exact.
"""

import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
CLI = os.path.join(HERE, "kitty_geometry.py")

# Keep the worktree clean: importing the module must not create __pycache__.
sys.dont_write_bytecode = True
sys.path.insert(0, HERE)
import kitty_geometry as kg  # noqa: E402

TESTS = []


def test(fn):
    TESTS.append(fn)
    return fn


def eq(actual, expected, label=""):
    if actual != expected:
        raise AssertionError("%s expected %r, got %r"
                             % (label or "value", expected, actual))


def rect(x, y, w, h):
    return {"x": x, "y": y, "w": w, "h": h}


def resolve(placement, image=(100, 100), cell=(9, 18), anchor=(0, 0)):
    image_w, image_h = image
    cell_w, cell_h = cell
    anchor_col, anchor_row = anchor
    return kg.resolve(placement, image_w, image_h, cell_w, cell_h,
                      anchor_col, anchor_row)


def expect_value_error(fn, label=""):
    try:
        fn()
    except ValueError:
        return
    raise AssertionError("%s expected ValueError" % (label or "call"))


def run_cli(*args):
    proc = subprocess.run([sys.executable, CLI] + list(args),
                          capture_output=True, text=True)
    try:
        payload = json.loads(proc.stdout.strip() or "{}")
    except json.JSONDecodeError:
        raise AssertionError("non-JSON stdout (exit %d): %r / stderr %r"
                             % (proc.returncode, proc.stdout, proc.stderr))
    return proc.returncode, payload


# --------------------------------------------------------------------------
# sizing
# --------------------------------------------------------------------------

@test
def no_columns_no_rows_uses_source_pixels():
    got = resolve({}, image=(100, 80), cell=(9, 18), anchor=(3, 2))
    eq(got["src"], rect(0, 0, 100, 80), "src")
    eq(got["display"], {"w": 100, "h": 80}, "display")
    eq(got["rect"], rect(27, 36, 100, 80), "rect")
    eq(got["cells"], {"cols": 12, "rows": 5}, "cells")
    eq(got["stretch"], False, "stretch")


@test
def columns_only_keeps_aspect():
    got = resolve({"c": 20}, image=(480, 320), cell=(9, 18), anchor=(1, 1))
    eq(got["display"], {"w": 180, "h": 120}, "display")
    eq(got["rect"], rect(9, 18, 180, 120), "rect")
    eq(got["cells"], {"cols": 20, "rows": 7}, "cells")
    eq(got["stretch"], False, "stretch")


@test
def rows_only_keeps_aspect():
    got = resolve({"r": 2}, image=(4, 3), cell=(3, 5), anchor=(0, 0))
    eq(got["display"], {"w": 13, "h": 10}, "display")
    eq(got["cells"], {"cols": 5, "rows": 2}, "cells")
    eq(got["stretch"], False, "stretch")


@test
def both_columns_and_rows_stretch():
    got = resolve({"c": 3, "r": 2}, image=(100, 50), cell=(9, 18),
                  anchor=(2, 4))
    eq(got["display"], {"w": 27, "h": 36}, "display")
    eq(got["rect"], rect(18, 72, 27, 36), "rect")
    eq(got["cells"], {"cols": 3, "rows": 2}, "cells")
    eq(got["stretch"], True, "stretch")


@test
def rounding_half_up_when_columns_only():
    # 6 * 3/4 = 4.5 -> 5 (Python's round() would give 4)
    got = resolve({"c": 2}, image=(4, 3), cell=(3, 2))
    eq(got["display"], {"w": 6, "h": 5}, "display")
    eq(got["cells"], {"cols": 2, "rows": 3}, "cells")


@test
def rounding_up_when_fraction_above_half():
    # 5 * 3/4 = 3.75 -> 4
    got = resolve({"c": 1}, image=(4, 3), cell=(5, 2))
    eq(got["display"], {"w": 5, "h": 4}, "display")


@test
def rounding_down_when_fraction_below_half():
    # 5 * 2/3 = 3.33 -> 3
    got = resolve({"c": 1}, image=(3, 2), cell=(5, 2))
    eq(got["display"], {"w": 5, "h": 3}, "display")


@test
def rounding_half_up_small_values():
    # 1 * 3/2 = 1.5 -> 2 and 5 * 2/4 = 2.5 -> 3
    got = resolve({"c": 1}, image=(2, 3), cell=(1, 2))
    eq(got["display"], {"w": 1, "h": 2}, "display")
    got = resolve({"c": 1}, image=(4, 2), cell=(5, 2))
    eq(got["display"], {"w": 5, "h": 3}, "display")


@test
def rounding_half_up_when_rows_only():
    # 1 * 5/2 = 2.5 -> 3
    got = resolve({"r": 1}, image=(5, 2), cell=(3, 1))
    eq(got["display"], {"w": 3, "h": 1}, "display")
    # 10 * 4/3 = 13.33 -> 13
    got = resolve({"r": 2}, image=(4, 3), cell=(3, 5))
    eq(got["display"], {"w": 13, "h": 10}, "display")


@test
def cell_rounding_boundary_480x320_c20():
    # 120 tall over 18px cells needs 7 rows, not 6.
    got = resolve({"c": 20}, image=(480, 320), cell=(9, 18), anchor=(0, 0))
    eq(got["display"], {"w": 180, "h": 120}, "display")
    eq(got["cells"], {"cols": 20, "rows": 7}, "cells")
    eq(got["cursor"], {"col": 20, "row": 6}, "cursor")


@test
def rounding_boundary_table_columns_only():
    # width=3, so height = 3*h/100: 1.47->1, 1.5->2, 1.53->2,
    # 4.47->4, 4.5->5, 4.53->5, 7.5->8.
    cases = [(49, 1), (50, 2), (51, 2),
             (149, 4), (150, 5), (151, 5),
             (250, 8)]
    for image_h, expected_h in cases:
        got = resolve({"c": 1}, image=(100, image_h), cell=(3, 18))
        eq(got["display"], {"w": 3, "h": expected_h},
           "image 100x%d" % image_h)


@test
def rounding_boundary_table_rows_only():
    # height=4, so width = 4*w/8 = w/2: .5 cases all round up.
    cases = [(1, 1), (2, 1), (3, 2), (6, 3), (7, 4), (9, 5), (13, 7)]
    for image_w, expected_w in cases:
        got = resolve({"r": 1}, image=(image_w, 8), cell=(3, 4))
        eq(got["display"], {"w": expected_w, "h": 4},
           "image %dx8" % image_w)


@test
def extreme_aspect_ratio_never_rounds_to_zero():
    # 1 * 1/100 rounds to 0; a placement must still occupy one pixel.
    got = resolve({"c": 1}, image=(100, 1), cell=(1, 18))
    eq(got["display"], {"w": 1, "h": 1}, "display")
    eq(got["cells"], {"cols": 1, "rows": 1}, "cells")


# --------------------------------------------------------------------------
# source cropping
# --------------------------------------------------------------------------

@test
def source_crop_without_scaling():
    got = resolve({"x": 10, "y": 10, "w": 20, "h": 30},
                  image=(100, 100), cell=(9, 18), anchor=(1, 2))
    eq(got["src"], rect(10, 10, 20, 30), "src")
    eq(got["display"], {"w": 20, "h": 30}, "display")
    eq(got["rect"], rect(9, 36, 20, 30), "rect")
    eq(got["cells"], {"cols": 3, "rows": 2}, "cells")


@test
def source_crop_before_stretch():
    got = resolve({"x": 10, "y": 20, "w": 50, "h": 40, "c": 5, "r": 3},
                  image=(100, 100), cell=(9, 18), anchor=(0, 0))
    eq(got["src"], rect(10, 20, 50, 40), "src")
    eq(got["display"], {"w": 45, "h": 54}, "display")
    eq(got["cells"], {"cols": 5, "rows": 3}, "cells")
    eq(got["stretch"], True, "stretch")


@test
def source_crop_aspect_uses_cropped_size():
    # crop is 40x10 (4:1); c=2 with 9px cells => 18 wide, 18/4 = 4.5 -> 5.
    got = resolve({"x": 10, "y": 10, "w": 40, "h": 10, "c": 2},
                  image=(100, 100), cell=(9, 18))
    eq(got["src"], rect(10, 10, 40, 10), "src")
    eq(got["display"], {"w": 18, "h": 5}, "display")


@test
def source_crop_defaults_to_remainder():
    got = resolve({"x": 90, "y": 95}, image=(100, 100), cell=(9, 18))
    eq(got["src"], rect(90, 95, 10, 5), "src")
    eq(got["display"], {"w": 10, "h": 5}, "display")


@test
def source_crop_width_and_height_are_clamped():
    got = resolve({"x": 90, "y": 10, "w": 50, "h": 200},
                  image=(100, 100), cell=(9, 18))
    eq(got["src"], rect(90, 10, 10, 90), "src")
    eq(got["display"], {"w": 10, "h": 90}, "display")


# --------------------------------------------------------------------------
# validation
# --------------------------------------------------------------------------

@test
def invalid_source_position_raises():
    for placement in ({"x": 100}, {"x": -1}, {"y": 100}, {"y": -1}):
        expect_value_error(lambda p=placement: resolve(p),
                           "placement %r" % (placement,))


@test
def invalid_source_size_raises():
    for placement in ({"w": 0}, {"h": 0}, {"x": 10, "w": 0},
                      {"y": 10, "h": 0}, {"w": -5}, {"h": -5}):
        expect_value_error(lambda p=placement: resolve(p),
                           "placement %r" % (placement,))


@test
def invalid_columns_or_rows_raise():
    for placement in ({"c": 0}, {"r": 0}, {"c": -1}, {"r": -2}):
        expect_value_error(lambda p=placement: resolve(p),
                           "placement %r" % (placement,))


@test
def non_integer_fields_raise():
    bad = [{"c": "3"}, {"c": 2.0}, {"r": 1.5}, {"x": "0"}, {"w": True},
           {"C": 1.0}, {"z": "0"}]
    for placement in bad:
        expect_value_error(lambda p=placement: resolve(p),
                           "placement %r" % (placement,))


@test
def invalid_image_cell_and_anchor_raise():
    expect_value_error(lambda: kg.resolve({}, 0, 100, 9, 18, 0, 0),
                       "zero image width")
    expect_value_error(lambda: kg.resolve({}, 100, 0, 9, 18, 0, 0),
                       "zero image height")
    expect_value_error(lambda: kg.resolve({}, 100, 100, 0, 18, 0, 0),
                       "zero cell width")
    expect_value_error(lambda: kg.resolve({}, 100, 100, 9, 0, 0, 0),
                       "zero cell height")
    expect_value_error(lambda: kg.resolve({}, 100, 100, 9, 18, -1, 0),
                       "negative anchor column")
    expect_value_error(lambda: kg.resolve({}, 100, 100, 9, 18, 0, -1),
                       "negative anchor row")
    expect_value_error(lambda: kg.resolve([], 100, 100, 9, 18, 0, 0),
                       "non-dict placement")


# --------------------------------------------------------------------------
# cursor placement
# --------------------------------------------------------------------------

@test
def worked_example_480x320_c40():
    got = resolve({"c": 40}, image=(480, 320), cell=(9, 18), anchor=(0, 0))
    eq(got["display"], {"w": 360, "h": 240}, "display")
    eq(got["cells"], {"cols": 40, "rows": 14}, "cells")
    eq(got["cursor"], {"col": 40, "row": 13}, "cursor")
    eq(kg.cursor_after({"c": 40}, 480, 320, 9, 18, 0, 0), (41, 14),
       "cursor_after")


@test
def cursor_after_multiline_placement():
    # 100px tall at 18px cells = 6 rows, 100/9 = 12 columns.
    got = resolve({}, image=(100, 100), cell=(9, 18), anchor=(2, 3))
    eq(got["cursor"], {"col": 14, "row": 8}, "cursor")
    eq(kg.cursor_after({}, 100, 100, 9, 18, 2, 3), (15, 9), "cursor_after")


@test
def cursor_after_stretched_placement():
    got = resolve({"c": 3, "r": 2}, image=(100, 100), cell=(9, 18),
                  anchor=(4, 5))
    eq(got["cursor"], {"col": 7, "row": 6}, "cursor")
    eq(kg.cursor_after({"c": 3, "r": 2}, 100, 100, 9, 18, 4, 5),
       (8, 7), "cursor_after")


@test
def no_cursor_move_leaves_cursor_alone():
    got = resolve({"c": 4, "C": 1}, image=(480, 320), cell=(9, 18),
                  anchor=(1, 1))
    eq(got["cursor"], {"col": None, "row": None}, "cursor")
    eq(kg.cursor_after({"c": 4, "C": 1}, 480, 320, 9, 18, 1, 1), None,
       "cursor_after")
    # Geometry other than the cursor is unaffected.
    eq(got["display"], {"w": 36, "h": 24}, "display")


@test
def c0_moves_cursor_like_default():
    moved = resolve({"c": 2, "C": 0}, image=(480, 320), cell=(9, 18),
                    anchor=(0, 0))
    default = resolve({"c": 2}, image=(480, 320), cell=(9, 18), anchor=(0, 0))
    eq(moved["cursor"], default["cursor"], "cursor")


@test
def cursor_after_uses_resolve_rounding():
    # 480x320 c=20 -> 7 rows, so the cursor cell is row 6 (0-based).
    eq(kg.cursor_after({"c": 20}, 480, 320, 9, 18, 0, 0), (21, 7),
       "cursor_after")


# --------------------------------------------------------------------------
# overlap / visibility
# --------------------------------------------------------------------------

@test
def overlap_partial_intersection():
    got = kg.overlap_region(rect(0, 0, 100, 50), rect(50, 25, 100, 50))
    eq(got, rect(50, 25, 50, 25), "overlap")


@test
def overlap_none_and_touching():
    eq(kg.overlap_region(rect(0, 0, 10, 10), rect(20, 0, 10, 10)), None,
       "separated")
    eq(kg.overlap_region(rect(0, 0, 10, 10), rect(10, 0, 10, 10)), None,
       "touching x")
    eq(kg.overlap_region(rect(0, 0, 10, 10), rect(0, 10, 10, 10)), None,
       "touching y")


@test
def overlap_containment_and_identity():
    eq(kg.overlap_region(rect(0, 0, 100, 100), rect(10, 20, 30, 40)),
       rect(10, 20, 30, 40), "contained")
    eq(kg.overlap_region(rect(3, 4, 5, 6), rect(3, 4, 5, 6)),
       rect(3, 4, 5, 6), "identical")


@test
def overlap_rejects_invalid_rects():
    expect_value_error(lambda: kg.overlap_region(None, rect(0, 0, 1, 1)),
                       "non-dict rect")
    expect_value_error(
        lambda: kg.overlap_region({"x": 0, "y": 0, "w": 1}, rect(0, 0, 1, 1)),
        "missing h")


@test
def visible_rect_clips_to_viewport():
    eq(kg.visible_rect(rect(10, 10, 50, 50), 100, 100), rect(10, 10, 50, 50),
       "inside")
    eq(kg.visible_rect(rect(90, 90, 50, 50), 100, 100), rect(90, 90, 10, 10),
       "clipped")
    eq(kg.visible_rect(rect(-20, -10, 50, 50), 100, 100),
       rect(0, 0, 30, 40), "negative origin")
    eq(kg.visible_rect(rect(200, 0, 50, 50), 100, 100), None, "outside")
    eq(kg.visible_rect(rect(0, 0, 50, 50), 0, 100), None, "empty viewport")
    expect_value_error(lambda: kg.visible_rect(rect(0, 0, 1, 1), -1, 10),
                       "negative viewport")


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------

@test
def cli_resolve_matches_api():
    code, payload = run_cli("resolve", "--image", "480x320", "--cell", "9x18",
                            "--anchor", "0,0", "--columns", "40")
    eq(code, 0, "exit code")
    eq(payload, resolve({"c": 40}, image=(480, 320), cell=(9, 18)), "payload")


@test
def cli_src_rows_and_no_cursor_move():
    code, payload = run_cli("resolve", "--image", "100x100", "--cell", "9x18",
                            "--anchor", "2,3", "--src", "10,20,50,40",
                            "--rows", "2", "--no-cursor-move")
    eq(code, 0, "exit code")
    eq(payload["src"], rect(10, 20, 50, 40), "src")
    eq(payload["display"], {"w": 45, "h": 36}, "display")
    eq(payload["rect"], rect(18, 54, 45, 36), "rect")
    eq(payload["stretch"], False, "stretch")
    eq(payload["cursor"], {"col": None, "row": None}, "cursor")


@test
def cli_columns_and_rows_stretch():
    code, payload = run_cli("resolve", "--image", "100x50", "--cell", "9x18",
                            "--anchor", "1,1", "--columns", "3", "--rows", "2")
    eq(code, 0, "exit code")
    eq(payload["display"], {"w": 27, "h": 36}, "display")
    eq(payload["stretch"], True, "stretch")
    eq(payload["cursor"], {"col": 4, "row": 2}, "cursor")


@test
def cli_invalid_placement_reports_error():
    code, payload = run_cli("resolve", "--image", "100x100", "--cell", "9x18",
                            "--anchor", "0,0", "--columns", "0")
    eq(code, 2, "exit code")
    if "error" not in payload:
        raise AssertionError("expected an error payload, got %r" % (payload,))


@test
def cli_rejects_malformed_arguments():
    code, _ = run_cli("resolve", "--image", "100", "--cell", "9x18",
                      "--anchor", "0,0")
    eq(code, 2, "exit code for malformed --image")


# --------------------------------------------------------------------------
# runner
# --------------------------------------------------------------------------

def main():
    failures = 0
    for fn in TESTS:
        try:
            fn()
        except Exception as exc:  # noqa: BLE001 - report every failure
            failures += 1
            print("FAIL %s: %s" % (fn.__name__, exc))
        else:
            print("ok %s" % fn.__name__)
    total = len(TESTS)
    if failures:
        print("FAILED: %d of %d tests failed" % (failures, total))
        return 1
    print("ok: %d/%d tests passed" % (total, total))
    return 0


if __name__ == "__main__":
    sys.exit(main())
