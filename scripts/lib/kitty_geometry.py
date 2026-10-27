#!/usr/bin/env python3
"""Pure geometry for Kitty graphics placements.

Standalone: python3 stdlib only, no terminal or image library required.

The module turns a placement spec (as sent by the terminal harness through
``emit_imgcat.py`` / the OSC 1337-image path) into the rectangles a screenshot
test should find on screen.  All coordinates are integers in pixels; ``rect``
is relative to the top-left of the terminal content area.

Placement semantics implemented here (the subset the tests use):

* The transmitted image has pixel size ``(image_w, image_h)``.  A placement
  may crop it with a source rectangle ``x, y, w, h`` (defaults: ``x=y=0``,
  ``w=image_w-x``, ``h=image_h-y``); cropping happens before scaling.
* The image is anchored at grid cell ``(anchor_col, anchor_row)`` (0-based)
  whose top-left pixel is ``(anchor_col*cell_w, anchor_row*cell_h)``.
* Neither ``c`` nor ``r``: displayed size is the source rect size, unclipped
  by cells.
* Only ``c``: width is ``c*cell_w``, height keeps the source aspect ratio.
* Only ``r``: height is ``r*cell_h``, width keeps the source aspect ratio.
* Both ``c`` and ``r``: the image is stretched to exactly ``c*cell_w`` by
  ``r*cell_h``.
* ``C=1`` leaves the cursor where it is; otherwise it lands on the cell after
  the last occupied column of the placement, on the placement's last row.

Rounding: aspect-ratio sizes round halves up (``4.5 -> 5``).  This is chosen
so the values are stable and easy to reproduce in assertions; the eventual
terminal implementation is expected to match or be reconciled by the harness
manager.

Usage:
    kitty_geometry.py resolve --image 480x320 --cell 9x18 --anchor 0,0 \\
        --columns 40
    kitty_geometry.py resolve --image 480x320 --cell 9x18 --anchor 2,3 \\
        --src 10,10,100,80 --rows 5 --no-cursor-move

JSON is written to stdout.  Exit codes: 0 = ok, 2 = invalid input.
"""

import argparse
import json
import sys


class GeometryError(ValueError):
    """Raised for invalid placement or image/cell parameters."""


# --------------------------------------------------------------------------
# validation helpers
# --------------------------------------------------------------------------

def _as_int(value, name, minimum=None):
    """Return ``value`` as an int, rejecting bools, floats and strings."""
    if isinstance(value, bool) or not isinstance(value, int):
        raise GeometryError("%s must be an integer, got %r" % (name, value))
    if minimum is not None and value < minimum:
        raise GeometryError("%s must be >= %d, got %d" % (name, minimum, value))
    return value


def _placement_int(placement, key, minimum, default=None):
    """Read an optional integer field from a placement dict.

    A missing field and a field explicitly set to ``None`` both mean "not
    supplied", which keeps JSON round-trips convenient.
    """
    if key not in placement or placement[key] is None:
        return default
    return _as_int(placement[key], key, minimum=minimum)


