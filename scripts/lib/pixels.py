#!/usr/bin/env python3
"""Pixel assertions for screenshot tests.

Standalone: python3 + Pillow only.  numpy is used when available (faster), but
every command works without it.

Usage:
    pixels.py --image shot.png --color '#FF0000' count
    pixels.py --image shot.png --color '255,0,0' --region 10,10,100,50 bbox
    pixels.py --image shot.png --color '#00FF00' assert --min-fraction 0.05
    pixels.py --image a.png --image-b b.png diff --max-changed-fraction 0
    pixels.py --image shot.png dominant

All results are JSON on stdout; ``--json PATH`` mirrors them to a file.
Exit codes: 0 = success/pass, 1 = assertion failed, 2 = error.
"""

import argparse
import json
import os
import re
import sys

try:
    from PIL import Image
except ImportError:  # pragma: no cover - environment guard
    print(json.dumps({"error": "Pillow (PIL) is required: python3 -m pip install Pillow"}))
    sys.exit(2)

try:  # optional fast path
    import numpy as np
except Exception:  # pragma: no cover - exercised only without numpy
    np = None


class ArgError(Exception):
    """Raised for any user-facing error; maps to exit code 2 + JSON."""


# --------------------------------------------------------------------------
# parsing helpers
# --------------------------------------------------------------------------

def parse_color(text):
    """Accept '#RRGGBB', 'RRGGBB' or 'R,G,B' (case-insensitive)."""
    if text is None:
        raise ArgError("--color is required for this command")
    raw = text.strip()
    if not raw:
        raise ArgError("--color must not be empty")
    if "," in raw:
        parts = [p.strip() for p in raw.split(",")]
        if len(parts) != 3:
            raise ArgError("invalid color %r: expected '#RRGGBB' or 'R,G,B'" % text)
        values = []
        for part in parts:
            if not re.fullmatch(r"\d{1,3}", part):
                raise ArgError("invalid color %r: each component must be 0-255" % text)
            value = int(part)
            if value > 255:
                raise ArgError("invalid color %r: each component must be 0-255" % text)
            values.append(value)
        return tuple(values)
    raw = raw[1:] if raw.startswith("#") else raw
    if not re.fullmatch(r"[0-9a-fA-F]{6}", raw):
        raise ArgError("invalid color %r: expected '#RRGGBB' or 'R,G,B'" % text)
    return tuple(int(raw[i:i + 2], 16) for i in (0, 2, 4))


def hex_color(color):
    return "#%02X%02X%02X" % tuple(color)


def parse_region(text, size):
    """Return an absolute (x, y, w, h) region validated against *size*."""
    width, height = size
    if text is None:
        return (0, 0, width, height)
    parts = [p.strip() for p in text.split(",")]
    if len(parts) != 4 or not all(re.fullmatch(r"-?\d+", p) for p in parts):
        raise ArgError("invalid --region %r: expected x,y,w,h" % text)
    x, y, w, h = (int(p) for p in parts)
    if w <= 0 or h <= 0:
        raise ArgError("invalid --region %r: width and height must be positive" % text)
    if x < 0 or y < 0:
        raise ArgError("invalid --region %r: x and y must be >= 0" % text)
    if x + w > width or y + h > height:
        raise ArgError(
            "region %r out of bounds for image %dx%d" % (text, width, height)
        )
    return (x, y, w, h)


def fraction(count, total):
    return round(count / total, 6) if total else 0.0


# --------------------------------------------------------------------------
# analysis
# --------------------------------------------------------------------------