def _ceil_div(num, den):
    return -(-num // den)


def _round_half_up_ratio(num, den):
    """Round ``num/den`` to the nearest integer, halves up (exact int math)."""
    return (2 * num + den) // (2 * den)


def _rect(x, y, w, h):
    return {"x": x, "y": y, "w": w, "h": h}


# --------------------------------------------------------------------------
# core API
# --------------------------------------------------------------------------

def resolve(placement, image_w, image_h, cell_w, cell_h,
            anchor_col, anchor_row):
    """Resolve a Kitty placement to screen geometry.

    ``placement`` keys understood: ``c``, ``r``, ``x``, ``y``, ``w``, ``h``,
    ``z`` (validated but not returned) and ``C`` (1 = do not move the cursor).

    Returns a dict::

        {"src": {"x","y","w","h"},
         "display": {"w","h"},
         "rect": {"x","y","w","h"},
         "cells": {"cols","rows"},
         "stretch": bool,
         "cursor": {"col": int|None, "row": int|None}}
    """
    if not isinstance(placement, dict):
        raise GeometryError("placement must be a dict, got %r" % (placement,))

    image_w = _as_int(image_w, "image_w", minimum=1)
    image_h = _as_int(image_h, "image_h", minimum=1)
    cell_w = _as_int(cell_w, "cell_w", minimum=1)
    cell_h = _as_int(cell_h, "cell_h", minimum=1)
    anchor_col = _as_int(anchor_col, "anchor_col", minimum=0)
    anchor_row = _as_int(anchor_row, "anchor_row", minimum=0)

    cols = _placement_int(placement, "c", minimum=1)
    rows = _placement_int(placement, "r", minimum=1)
    no_cursor_move = _placement_int(placement, "C", minimum=0, default=0)
    _placement_int(placement, "z", minimum=None, default=0)

    # ---- source rectangle (crop within the transmitted image) -------------
    src_x = _placement_int(placement, "x", minimum=None, default=0)
    src_y = _placement_int(placement, "y", minimum=None, default=0)
    if src_x < 0 or src_x >= image_w:
        raise GeometryError(
            "source x %d out of range for image width %d" % (src_x, image_w))
    if src_y < 0 or src_y >= image_h:
        raise GeometryError(
            "source y %d out of range for image height %d" % (src_y, image_h))

    src_w = _placement_int(placement, "w", minimum=None,
                           default=image_w - src_x)
    src_h = _placement_int(placement, "h", minimum=None,
                           default=image_h - src_y)
    if src_w < 0 or src_h < 0:
        raise GeometryError(
            "source size must not be negative, got %dx%d" % (src_w, src_h))
    if src_w == 0 or src_h == 0:
        raise GeometryError("source rectangle has zero area")
    if src_w > image_w - src_x:
        src_w = image_w - src_x
    if src_h > image_h - src_y:
        src_h = image_h - src_y
    if src_w == 0 or src_h == 0:
        raise GeometryError("source rectangle has zero area after clamping")

    # ---- displayed size ---------------------------------------------------
    if cols is not None and rows is not None:
        display_w = cols * cell_w
        display_h = rows * cell_h
        stretch = True
    elif cols is not None:
        display_w = cols * cell_w
        display_h = _round_half_up_ratio(display_w * src_h, src_w)
        stretch = False
    elif rows is not None:
        display_h = rows * cell_h
        display_w = _round_half_up_ratio(display_h * src_w, src_h)
        stretch = False
    else:
        display_w = src_w
        display_h = src_h
        stretch = False

    # A ratio can legitimately round down to 0 for extreme aspect ratios; a
    # zero-pixel image cannot be placed, so keep it at least one pixel.
    display_w = max(1, display_w)
    display_h = max(1, display_h)

    rect = _rect(anchor_col * cell_w, anchor_row * cell_h,
                 display_w, display_h)

    cell_cols = _ceil_div(display_w, cell_w)
    cell_rows = _ceil_div(display_h, cell_h)

    if no_cursor_move == 1:
        cursor_col = None
        cursor_row = None
    else:
        cursor_col = anchor_col + cell_cols
        cursor_row = anchor_row + cell_rows - 1

    return {
        "src": _rect(src_x, src_y, src_w, src_h),
        "display": {"w": display_w, "h": display_h},
        "rect": rect,
        "cells": {"cols": cell_cols, "rows": cell_rows},
        "stretch": stretch,
        "cursor": {"col": cursor_col, "row": cursor_row},
    }


def cursor_after(placement, image_w, image_h, cell_w, cell_h,
                 anchor_col, anchor_row):
    """1-based cursor cell after a placement, for DSR comparisons.

    Returns ``(col, row)`` or ``None`` when the placement uses ``C=1``.
    """
    result = resolve(placement, image_w, image_h, cell_w, cell_h,
                     anchor_col, anchor_row)
    col = result["cursor"]["col"]
    row = result["cursor"]["row"]
    if col is None or row is None:
        return None
    return (col + 1, row + 1)


# --------------------------------------------------------------------------
# rectangle helpers
# --------------------------------------------------------------------------

def _normalize_rect(rect, label):
    if not isinstance(rect, dict):
        raise GeometryError("%s must be a rect dict, got %r" % (label, rect))
    x = _as_int(rect.get("x"), "%s.x" % label)
    y = _as_int(rect.get("y"), "%s.y" % label)
    w = _as_int(rect.get("w"), "%s.w" % label)
    h = _as_int(rect.get("h"), "%s.h" % label)
    return x, y, w, h


def overlap_region(a, b):
    """Intersection of two rects, or ``None`` when they do not overlap.

    Edge-touching rects do not overlap (the intersection has zero area).
    """
    ax, ay, aw, ah = _normalize_rect(a, "a")
    bx, by, bw, bh = _normalize_rect(b, "b")
    left = max(ax, bx)
    top = max(ay, by)
    right = min(ax + aw, bx + bw)
    bottom = min(ay + ah, by + bh)
    if right <= left or bottom <= top:
        return None
    return _rect(left, top, right - left, bottom - top)


def visible_rect(rect, viewport_w, viewport_h):
    """Clip ``rect`` to the viewport starting at the content origin.

    Returns the clipped rect or ``None`` when nothing is visible.
    """
    viewport_w = _as_int(viewport_w, "viewport_w", minimum=0)
    viewport_h = _as_int(viewport_h, "viewport_h", minimum=0)
    return overlap_region(rect, _rect(0, 0, viewport_w, viewport_h))


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------

def _parse_pair(text, name, sep):
    parts = text.split(sep)
    if len(parts) != 2:
        raise argparse.ArgumentTypeError(
            "%s must be formatted as A%sB, got %r" % (name, sep, text))
    try:
        return int(parts[0].strip()), int(parts[1].strip())
    except ValueError:
        raise argparse.ArgumentTypeError(
            "%s must contain integers, got %r" % (name, text))


def _parse_size(text):
    return _parse_pair(text, "--image", "x")


def _parse_cell(text):
    return _parse_pair(text, "--cell", "x")


def _parse_anchor(text):
    return _parse_pair(text, "--anchor", ",")


def _parse_src(text):
    parts = text.split(",")
    if len(parts) != 4:
        raise argparse.ArgumentTypeError(
            "--src must be formatted as x,y,w,h, got %r" % (text,))
    try:
        return tuple(int(p.strip()) for p in parts)
    except ValueError:
        raise argparse.ArgumentTypeError(
            "--src must contain integers, got %r" % (text,))


def build_parser():
    parser = argparse.ArgumentParser(
        prog="kitty_geometry.py",
        description="Resolve Kitty graphics placements to screen rectangles.")
    sub = parser.add_subparsers(dest="command", required=True)

    res = sub.add_parser("resolve", help="resolve one placement to JSON")
    res.add_argument("--image", type=_parse_size, required=True,
                     metavar="WxH", help="transmitted image size in pixels")
    res.add_argument("--cell", type=_parse_cell, required=True,
                     metavar="CWxCH", help="cell size in pixels")
    res.add_argument("--anchor", type=_parse_anchor, required=True,
                     metavar="C,R", help="0-based anchor cell")
    res.add_argument("--columns", type=int, metavar="N", help="placement c")
    res.add_argument("--rows", type=int, metavar="N", help="placement r")
    res.add_argument("--src", type=_parse_src, metavar="x,y,w,h",
                     help="source rectangle in image pixels")
    res.add_argument("--no-cursor-move", action="store_true",
                     help="emit C=1 (cursor stays put)")
    return parser


def _cmd_resolve(args):
    placement = {}
    if args.columns is not None:
        placement["c"] = args.columns
    if args.rows is not None:
        placement["r"] = args.rows
    if args.src is not None:
        placement["x"], placement["y"], placement["w"], placement["h"] = args.src
    if args.no_cursor_move:
        placement["C"] = 1
    image_w, image_h = args.image
    cell_w, cell_h = args.cell
    anchor_col, anchor_row = args.anchor
    return resolve(placement, image_w, image_h, cell_w, cell_h,
                   anchor_col, anchor_row)


def main(argv=None):
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        payload = _cmd_resolve(args)
    except GeometryError as exc:
        print(json.dumps({"error": str(exc)}))
        return 2
    print(json.dumps(payload))
    return 0


if __name__ == "__main__":
    sys.exit(main())