class Analysis:
    """One image + region, with exact/fuzzy color matching."""

    def __init__(self, path, region_spec, fuzz):
        if not path:
            raise ArgError("--image is required")
        if not os.path.isfile(path):
            raise ArgError("image not found: %s" % path)
        try:
            image = Image.open(path)
            image.load()
        except Exception as exc:
            raise ArgError("cannot open image %s: %s" % (path, exc))
        if image.mode != "RGB":
            image = image.convert("RGB")
        self.path = path
        self.image = image
        self.size = image.size
        self.region = parse_region(region_spec, image.size)
        self.fuzz = fuzz
        x, y, w, h = self.region
        self.crop = image.crop((x, y, x + w, y + h))
        self.total = w * h
        self._array = None

    # -- pixel data ------------------------------------------------------
    @property
    def array(self):
        if self._array is None and np is not None:
            self._array = np.asarray(self.crop, dtype=np.uint8)
        return self._array

    def _matched_positions(self, color):
        """Yield (count, x0, y0, x1, y1) in region-local coordinates."""
        fuzz = self.fuzz
        if np is not None:
            arr = self.array.astype(np.int16)
            target = np.array(color, dtype=np.int16)
            mask = np.abs(arr - target).max(axis=2) <= fuzz
            count = int(mask.sum())
            if count:
                rows, cols = np.nonzero(mask)
                return count, int(cols.min()), int(rows.min()), int(cols.max()), int(rows.max())
            return 0, 0, 0, -1, -1

        # Pillow-only fallback: scan the raw RGB byte stream.
        data = self.crop.tobytes()
        size = self.total
        width = self.region[2]
        count = 0
        min_x = min_y = None
        max_x = max_y = None
        r, g, b = color
        for i in range(size):
            offset = i * 3
            if (abs(data[offset] - r) <= fuzz
                    and abs(data[offset + 1] - g) <= fuzz
                    and abs(data[offset + 2] - b) <= fuzz):
                count += 1
                x = i % width
                y = i // width
                if min_x is None or x < min_x:
                    min_x = x
                if max_x is None or x > max_x:
                    max_x = x
                if min_y is None or y < min_y:
                    min_y = y
                if max_y is None or y > max_y:
                    max_y = y
        if count == 0:
            return 0, 0, 0, -1, -1
        return count, min_x, min_y, max_x, max_y

    def analyze(self, color):
        count, x0, y0, x1, y1 = self._matched_positions(color)
        found = count > 0
        if found:
            rx, ry = self.region[0], self.region[1]
            bw = x1 - x0 + 1
            bh = y1 - y0 + 1
            bbox = {
                "found": True,
                "x": rx + x0,
                "y": ry + y0,
                "w": bw,
                "h": bh,
                "count": count,
                "fraction_in_bbox": fraction(count, bw * bh),
            }
        else:
            bbox = {
                "found": False,
                "x": 0,
                "y": 0,
                "w": 0,
                "h": 0,
                "count": 0,
                "fraction_in_bbox": 0.0,
            }
        return {
            "count": count,
            "total": self.total,
            "fraction": fraction(count, self.total),
            "bbox": bbox,
        }

    def dominant(self, limit=8):
        """Top *limit* exact colors, ordered by count desc then RGB asc."""
        counts = self.crop.getcolors(maxcolors=1 << 24)
        if counts is None:  # pathological: more than 16M colors
            counts = []
            for value, n in sorted(self.crop.getcolors(maxcolors=self.total) or []):
                counts.append((n, value))
        counts.sort(key=lambda item: (-item[0], item[1]))
        return [
            {
                "color": hex_color(color),
                "count": int(count),
                "fraction": fraction(count, self.total),
            }
            for count, color in counts[:limit]
        ]


def changed_pixels(a, b, fuzz):
    """Number of pixels in the shared region differing by more than *fuzz*."""
    if np is not None:
        left = a.array.astype(np.int16)
        right = b.array.astype(np.int16)
        delta = np.abs(left - right).max(axis=2)
        return int((delta > fuzz).sum())

    left = a.crop.tobytes()
    right = b.crop.tobytes()
    changed = 0
    for i in range(a.total):
        offset = i * 3
        if (abs(left[offset] - right[offset]) > fuzz
                or abs(left[offset + 1] - right[offset + 1]) > fuzz
                or abs(left[offset + 2] - right[offset + 2]) > fuzz):
            changed += 1
    return changed


# --------------------------------------------------------------------------
# commands
# --------------------------------------------------------------------------

def cmd_count(args):
    color = parse_color(args.color)
    image = Analysis(args.image, args.region, args.fuzz)
    result = image.analyze(color)
    return {
        "command": "count",
        "count": result["count"],
        "total": result["total"],
        "fraction": result["fraction"],
        "color": hex_color(color),
        "region": list(image.region),
    }, 0


def cmd_bbox(args):
    color = parse_color(args.color)
    image = Analysis(args.image, args.region, args.fuzz)
    result = image.analyze(color)
    bbox = result["bbox"]
    return {
        "command": "bbox",
        "found": bbox["found"],
        "x": bbox["x"],
        "y": bbox["y"],
        "w": bbox["w"],
        "h": bbox["h"],
        "count": bbox["count"],
        "fraction_in_bbox": bbox["fraction_in_bbox"],
        "color": hex_color(color),
        "region": list(image.region),
    }, 0


def cmd_assert(args):
    color = parse_color(args.color)
    for name in ("min_fraction", "max_fraction", "min_count", "bbox_max_w", "bbox_max_h"):
        value = getattr(args, name)
        if value is not None and value < 0:
            raise ArgError("--%s must be >= 0" % name.replace("_", "-"))
    if (args.min_fraction is not None and args.max_fraction is not None
            and args.min_fraction > args.max_fraction):
        raise ArgError("--min-fraction must not exceed --max-fraction")

    image = Analysis(args.image, args.region, args.fuzz)
    result = image.analyze(color)
    bbox = result["bbox"]

    checks = {}
    if args.min_fraction is not None:
        checks["min_fraction"] = {
            "required": args.min_fraction,
            "actual": result["fraction"],
            "pass": result["fraction"] >= args.min_fraction,
        }
    if args.max_fraction is not None:
        checks["max_fraction"] = {
            "required": args.max_fraction,
            "actual": result["fraction"],
            "pass": result["fraction"] <= args.max_fraction,
        }
    if args.min_count is not None:
        checks["min_count"] = {
            "required": int(args.min_count),
            "actual": result["count"],
            "pass": result["count"] >= args.min_count,
        }
    if args.bbox_max_w is not None:
        checks["bbox_max_w"] = {
            "required": int(args.bbox_max_w),
            "actual": bbox["w"],
            "pass": bbox["w"] <= args.bbox_max_w,
        }
    if args.bbox_max_h is not None:
        checks["bbox_max_h"] = {
            "required": int(args.bbox_max_h),
            "actual": bbox["h"],
            "pass": bbox["h"] <= args.bbox_max_h,
        }

    passed = all(check["pass"] for check in checks.values())
    return {
        "command": "assert",
        "pass": passed,
        "count": result["count"],
        "total": result["total"],
        "fraction": result["fraction"],
        "color": hex_color(color),
        "region": list(image.region),
        "bbox": bbox,
        "checks": checks,
    }, 0 if passed else 1


def cmd_diff(args):
    if not args.image_b:
        raise ArgError("--image-b is required for diff")
    if not os.path.isfile(args.image_b):
        raise ArgError("image not found: %s" % args.image_b)
    if args.max_changed_fraction < 0:
        raise ArgError("--max-changed-fraction must be >= 0")

    image_a = Analysis(args.image, args.region, args.fuzz)
    image_b = Analysis(args.image_b, args.region, args.fuzz)
    if image_a.size != image_b.size:
        raise ArgError(
            "image size mismatch: %dx%d vs %dx%d"
            % (image_a.size + image_b.size)
        )
    total = image_a.total
    changed = changed_pixels(image_a, image_b, args.fuzz)
    value = fraction(changed, total)
    passed = value <= args.max_changed_fraction
    return {
        "command": "diff",
        "changed_pixels": changed,
        "total": total,
        "fraction": value,
        "pass": passed,
        "max_changed_fraction": args.max_changed_fraction,
        "region": list(image_a.region),
    }, 0 if passed else 1


def cmd_dominant(args):
    image = Analysis(args.image, args.region, args.fuzz)
    return {
        "command": "dominant",
        "colors": image.dominant(8),
        "total": image.total,
        "region": list(image.region),
    }, 0


COMMANDS = {
    "count": cmd_count,
    "bbox": cmd_bbox,
    "assert": cmd_assert,
    "diff": cmd_diff,
    "dominant": cmd_dominant,
}


# --------------------------------------------------------------------------
# CLI plumbing
# --------------------------------------------------------------------------

class JsonArgumentParser(argparse.ArgumentParser):
    def error(self, message):
        raise ArgError(message)


def add_common_arguments(parser, suppressed=False):
    default = argparse.SUPPRESS if suppressed else None
    parser.add_argument("--image", metavar="PATH", default=default,
                        help="screenshot to analyse")
    parser.add_argument("--color", metavar="COLOR", default=default,
                        help="'#RRGGBB', 'RRGGBB' or 'R,G,B'")
    parser.add_argument("--fuzz", metavar="N", type=int, default=default,
                        help="max per-channel absolute difference (default 0)")
    parser.add_argument("--region", metavar="x,y,w,h", default=default,
                        help="crop before analysis")
    parser.add_argument("--json", dest="json_path", metavar="PATH", default=default,
                        help="also write the JSON result here")


def add_assert_arguments(parser, suppressed=False):
    default = argparse.SUPPRESS if suppressed else None
    parser.add_argument("--min-fraction", type=float, default=default, metavar="F")
    parser.add_argument("--max-fraction", type=float, default=default, metavar="F")
    parser.add_argument("--min-count", type=int, default=default, metavar="N")
    parser.add_argument("--bbox-max-w", type=int, default=default, metavar="W")
    parser.add_argument("--bbox-max-h", type=int, default=default, metavar="H")


def add_diff_arguments(parser, suppressed=False):
    image_b = argparse.SUPPRESS if suppressed else None
    max_changed = argparse.SUPPRESS if suppressed else 1.0
    parser.add_argument("--image-b", metavar="PATH", default=image_b)
    parser.add_argument("--max-changed-fraction", type=float,
                        default=max_changed, metavar="F")


def build_parser():
    parser = JsonArgumentParser(prog="pixels.py", description=__doc__)
    add_common_arguments(parser, suppressed=False)
    add_assert_arguments(parser, suppressed=False)
    add_diff_arguments(parser, suppressed=False)

    common = JsonArgumentParser(add_help=False)
    add_common_arguments(common, suppressed=True)
    assert_args = JsonArgumentParser(add_help=False)
    add_assert_arguments(assert_args, suppressed=True)
    diff_args = JsonArgumentParser(add_help=False)
    add_diff_arguments(diff_args, suppressed=True)

    subparsers = parser.add_subparsers(dest="command", metavar="command")

    subparsers.add_parser("count", parents=[common], help="count matching pixels")
    subparsers.add_parser("bbox", parents=[common], help="bounding box of matching pixels")
    subparsers.add_parser("assert", parents=[common, assert_args],
                          help="assert pixel constraints")
    subparsers.add_parser("diff", parents=[common, diff_args],
                          help="compare two images")
    subparsers.add_parser("dominant", parents=[common],
                          help="top 8 exact colors in the region")
    return parser


def emit(result, json_path=None):
    text = json.dumps(result)
    print(text)
    if json_path:
        parent = os.path.dirname(os.path.abspath(json_path))
        try:
            if parent and not os.path.isdir(parent):
                os.makedirs(parent, exist_ok=True)
            with open(json_path, "w", encoding="utf-8") as handle:
                handle.write(text + "\n")
        except OSError as exc:
            raise ArgError("cannot write --json %s: %s" % (json_path, exc))
    sys.stdout.flush()


def fail(message):
    print(json.dumps({"error": message}))
    sys.stdout.flush()
    return 2


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    parser = build_parser()
    try:
        args = parser.parse_args(argv)
        if not getattr(args, "command", None):
            raise ArgError("missing subcommand: choose count, bbox, assert, diff or dominant")
        fuzz = getattr(args, "fuzz", 0)
        if fuzz is None:
            fuzz = 0
        if fuzz < 0:
            raise ArgError("--fuzz must be >= 0")
        args.fuzz = fuzz
        image = getattr(args, "image", None)
        if not image:
            raise ArgError("--image is required")
        args.image = image
        json_path = getattr(args, "json_path", None)
        max_changed = getattr(args, "max_changed_fraction", 1.0)
        if args.command == "diff" and max_changed < 0:
            raise ArgError("--max-changed-fraction must be >= 0")

        result, code = COMMANDS[args.command](args)
        emit(result, json_path)
        return code
    except ArgError as exc:
        return fail(str(exc))
    except BrokenPipeError:  # pragma: no cover
        return 0


if __name__ == "__main__":
    sys.exit(main())
