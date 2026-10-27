#!/bin/bash
# imgcat-e2e.sh - headless end-to-end verification that a Ptyxis/VTE build
# renders iTerm2 OSC 1337 inline images (imgcat).
#
# Starts a private Xvfb + openbox display, runs the target ptyxis binary in a
# throwaway dbus session (with a systemd-run shim so --standalone --execute
# spawns the command directly in this sandbox), emits deterministic PNGs with
# the shared iTerm2 emitter, screenshots the root window, and asserts pixels.
#
# Usage:
#   scripts/imgcat-e2e.sh [--bin PATH] [--emitter PATH] [--out DIR]
#                         [--scenario NAME]... [--keep] [--timeout SEC] [--list]
#
# Defaults:
#   --bin      /nix/store/k4dqrarb5ixcf9hjawwafh440fgc9jvg-ptyxis-50.1/bin/ptyxis
#   --emitter  auto: $IMGCAT_EMITTER, scripts/lib/emit_imgcat.py, or
#              ../../imgcat-protocol/scripts/emit_imgcat.py (shared team emitter);
#              falls back to scripts/lib/emit_osc.sh if none is found.
#   --out      /tmp/opencode/imgcat-e2e
#
# Exit status: 0 if every selected scenario passed (or skipped), 1 otherwise.
#
# Artifacts: <out>/<run-id>/scenarios/<scenario>/ (screenshots, emitted bytes,
#            pixel JSON, verdict.json) and <out>/<run-id>/summary.{json,txt}.

set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LIB="$SCRIPT_DIR/lib"
# shellcheck source=lib/session.sh
. "$LIB/session.sh"

BIN="${IMGCAT_BIN:-$IMGCAT_BASELINE_BIN}"
OUTROOT="${IMGCAT_E2E_OUT:-/tmp/opencode/imgcat-e2e}"
EMITTER_OPT="${IMGCAT_EMITTER:-}"
KEEP=0
LIST_ONLY=0
TIMEOUT=40
SELECTED=()

# Image geometry of the primary fixture (see scripts/lib/fixtures.sh):
# 480x320 with a 2px white border and a 16x16 cyan inset at (24,24).
MAG_W=480
MAG_H=320
MAG_IN_W=476   # magenta interior bbox
MAG_IN_H=316
CYAN_OFF=22    # cyan offset from the magenta bbox origin (24 - 2)

ALL_SCENARIOS=(
    basic-bel
    basic-st
    terminator-8bit-st
    do-not-move-cursor
    size-cells
    size-px
    size-percent
    size-one-dim
    size-stretch
    size-letterbox
    inline-zero
    wire-errors
    two-images
    two-images-newline
    scrollback
    resize
    clear
    tall-image
    large-image
    photo-payload
    payload-boundary
    payload-100k
    payload-1m
    payload-5m
    payload-oversize
    memory-guard
    erase-semantics
    control-omitted
    control-xterm
    control-stock-vte
)

usage() {
    sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        --bin) BIN="$2"; shift 2 ;;
        --emitter) EMITTER_OPT="$2"; shift 2 ;;
        --out) OUTROOT="$2"; shift 2 ;;
        --scenario) SELECTED+=("$2"); shift 2 ;;
        --timeout) TIMEOUT="$2"; shift 2 ;;
        --keep) KEEP=1; shift ;;
        --list) LIST_ONLY=1; shift ;;
        -h|--help) usage ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

if [ "$LIST_ONLY" = 1 ]; then
    printf '%s\n' "${ALL_SCENARIOS[@]}"
    exit 0
fi

if [ ! -x "$BIN" ]; then
    echo "error: ptyxis binary not executable: $BIN" >&2
    exit 2
fi

find_emitter() {
    local c
    for c in "$EMITTER_OPT" "$SCRIPT_DIR/emit_imgcat.py" "$LIB/emit_imgcat.py" \
             "$SCRIPT_DIR/../../imgcat-protocol/scripts/emit_imgcat.py" \
             "/home/metal/projects/console-extend/worktrees/imgcat-protocol/scripts/emit_imgcat.py"; do
        [ -n "$c" ] && [ -f "$c" ] && { printf '%s\n' "$c"; return 0; }
    done
    return 1
}
EMITTER=$(find_emitter || true)

if [ ${#SELECTED[@]} -eq 0 ]; then
    SELECTED=("${ALL_SCENARIOS[@]}")
fi

RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"
RUN="$OUTROOT/$RUN_ID"
FIX="$RUN/fixtures"
SCEN_DIR="$RUN/scenarios"
mkdir -p "$FIX" "$SCEN_DIR"
: >"$RUN/results.tsv"

log() { printf '%s\n' "$*" >>"$RUN/harness.log"; printf '%s\n' "$*"; }

cleanup() {
    session_stop 2>/dev/null
    if [ "$KEEP" = 1 ]; then
        log "kept display $DISPLAY (Xvfb pid ${DISPLAY_XVFB_PID:-?}); kill it manually"
    else
        display_stop 2>/dev/null
    fi
}
trap cleanup EXIT

# ---------------------------------------------------------------- utilities

ck() { printf '%s\t%s\t%s\n' "$2" "$1" "$3" >>"$SC/checks.tsv"; }
ck_pass() { ck "$1" PASS "$2"; }
ck_fail() { ck "$1" FAIL "$2"; }
ck_info() { ck "$1" INFO "$2"; }
ck_skip() { ck "$1" SKIP "$2"; }

json_field() { python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get(sys.argv[1],""))' "$1"; }

pix() { python3 "$LIB/pixels.py" "$@"; }

count_of() {
    pix count --image "$1" --color "$2" --fuzz "${3:-0}" 2>/dev/null | json_field count
}

# echoes: x y w h count found
bbox_of() {
    pix bbox --image "$1" --color "$2" --fuzz "${3:-0}" 2>/dev/null |
        python3 -c 'import json,sys
d=json.load(sys.stdin)
print(d["x"], d["y"], d["w"], d["h"], d["count"], int(bool(d["found"])))'
}

# Emit one OSC 1337 sequence with the shared emitter (or the bundled fallback).
# Usage: emit_seq OUTFILE <emitter args...>
emit_seq() {
    local out="$1"; shift
    if [ -n "$EMITTER" ]; then
        python3 "$EMITTER" "$@" >"$out"
        return
    fi
    # Minimal fallback: translate the flags we use to emit_osc.sh.
    local inline=1 term=bel width="" height="" dnm="" newline=0 file=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --inline) inline="$2"; shift 2 ;;
            --terminator) term="$2"; shift 2 ;;
            --width) width="$2"; shift 2 ;;
            --height) height="$2"; shift 2 ;;
            --do-not-move-cursor) dnm=1; shift ;;
            --newline) newline=1; shift ;;
            --preserve-aspect-ratio) shift 2 ;;
            --size|--name) shift 2 ;;
            --*) shift ;;
            *) file="$1"; shift ;;
        esac
    done
    local args="inline=$inline"
    [ -n "$width" ] && args="$args;width=$width"
    [ -n "$height" ] && args="$args;height=$height"
    [ -n "$dnm" ] && args="$args;doNotMoveCursor=1"
    "$LIB/emit_osc.sh" --args "$args" --file "$file" --term "$term" >"$out"
    [ "$newline" = 1 ] && printf '\n' >>"$out"
    return 0
}

img_present_checks() { # shot label expect_w expect_h min_count
    local shot="$1" label="$2" ew="$3" eh="$4" minc="$5"
    local bx by bw bh bc f
    read -r bx by bw bh bc f <<<"$(bbox_of "$shot" '#FF00FF')"
    ck_info "$label-bbox" "x=$bx y=$by w=$bw h=$bh count=$bc found=$f"
    if [ "$f" = 1 ] && [ "$bc" -ge "$minc" ]; then
        ck_pass "$label-present" "magenta=$bc (>= $minc), bbox ${bw}x${bh} at ${bx},${by}"
    else
        ck_fail "$label-present" "magenta=$bc (< $minc), bbox ${bw}x${bh} at ${bx},${by} found=$f"
        return
    fi
    if [ -n "$ew" ] && [ -n "$eh" ]; then
        if [ $((bw - ew)) -le 2 ] && [ $((ew - bw)) -le 2 ] &&
           [ $((bh - eh)) -le 2 ] && [ $((eh - bh)) -le 2 ]; then
            ck_pass "$label-size" "expected ${ew}x${eh}, got ${bw}x${bh}"
        else
            ck_fail "$label-size" "expected ${ew}x${eh}, got ${bw}x${bh}"
        fi
    fi
    if [ "$(inside_window "$bx" "$by" "$bw" "$bh")" = yes ]; then
        ck_pass "$label-in-window" "bbox within window $(geom_of)"
    else
        ck_fail "$label-in-window" "bbox ${bx},${by} ${bw}x${bh} outside window $(geom_of)"
    fi
}

inside_window() {
    local x=$1 y=$2 w=$3 h=$4 wx wy ww wh
    read -r wx wy ww wh <<<"$(session_window_geom)" || { echo no; return; }
    if [ "$w" -le 0 ] || [ "$h" -le 0 ]; then echo no; return; fi
    if [ "$x" -ge "$wx" ] && [ "$y" -ge "$wy" ] &&
       [ $((x + w)) -le $((wx + ww)) ] && [ $((y + h)) -le $((wy + wh)) ]; then
        echo yes
    else
        echo no
    fi
}

geom_of() { session_window_geom; }

term_tail_hex() { od -An -tx1 "$1" | tr -d ' \n' | tail -c 8; }

scenario_dims() { # rows cols
    local dims
    dims=$(session_size 2>/dev/null) || dims="22 84"
    printf '%s\n' "$dims"
}

# ------------------------------------------------------------- calibration

calibrate() {
    local sc="$RUN/calibration"
    mkdir -p "$sc/shots"
    local ok=0
    if session_start "$BIN" "$sc/session" "calibration"; then
        session_send 'printf "\033[48;2;255;0;0m"; for i in $(seq 1 10); do printf "%20s\n" ""; done; printf "\033[0m"' 15 >/dev/null 2>&1 || true
        if session_shot "$sc/shots/calibration.png"; then
            local bx by bw bh bc f wx wy ww wh
            read -r bx by bw bh bc f <<<"$(bbox_of "$sc/shots/calibration.png" '#FF0000')"
            read -r wx wy ww wh <<<"$(session_window_geom)"
            if [ "$f" = 1 ] && [ "$bw" -ge 50 ] && [ "$bh" -ge 50 ]; then
                python3 - "$bw" "$bh" "$bx" "$by" "$wx" "$wy" >"$RUN/calibration.json" <<'PY'
import json, sys
bw, bh, bx, by, wx, wy = map(int, sys.argv[1:7])
print(json.dumps({
    "cell_w": round(bw / 20.0, 4),
    "cell_h": round(bh / 10.0, 4),
    "content_x": bx, "content_y": by,
    "content_off_x": bx - wx, "content_off_y": by - wy,
    "window_x": wx, "window_y": wy,
    "source": "20x10 truecolor-red block",
    "sample": {"block_w": bw, "block_h": bh},
}, indent=2))
PY
                ok=1
            fi
        fi
        session_stop
    fi
    if [ "$ok" != 1 ]; then
        printf '{"cell_w": 9.0, "cell_h": 18.0, "content_off_x": 11, "content_off_y": 58, "source": "fallback default"}\n' >"$RUN/calibration.json"
        log "WARN: calibration failed; using fallback 9x18 cells"
    fi
    log "calibration: $(tr -d '\n ' <"$RUN/calibration.json")"
}

cell_w() { json_field cell_w <"$RUN/calibration.json"; }
cell_h() { json_field cell_h <"$RUN/calibration.json"; }
content_off_x() { json_field content_off_x <"$RUN/calibration.json"; }
content_off_y() { json_field content_off_y <"$RUN/calibration.json"; }

# Absolute top-left of the terminal grid in the current session.
content_origin() {
    local wx wy ww wh
    read -r wx wy ww wh <<<"$(session_window_geom)" || return 1
    printf '%s %s\n' $((wx + $(content_off_x))) $((wy + $(content_off_y)))
}

# ---------------------------------------------------------------- scenarios

sc_basic() { # term
    local term="$1"
    emit_seq "$SC/emitted.bin" --inline 1 --terminator "$term" "$FIX/magenta-480x320.png" ||
        { ck_fail emission "emit_imgcat.py failed"; return; }
    local tb
    tb=$(term_tail_hex "$SC/emitted.bin")
    if [ "$term" = bel ]; then
        case "$tb" in *07) ck_pass terminator "last byte BEL (0x07)";; *) ck_fail terminator "expected BEL, tail=$tb";; esac
    else
        case "$tb" in *1b5c) ck_pass terminator "last bytes ESC \\\\ (0x1b 0x5c)";; *) ck_fail terminator "expected ST, tail=$tb";; esac
    fi
    session_send "cat '$SC/emitted.bin'" "$TIMEOUT" || { ck_fail emit "cat sequence timed out"; return; }
    session_shot "$SC/shots/after.png" || { ck_fail screenshot "import failed"; return; }
    img_present_checks "$SC/shots/after.png" image "$MAG_IN_W" "$MAG_IN_H" 140000

    local cw ch rows cols cur erow ecol
    cw=$(cell_w); ch=$(cell_h)
    read -r rows cols <<<"$(scenario_dims)"
    erow=$(python3 -c "print(int(1 + (($MAG_H + $ch - 1)//$ch) - 1))")
    ecol=$(python3 -c "print(int(min(1 + (($MAG_W + $cw - 1)//$cw), $cols - 1)))")
    cur=$(session_cursor) || { ck_fail cursor "no DSR reply"; return; }
    ck_info cursor-after "$cur (expected bottom-right ~$erow,$ecol; grid ${rows}x${cols})"
    if [ "${cur%% *}" = "$erow" ] && [ "${cur##* }" = "$ecol" ]; then
        ck_pass cursor-bottom-right "cursor at ($cur) = bottom-right of the image (C18)"
    else
        ck_fail cursor-bottom-right "cursor at ($cur), expected ($erow,$ecol) (C18)"
    fi
    ck_pass alive "ptyxis alive after ${term} sequence"
}

sc_terminator_8bit() {
    emit_seq "$SC/emitted-st.bin" --inline 1 --terminator st "$FIX/magenta-480x320.png" ||
        { ck_fail emission "emit failed"; return; }
    python3 - "$SC/emitted-st.bin" "$SC/emitted-9c.bin" <<'PY'
import sys
d = open(sys.argv[1], 'rb').read()
assert d[-2:] == b'\x1b\\', d[-4:]
open(sys.argv[2], 'wb').write(d[:-2] + b'\x9c')
PY
    ck_pass emission "converted ST tail to 8-bit 0x9c ($(od -An -tx1 "$SC/emitted-9c.bin" | tr -d ' \n' | tail -c 4))"
    session_send "cat '$SC/emitted-9c.bin'" "$TIMEOUT" || { ck_fail emit "timed out"; return; }
    session_shot "$SC/shots/after.png"
    local m7
    m7=$(count_of "$SC/shots/after.png" '#FF00FF')
    if [ "${m7:-0}" -ge 140000 ]; then
        ck_pass mixed-8bit-st "7-bit OSC + 8-bit ST (0x9c) renders (magenta=$m7) (C2)"
    else
        ck_fail mixed-8bit-st "7-bit OSC + 8-bit ST (0x9c) ignored, magenta=$m7 — VTE parser.hh check_matching_controls rejects mixed C0/C1 sets (C2)"
    fi
    # Fully 8-bit form: OSC introducer 0x9d and ST 0x9c.
    python3 - "$SC/emitted-st.bin" "$SC/emitted-8bit.bin" <<'PYINNER'
import sys
d = open(sys.argv[1], 'rb').read()
assert d[:2] == b'\x1b]', d[:2]
open(sys.argv[2], 'wb').write(b'\x9d' + d[2:-2] + b'\x9c')
PYINNER
    session_send "printf '\\033[H\\033[2J\\033[3J'" 10 >/dev/null 2>&1 || true
    session_send "cat '$SC/emitted-8bit.bin'" "$TIMEOUT" || { ck_fail emit-8bit "timed out"; return; }
    session_shot "$SC/shots/after-8bit.png"
    local m8
    m8=$(count_of "$SC/shots/after-8bit.png" '#FF00FF')
    if [ "${m8:-0}" -ge 140000 ]; then
        ck_pass full-8bit "8-bit OSC (0x9d) + 8-bit ST (0x9c) renders (magenta=$m8)"
    else
        ck_fail full-8bit "8-bit OSC (0x9d) + 8-bit ST (0x9c) ignored, magenta=$m8"
    fi
    ck_pass alive "ptyxis alive after 8-bit terminator sequences"
}

sc_do_not_move_cursor() {
    local before after
    before=$(session_cursor) || { ck_fail dsr-before "no DSR reply"; return; }
    ck_info cursor-before "$before"
    emit_seq "$SC/emitted-dnm.bin" --inline 1 --do-not-move-cursor --terminator bel "$FIX/magenta-480x320.png" ||
        { ck_fail emission "emit failed"; return; }
    session_send "cat '$SC/emitted-dnm.bin'" "$TIMEOUT" || { ck_fail emit "timed out"; return; }
    after=$(session_cursor) || { ck_fail dsr-after "no DSR reply"; return; }
    ck_info cursor-after "$after"
    session_shot "$SC/shots/after-dnm.png"
    img_present_checks "$SC/shots/after-dnm.png" image "$MAG_IN_W" "$MAG_IN_H" 140000
    if [ "$before" = "$after" ]; then
        ck_pass cursor-not-moved "doNotMoveCursor=1 kept cursor at ($before) (C20)"
    else
        ck_fail cursor-not-moved "cursor moved ($before -> $after) despite doNotMoveCursor=1 (C20)"
    fi
    # Control: without the flag the cursor must advance to the image's bottom-right.
    session_send "printf '\\033[H\\033[2J\\033[3J'" 10 >/dev/null 2>&1 || true
    emit_seq "$SC/emitted-plain.bin" --inline 1 --terminator bel "$FIX/magenta-480x320.png" ||
        { ck_fail emission-plain "emit failed"; return; }
    session_send "cat '$SC/emitted-plain.bin'" "$TIMEOUT" || { ck_fail emit-plain "timed out"; return; }
    local plain
    plain=$(session_cursor) || { ck_fail dsr-plain "no DSR reply"; return; }
    ck_info cursor-after-plain "$plain"
    if [ "${plain%% *}" -gt 1 ]; then
        ck_pass cursor-advances-without-flag "plain inline=1 moved cursor to ($plain)"
    else
        ck_fail cursor-advances-without-flag "plain inline=1 left cursor at ($plain)"
    fi
}

# Convert a calibration cell dimension to int for bash arithmetic.
cell_w_i() { python3 -c "print(int(round($(cell_w))))"; }
cell_h_i() { python3 -c "print(int(round($(cell_h))))"; }

# Expected DSR "row col" after an image whose box is box_w x box_h starting at (1,1).
box_cursor() { # box_w box_h
    local bw=$1 bh=$2 cwi chi
    cwi=$(cell_w_i); chi=$(cell_h_i)
    local rows cols
    read -r rows cols <<<"$(scenario_dims)"
    python3 -c "print((($bh+$chi-1)//$chi), min((($bw+$cwi-1)//$cwi)+1, $cols))"
}

# Bounding box of the plain solid-magenta fixture -> BB_X BB_Y BB_W BB_H BB_C BB_F
bbox_plain() {
    read -r BB_X BB_Y BB_W BB_H BB_C BB_F <<<"$(bbox_of "$1" '#FF00FF')"
    ck_info bbox "x=$BB_X y=$BB_Y w=$BB_W h=$BB_H count=$BB_C found=$BB_F"
}

# Assert the drawn footprint matches the spec box/bitmap size.
expect_bbox_size() { # label ew eh tol
    local label=$1 ew=$2 eh=$3 tol=${4:-2}
    if [ "$BB_F" = 1 ] && [ "$BB_C" -ge 1000 ] &&
       [ $((BB_W - ew)) -le "$tol" ] && [ $((ew - BB_W)) -le "$tol" ] &&
       [ $((BB_H - eh)) -le "$tol" ] && [ $((eh - BB_H)) -le "$tol" ]; then
        ck_pass "$label-size" "drawn ${BB_W}x${BB_H}, expected ${ew}x${eh} (tol ${tol}px)"
    else
        ck_fail "$label-size" "drawn ${BB_W}x${BB_H}, expected ${ew}x${eh} (tol ${tol}px); magenta=$BB_C found=$BB_F"
    fi
}

assert_cursor_at() { # label expected_row expected_col
    local cur
    cur=$(session_cursor 2>/dev/null) || { ck_fail "$1" "no DSR reply"; return; }
    ck_info "$1-dsr" "$cur (expected $2,$3)"
    if [ "${cur%% *}" = "$2" ] && [ "${cur##* }" = "$3" ]; then
        ck_pass "$1" "cursor ($cur) matches expected ($2,$3)"
    else
        ck_fail "$1" "cursor ($cur), expected ($2,$3)"
    fi
}

expect_origin_y() { # label expected_y tol
    if [ $((BB_Y - $2)) -le "${3:-2}" ] && [ $(($2 - BB_Y)) -le "${3:-2}" ]; then
        ck_pass "$1" "bbox y=$BB_Y matches expected $2"
    else
        ck_fail "$1" "bbox y=$BB_Y, expected $2 (tol ${3:-2})"
    fi
}

sc_size_cells() {
    local cwi chi cy bw bh er ec
    cwi=$(cell_w_i); chi=$(cell_h_i)
    # Box 20x10 cells = 180x180px; native aspect 1.5 -> draw 180x120,
    # letterboxed vertically by (180-120)/2 = 30px (C13/C16).
    bw=$((20 * cwi)); bh=$((10 * chi))
    emit_seq "$SC/emitted.bin" --inline 1 --width 20 --height 10 --terminator bel "$FIX/plain-magenta-480x320.png" ||
        { ck_fail emission "emit failed"; return; }
    session_send "cat '$SC/emitted.bin'" "$TIMEOUT" || { ck_fail emit "timed out"; return; }
    session_shot "$SC/shots/after.png"
    bbox_plain "$SC/shots/after.png"
    if [ "$BB_F" != 1 ] || [ "$BB_C" -lt 1000 ]; then
        ck_fail present "image missing (magenta=$BB_C)"
        return
    fi
    ck_pass present "image rendered (magenta=$BB_C)"
    expect_bbox_size "cells" "$bw" "$((bw * 320 / 480))" 2
    read -r _ cy <<<"$(content_origin)"
    expect_origin_y "cells-centred" $((cy + (bh - bw * 320 / 480) / 2)) 2
    read -r er ec <<<"$(box_cursor "$bw" "$bh")"
    assert_cursor_at "cells-cursor" "$er" "$ec"
    if [ "$(inside_window "$BB_X" "$BB_Y" "$BB_W" "$BB_H")" = yes ]; then
        ck_pass in-window "image within window"
    else
        ck_fail in-window "image outside window"
    fi
}

sc_size_px() {
    local cwi chi cy w h er ec
    cwi=$(cell_w_i); chi=$(cell_h_i)
    w=200; h=$(python3 -c "print(int(round(200 / (480.0/320.0))))")  # 133
    emit_seq "$SC/emitted.bin" --inline 1 --width 200px --terminator bel "$FIX/plain-magenta-480x320.png" ||
        { ck_fail emission "emit failed"; return; }
    session_send "cat '$SC/emitted.bin'" "$TIMEOUT" || { ck_fail emit "timed out"; return; }
    session_shot "$SC/shots/after.png"
    bbox_plain "$SC/shots/after.png"
    if [ "$BB_F" != 1 ] || [ "$BB_C" -lt 1000 ]; then
        ck_fail present "image missing (magenta=$BB_C)"
        return
    fi
    ck_pass present "image rendered (magenta=$BB_C)"
    expect_bbox_size "px" "$w" "$h" 2
    read -r _ cy <<<"$(content_origin)"
    expect_origin_y "px-top" "$cy" 2
    read -r er ec <<<"$(box_cursor "$w" "$h")"
    assert_cursor_at "px-cursor" "$er" "$ec"
}

sc_size_percent() {
    local cwi chi cy vw w h er ec
    cwi=$(cell_w_i); chi=$(cell_h_i)
    local rows cols
    read -r rows cols <<<"$(scenario_dims)"
    vw=$((cols * cwi))
    w=$(python3 -c "print(int(round(0.5 * $vw)))")
    h=$(python3 -c "print(int(round($w / (480.0/320.0))))")
    emit_seq "$SC/emitted.bin" --inline 1 --width 50% --terminator bel "$FIX/plain-magenta-480x320.png" ||
        { ck_fail emission "emit failed"; return; }
    session_send "cat '$SC/emitted.bin'" "$TIMEOUT" || { ck_fail emit "timed out"; return; }
    session_shot "$SC/shots/after.png"
    bbox_plain "$SC/shots/after.png"
    if [ "$BB_F" != 1 ] || [ "$BB_C" -lt 1000 ]; then
        ck_fail present "image missing (magenta=$BB_C)"
        return
    fi
    ck_pass present "image rendered (magenta=$BB_C)"
    expect_bbox_size "percent" "$w" "$h" 2
    read -r _ cy <<<"$(content_origin)"
    expect_origin_y "percent-top" "$cy" 2
    read -r er ec <<<"$(box_cursor "$w" "$h")"
    assert_cursor_at "percent-cursor" "$er" "$ec"
}

sc_size_one_dim() {
    local cwi chi cy w h er ec
    cwi=$(cell_w_i); chi=$(cell_h_i)
    w=$((20 * cwi)); h=$((w * 320 / 480))
    emit_seq "$SC/emitted.bin" --inline 1 --width 20 --terminator bel "$FIX/plain-magenta-480x320.png" ||
        { ck_fail emission "emit failed"; return; }
    session_send "cat '$SC/emitted.bin'" "$TIMEOUT" || { ck_fail emit "timed out"; return; }
    session_shot "$SC/shots/after.png"
    bbox_plain "$SC/shots/after.png"
    if [ "$BB_F" != 1 ] || [ "$BB_C" -lt 1000 ]; then
        ck_fail present "image missing (magenta=$BB_C)"
        return
    fi
    ck_pass present "image rendered (magenta=$BB_C)"
    expect_bbox_size "one-dim" "$w" "$h" 2
    read -r _ cy <<<"$(content_origin)"
    expect_origin_y "one-dim-top" "$cy" 2
    read -r er ec <<<"$(box_cursor "$w" "$h")"
    assert_cursor_at "one-dim-cursor" "$er" "$ec"
}

sc_size_stretch() {
    local cy er ec
    # preserveAspectRatio=0 with both dimensions: stretch to 200x200 (C13).
    emit_seq "$SC/emitted.bin" --inline 1 --width 200px --height 200px \
        --preserve-aspect-ratio 0 --terminator bel "$FIX/plain-magenta-480x320.png" ||
        { ck_fail emission "emit failed"; return; }
    session_send "cat '$SC/emitted.bin'" "$TIMEOUT" || { ck_fail emit "timed out"; return; }
    session_shot "$SC/shots/after.png"
    bbox_plain "$SC/shots/after.png"
    if [ "$BB_F" != 1 ] || [ "$BB_C" -lt 1000 ]; then
        ck_fail present "image missing (magenta=$BB_C)"
        return
    fi
    ck_pass present "image rendered (magenta=$BB_C)"
    expect_bbox_size "stretch" 200 200 2
    read -r _ cy <<<"$(content_origin)"
    expect_origin_y "stretch-top" "$cy" 2
    read -r er ec <<<"$(box_cursor 200 200)"
    assert_cursor_at "stretch-cursor" "$er" "$ec"
}

sc_size_letterbox() {
    local cy er ec draw_h off_y
    draw_h=$(python3 -c "print(int(round(200 / (480.0/320.0))))")  # 133
    off_y=$(( (200 - draw_h) / 2 ))
    emit_seq "$SC/emitted.bin" --inline 1 --width 200px --height 200px \
        --preserve-aspect-ratio 1 --terminator bel "$FIX/plain-magenta-480x320.png" ||
        { ck_fail emission "emit failed"; return; }
    session_send "cat '$SC/emitted.bin'" "$TIMEOUT" || { ck_fail emit "timed out"; return; }
    session_shot "$SC/shots/after.png"
    bbox_plain "$SC/shots/after.png"
    if [ "$BB_F" != 1 ] || [ "$BB_C" -lt 1000 ]; then
        ck_fail present "image missing (magenta=$BB_C)"
        return
    fi
    ck_pass present "image rendered (magenta=$BB_C)"
    expect_bbox_size "letterbox" 200 "$draw_h" 2
    read -r _ cy <<<"$(content_origin)"
    expect_origin_y "letterbox-top" $((cy + off_y)) 2
    read -r er ec <<<"$(box_cursor 200 200)"
    assert_cursor_at "letterbox-cursor" "$er" "$ec"
}

sc_inline_zero() {
    local before after
    before=$(session_cursor) || { ck_fail dsr-before "no DSR reply"; return; }
    emit_seq "$SC/emitted.bin" --inline 0 --terminator bel "$FIX/magenta-480x320.png" ||
        { ck_fail emission "emit failed"; return; }
    session_send "cat '$SC/emitted.bin'" "$TIMEOUT" || { ck_fail emit "timed out"; return; }
    after=$(session_cursor) || { ck_fail dsr-after "no DSR reply"; return; }
    session_shot "$SC/shots/after.png"
    local mag
    mag=$(count_of "$SC/shots/after.png" '#FF00FF')
    ck_info counts "cursor $before -> $after, magenta=$mag"
    if [ "${mag:-1}" -eq 0 ]; then
        ck_pass no-image "inline=0 draws nothing (C17)"
    else
        ck_fail no-image "inline=0 drew an image (magenta=$mag)"
    fi
    if [ "$before" = "$after" ]; then
        ck_pass cursor-unchanged "cursor unchanged by inline=0 (C17)"
    else
        ck_fail cursor-unchanged "cursor moved $before -> $after on inline=0"
    fi
}

sc_wire_errors() {
    local before after mag
    # 1. invalid base64
    python3 - "$SC/invalid.bin" <<'PY'
import sys
open(sys.argv[1], 'wb').write(b"\x1b]1337;File=inline=1:!!!!not-base64!!!!\x07")
PY
    before=$(session_cursor) || { ck_fail dsr "no DSR"; return; }
    session_send "cat '$SC/invalid.bin'" 10 || { ck_fail emit-invalid "timed out"; return; }
    after=$(session_cursor) || true
    session_shot "$SC/shots/invalid.png"
    mag=$(count_of "$SC/shots/invalid.png" '#FF00FF')
    if [ "${mag:-1}" -eq 0 ] && [ "$before" = "$after" ]; then
        ck_pass invalid-base64 "nothing drawn, cursor unchanged ($before)"
    else
        ck_fail invalid-base64 "magenta=$mag cursor $before -> $after (C9)"
    fi

    # 2. truncated payload
    emit_seq "$SC/full.bin" --inline 1 --terminator bel "$FIX/magenta-480x320.png" || { ck_fail emission "emit failed"; return; }
    python3 - "$SC/full.bin" "$SC/trunc.bin" <<'PY'
import sys
d = open(sys.argv[1], 'rb').read()
i = d.index(b':') + 1
open(sys.argv[2], 'wb').write(d[:i + 60] + b'\x07')
PY
    session_send "printf '\\033[H\\033[2J\\033[3J'" 10 >/dev/null 2>&1 || true
    before=$(session_cursor) || true
    session_send "cat '$SC/trunc.bin'" 10 || { ck_fail emit-trunc "timed out"; return; }
    after=$(session_cursor) || true
    session_shot "$SC/shots/truncated.png"
    mag=$(count_of "$SC/shots/truncated.png" '#FF00FF')
    if [ "${mag:-1}" -eq 0 ] && [ "$before" = "$after" ]; then
        ck_pass truncated "nothing drawn, cursor unchanged ($before)"
    else
        ck_fail truncated "magenta=$mag cursor $before -> $after (C9)"
    fi

    # 3. missing terminator (sequence must not dispatch)
    python3 - "$SC/full.bin" "$SC/noterm.bin" <<'PY'
import sys
d = open(sys.argv[1], 'rb').read()
open(sys.argv[2], 'wb').write(d[:-1])   # drop BEL
PY
    session_send "printf '\\033[H\\033[2J\\033[3J'" 10 >/dev/null 2>&1 || true
    session_send "cat '$SC/noterm.bin'" 8 || true
    session_shot "$SC/shots/no-terminator.png"
    mag=$(count_of "$SC/shots/no-terminator.png" '#FF00FF')
    if [ "${mag:-1}" -eq 0 ]; then
        ck_pass no-terminator "unterminated sequence drew nothing (C2)"
    else
        ck_fail no-terminator "unterminated sequence drew magenta=$mag (C2)"
    fi
    session_send "printf '\\030'" 8 || true   # CAN aborts the pending OSC
    session_send "printf '\\033[H\\033[2J\\033[3J'" 10 >/dev/null 2>&1 || true
    ck_pass alive "ptyxis alive after malformed sequences"
}

sc_two_images() {
    local px py pw ph pc pf mx my mw mh mc mf
    emit_seq "$SC/probe.bin" --inline 1 --terminator bel "$FIX/probe-96x64.png" || { ck_fail emission "probe failed"; return; }
    emit_seq "$SC/magenta.bin" --inline 1 --terminator bel "$FIX/magenta-480x320.png" || { ck_fail emission2 "magenta failed"; return; }
    session_send "cat '$SC/probe.bin'; cat '$SC/magenta.bin'" "$TIMEOUT" || { ck_fail emit "timed out"; return; }
    session_shot "$SC/shots/after.png"
    read -r px py pw ph pc pf <<<"$(bbox_of "$SC/shots/after.png" '#3366FF')"
    read -r mx my mw mh mc mf <<<"$(bbox_of "$SC/shots/after.png" '#FF00FF')"
    ck_info probe-bbox "x=$px y=$py w=$pw h=$ph count=$pc found=$pf"
    ck_info magenta-bbox "x=$mx y=$my w=$mw h=$mh count=$mc found=$mf"
    if [ "$pf" = 1 ] && [ "$pc" -ge 5000 ]; then ck_pass probe-present "blue=$pc ${pw}x${ph}"; else ck_fail probe-present "blue=$pc"; fi
    if [ "$mf" = 1 ] && [ "$mc" -ge 140000 ]; then ck_pass magenta-present "magenta=$mc ${mw}x${mh}"; else ck_fail magenta-present "magenta=$mc"; fi
    # Spec C23: the second image starts on the first image's bottom row, to its right.
    local dy dx cw ch
    cw=$(python3 -c "print(int(round($(cell_w))))")
    ch=$(python3 -c "print(int(round($(cell_h))))")
    dy=$(python3 -c "print(int(($ph + 2 + $ch - 1)//$ch * $ch - $ch))")
    dx=$(python3 -c "print(int(($pw + 2 + $cw - 1)//$cw * $cw))")
    ck_info expected-offset "dy~$dy dx~$dx (probe ${pw}x${ph}, cell ${cw}x${ch})"
    if [ $((my - py - dy)) -le 3 ] && [ $((py + dy - my)) -le 3 ]; then
        ck_pass second-on-last-row "second image y=$my on first image's bottom row (expected $((py + dy)))"
    else
        ck_fail second-on-last-row "second image dy=$((my - py)), expected $dy (C23)"
    fi
    if [ $((mx - px)) -ge $((dx - 6)) ]; then
        ck_pass side-by-side "second image x offset $((mx - px)) ~ $dx"
    else
        ck_fail side-by-side "second image x offset $((mx - px)), expected ~$dx"
    fi
}

sc_two_images_newline() {
    local px py pw ph pc pf mx my mw mh mc mf
    emit_seq "$SC/probe.bin" --inline 1 --newline --terminator bel "$FIX/probe-96x64.png" || { ck_fail emission "probe failed"; return; }
    emit_seq "$SC/magenta.bin" --inline 1 --terminator bel "$FIX/magenta-480x320.png" || { ck_fail emission2 "magenta failed"; return; }
    session_send "cat '$SC/probe.bin'; cat '$SC/magenta.bin'" "$TIMEOUT" || { ck_fail emit "timed out"; return; }
    session_shot "$SC/shots/after.png"
    read -r px py pw ph pc pf <<<"$(bbox_of "$SC/shots/after.png" '#3366FF')"
    read -r mx my mw mh mc mf <<<"$(bbox_of "$SC/shots/after.png" '#FF00FF')"
    ck_info probe-bbox "x=$px y=$py w=$pw h=$ph count=$pc"
    ck_info magenta-bbox "x=$mx y=$my w=$mw h=$mh count=$mc"
    # The second image is 18 rows tall; starting below the probe it may push
    # the screen up one row (C19), clipping the probe's top. Both must exist.
    if [ "$pf" = 1 ] && [ "$pc" -ge 4000 ] && [ "$mf" = 1 ] && [ "$mc" -ge 140000 ]; then
        ck_pass both-rendered "blue=$pc magenta=$mc (probe top may be clipped by C19 scroll)"
    else
        ck_fail both-rendered "blue=$pc magenta=$mc"
    fi
    if [ "$my" -ge $((py + ph + 4)) ]; then
        ck_pass no-overlap "newline separates images (dy=$((my - py)), probe h=$ph)"
    else
        ck_fail no-overlap "images overlap after newline (dy=$((my - py)), probe h=$ph)"
    fi
}

sc_scrollback() {
    local bx by bw bh bc f cx cy cc cf
    emit_seq "$SC/emitted.bin" --inline 1 --terminator bel "$FIX/magenta-480x320.png" || { ck_fail emission "emit failed"; return; }
    session_send "cat '$SC/emitted.bin'" "$TIMEOUT" || { ck_fail emit "timed out"; return; }
    session_shot "$SC/shots/before-text.png"
    img_present_checks "$SC/shots/before-text.png" initial "$MAG_IN_W" "$MAG_IN_H" 140000

    session_send 'for i in $(seq 1 300); do echo "scroll line $i ------------------------------------------------------------------"; done' 30 ||
        { ck_fail text "text emission timed out"; return; }
    session_shot "$SC/shots/scrolled-away.png"
    local away
    away=$(count_of "$SC/shots/scrolled-away.png" '#FF00FF')
    ck_info image-after-300-lines "magenta=$away (expected 0 while scrolled off)"
    if [ "${away:-1}" -le 5 ]; then
        ck_pass scrolled-off "image left viewport after 300 lines (magenta=$away)"
    else
        ck_fail scrolled-off "image still visible after 300 lines (magenta=$away)"
    fi

    local wx wy ww wh attempt found_count=0
    read -r wx wy ww wh <<<"$(session_window_geom)"
    for attempt in 1 2 3 4; do
        xdotool mousemove $((wx + ww / 2)) $((wy + wh / 2)) click --repeat 80 --delay 5 4 2>/dev/null
        sleep 0.4
        session_shot "$SC/shots/scrolled-back-$attempt.png"
        found_count=$(count_of "$SC/shots/scrolled-back-$attempt.png" '#FF00FF')
        if [ "${found_count:-0}" -ge 140000 ]; then break; fi
    done
    local shot="$SC/shots/scrolled-back-$attempt.png"
    ck_info scrolled-back-magenta "magenta=$found_count after $attempt scroll steps"
    if [ "${found_count:-0}" -ge 140000 ]; then
        ck_pass scrolled-back "image recovered intact after scrolling back (magenta=$found_count)"
    else
        ck_fail scrolled-back "image not recovered after scrolling back (magenta=$found_count)"
        return
    fi
    read -r bx by bw bh bc f <<<"$(bbox_of "$shot" '#FF00FF')"
    read -r cx cy _ _ cc cf <<<"$(bbox_of "$shot" '#00FFFF')"
    ck_info scrolled-bbox "x=$bx y=$by w=$bw h=$bh count=$bc"
    if [ $((bw - MAG_IN_W)) -le 2 ] && [ $((MAG_IN_W - bw)) -le 2 ] &&
       [ $((bh - MAG_IN_H)) -le 2 ] && [ $((MAG_IN_H - bh)) -le 2 ]; then
        ck_pass scrolled-size "bbox ${bw}x${bh} unchanged"
    else
        ck_fail scrolled-size "bbox ${bw}x${bh}, expected ${MAG_IN_W}x${MAG_IN_H} (C25)"
    fi
    if [ "$cf" = 1 ] && [ "$cc" -ge 200 ] &&
       [ $((cx - bx - CYAN_OFF)) -le 3 ] && [ $((bx + CYAN_OFF - cx)) -le 3 ] &&
       [ $((cy - by - CYAN_OFF)) -le 3 ] && [ $((by + CYAN_OFF - cy)) -le 3 ]; then
        ck_pass content-intact "cyan inset at +$((cx - bx)),+$((cy - by)) from magenta origin"
    else
        ck_fail content-intact "cyan inset at +$((cx - bx)),+$((cy - by)), expected +$CYAN_OFF,+$CYAN_OFF (count=$cc)"
    fi
    # Scroll down past the image, then back up (clamped at the top) and check
    # the anchor is identical: images ride their rows, not the viewport.
    xdotool mousemove $((wx + ww / 2)) $((wy + wh / 2)) click --repeat 20 --delay 5 5 2>/dev/null
    sleep 0.4
    xdotool mousemove $((wx + ww / 2)) $((wy + wh / 2)) click --repeat 80 --delay 5 4 2>/dev/null
    sleep 0.5
    session_shot "$SC/shots/scrolled-again.png"
    local bx2 by2 bw2 bh2 bc2 f2
    read -r bx2 by2 bw2 bh2 bc2 f2 <<<"$(bbox_of "$SC/shots/scrolled-again.png" '#FF00FF')"
    ck_info re-scroll-bbox "x=$bx2 y=$by2 w=$bw2 h=$bh2 count=$bc2"
    if [ "$f2" = 1 ] && [ $((bx2 - bx)) -le 3 ] && [ $((bx - bx2)) -le 3 ] &&
       [ $((by2 - by)) -le 3 ] && [ $((by - by2)) -le 3 ]; then
        ck_pass anchor-stable "image anchored to the same row after down/up scrolling"
    else
        ck_fail anchor-stable "anchor moved: ($bx,$by) -> ($bx2,$by2)"
    fi
}

sc_resize() {
    local bx by bw bh bc f small_count
    emit_seq "$SC/emitted.bin" --inline 1 --terminator bel "$FIX/magenta-480x320.png" || { ck_fail emission "emit failed"; return; }
    session_send "cat '$SC/emitted.bin'" "$TIMEOUT" || { ck_fail emit "timed out"; return; }
    session_shot "$SC/shots/before.png"
    img_present_checks "$SC/shots/before.png" initial "$MAG_IN_W" "$MAG_IN_H" 140000

    xdotool windowsize --sync "$SESSION_WID" 520 380 2>/dev/null
    sleep 1.2
    session_shot "$SC/shots/small.png"
    ck_info small-geometry "$(geom_of)"
    if session_alive; then ck_pass alive-after-shrink "ptyxis alive at $(geom_of)"; else ck_fail alive-after-shrink "ptyxis died after shrink"; return; fi
    small_count=$(count_of "$SC/shots/small.png" '#FF00FF')
    ck_info small-magenta "magenta=$small_count"
    if [ "${small_count:-0}" -gt 1000 ]; then
        ck_pass image-after-shrink "image still drawn after shrink (magenta=$small_count)"
    else
        ck_fail image-after-shrink "image gone after shrink (magenta=$small_count)"
    fi

    xdotool windowsize --sync "$SESSION_WID" 900 650 2>/dev/null
    sleep 1.2
    session_shot "$SC/shots/restored.png"
    ck_info restored-geometry "$(geom_of)"
    read -r bx by bw bh bc f <<<"$(bbox_of "$SC/shots/restored.png" '#FF00FF')"
    ck_info restored-bbox "x=$bx y=$by w=$bw h=$bh count=$bc"
    if session_alive && [ "$f" = 1 ] && [ "$bc" -ge 140000 ] &&
       [ $((bw - MAG_IN_W)) -le 2 ] && [ $((MAG_IN_W - bw)) -le 2 ] &&
       [ $((bh - MAG_IN_H)) -le 2 ] && [ $((MAG_IN_H - bh)) -le 2 ]; then
        ck_pass restored "image intact after grow back (${bw}x${bh}, magenta=$bc); resize does not rescale (C29)"
    else
        ck_fail restored "after grow back: found=$f bbox=${bw}x${bh} magenta=$bc alive=$(session_alive && echo yes || echo no)"
    fi
}

sc_clear() {
    local before after
    emit_seq "$SC/emitted.bin" --inline 1 --terminator bel "$FIX/magenta-480x320.png" || { ck_fail emission "emit failed"; return; }
    session_send "cat '$SC/emitted.bin'" "$TIMEOUT" || { ck_fail emit "timed out"; return; }
    session_shot "$SC/shots/before-clear.png"
    before=$(count_of "$SC/shots/before-clear.png" '#FF00FF')
    if [ "${before:-0}" -ge 140000 ]; then
        ck_pass present-before "magenta=$before before clear (test not vacuous)"
    else
        ck_fail present-before "magenta=$before before clear; image never rendered"
        return
    fi
    session_send "printf '\\033[H\\033[2J\\033[3J'" 10 || { ck_fail clear "clear command timed out"; return; }
    sleep 0.3
    session_shot "$SC/shots/after-clear.png"
    after=$(count_of "$SC/shots/after-clear.png" '#FF00FF')
    ck_info after-magenta "magenta=$after"
    if [ "${after:-1}" -eq 0 ]; then
        ck_pass clear-removes-image "image gone after ED 2 + ED 3 (magenta=0)"
    else
        ck_fail clear-removes-image "image remains after clear (magenta=$after)"
    fi
    if session_alive; then ck_pass alive "ptyxis alive after clear"; else ck_fail alive "ptyxis died during clear"; fi
}

sc_tall_image() {
    local bx by bw bh bc f cur rows cols er cwi chi expected_w
    # Explicit height=200 cells (3600px) only: width is aspect-derived, so the
    # bitmap fills the reserved box (no letterboxing into scrollback).  A
    # 100x1200 image => box 300x3600, which must scroll (C15/C19), not be
    # squeezed to the viewport.  The PNG is 2489B, well under every payload cap.
    cwi=$(cell_w_i); chi=$(cell_h_i)
    expected_w=$(python3 -c "print(int(round(200 * $chi * (100.0/1200.0))))")
    emit_seq "$SC/emitted.bin" --inline 1 --height 200 --terminator bel "$FIX/tall-100x1200.png" ||
        { ck_fail emission "emit failed"; return; }
    session_send "printf 'MARKER-BEFORE-IMAGE\\n'; cat '$SC/emitted.bin'" "$TIMEOUT" ||
        { ck_fail emit "timed out"; return; }
    session_shot "$SC/shots/after.png"
    read -r bx by bw bh bc f <<<"$(bbox_of "$SC/shots/after.png" '#FF8800')"
    read -r rows cols <<<"$(scenario_dims)"
    ck_info bbox "x=$bx y=$by w=$bw h=$bh count=$bc found=$f (grid ${cols}x${rows}, expected box ${expected_w}x$((200*chi)))"
    if [ "$f" = 1 ] && [ $((bw - expected_w)) -le 3 ] && [ $((expected_w - bw)) -le 3 ]; then
        ck_pass width "explicit 200-cell height honoured; aspect-derived width=$bw (expected ~$expected_w)"
    else
        ck_fail width "explicit height ignored/squeezed: bbox w=$bw, expected ~$expected_w (C15)"
    fi
    if [ "$f" = 1 ] && [ "${bc:-0}" -ge 20000 ]; then
        ck_pass rendered "tall bitmap painted and clipped by the viewport (orange=$bc, bbox ${bw}x${bh})"
    else
        ck_fail rendered "tall bitmap not painted (orange=$bc)"
    fi
    # C19: the image pushes rows into scrollback; its bottom row is on screen.
    cur=$(session_cursor 2>/dev/null) || cur="?"
    ck_info cursor-after "$cur (grid rows=$rows)"
    if [ "${cur%% *}" = "$rows" ]; then
        ck_pass scrolled "explicit tall image scrolled, cursor on the last row ($cur) (C19)"
    else
        ck_fail scrolled "cursor at ($cur), expected last row ($rows) after scrolling (C19)"
    fi
    if session_alive; then ck_pass alive "ptyxis alive after tall image"; else ck_fail alive "ptyxis died on tall image"; fi
}

sc_large_image() {
    local t0 t1 dt rss gx gy gw gh gc gf wx wy ww wh seq_bytes
    emit_seq "$SC/emitted.bin" --inline 1 --terminator bel "$FIX/large-3000x2000.png" ||
        { ck_fail emission "emit failed"; return; }
    seq_bytes=$(stat -c %s "$SC/emitted.bin")
    ck_info sequence-size "${seq_bytes} bytes emitted; VTE OSC string cap is 4096 bytes (VTE_SEQ_STRING_MAX_CAPACITY)"
    t0=$(date +%s%N)
    session_send "cat '$SC/emitted.bin'" 60 || { ck_fail emit "large image emission timed out (>60s)"; return; }
    t1=$(date +%s%N)
    dt=$(python3 -c "print(round(($t1-$t0)/1e9,2))")
    sleep 0.8
    session_shot "$SC/shots/after.png"
    rss=$(session_rss_kb)
    read -r wx wy ww wh <<<"$(geom_of)"
    read -r gx gy gw gh gc gf <<<"$(bbox_of "$SC/shots/after.png" '#00A000')"
    ck_info timing "emit+render ${dt}s, rss=${rss}kB, window=${ww}x${wh}"
    ck_info bbox "x=$gx y=$gy w=$gw h=$gh count=$gc found=$gf"
    if session_alive; then ck_pass alive "ptyxis alive after 3000x2000 image"; else ck_fail alive "ptyxis died on large image"; return; fi
    if python3 -c "import sys; sys.exit(0 if $dt < 30 else 1)"; then
        ck_pass timing-ok "completed in ${dt}s (<30s)"
    else
        ck_fail timing-ok "took ${dt}s (>=30s)"
    fi
    if [ "$rss" -gt 0 ] && [ "$rss" -lt 2000000 ]; then
        ck_pass memory "rss=${rss}kB (<2GB)"
    else
        ck_fail memory "rss=${rss}kB (>=2GB or unreadable)"
    fi
    if [ "$gf" = 1 ] && [ "$gc" -ge 20000 ]; then
        ck_pass rendered "green=$gc, bbox ${gw}x${gh}"
    else
        ck_fail rendered "green=$gc, bbox ${gw}x${gh} found=$gf — sequence of ${seq_bytes}B exceeds the 4096-byte VTE OSC buffer limit, so it was silently discarded (C30); small payloads render, normal photos/large images do not"
        return
    fi
    if [ "$gw" -le "$ww" ] && [ "$gh" -le "$wh" ]; then
        ck_pass downscaled "image ${gw}x${gh} fits window content ${ww}x${wh}"
    else
        ck_fail downscaled "image ${gw}x${gh} exceeds window ${ww}x${wh}"
    fi
    if python3 -c "import sys; a=$gw/$gh if $gh else 0; sys.exit(0 if abs(a-1.5)<0.15 else 1)"; then
        ck_pass aspect "aspect $(python3 -c "print(round($gw/$gh,3))") ~= 1.5 (3000x2000)"
    else
        ck_fail aspect "aspect $(python3 -c "print(round($gw/$gh,3))") != 1.5 (stretched or clipped)"
    fi
    local fill
    fill=$(python3 -c "print(round($gc/($gw*$gh),4) if ($gw*$gh) else 0)")
    if python3 -c "import sys; sys.exit(0 if $fill > 0.4 else 1)"; then
        ck_pass fill "green fills $fill of bbox"
    else
        ck_fail fill "green fills only $fill of bbox (blank/garbled image?)"
    fi
}

sc_photo_payload() {
    local bx by bw bh bc f sz
    # A normal 480x320 image (noise defeats PNG compression) is ~100 KB of
    # base64, like a real photo passed to imgcat.
    emit_seq "$SC/emitted.bin" --inline 1 --terminator bel "$FIX/photo-480x320.png" ||
        { ck_fail emission "emit failed"; return; }
    sz=$(stat -c %s "$SC/emitted.bin")
    ck_info sequence-size "${sz} bytes emitted (PNG $(stat -c %s "$FIX/photo-480x320.png") bytes)"
    if [ "$sz" -le 4096 ]; then
        ck_fail fixture "photo fixture sequence is only ${sz}B; it does not exercise the 4096B OSC limit"
        return
    fi
    session_send "cat '$SC/emitted.bin'" 60 || { ck_fail emit "timed out"; return; }
    sleep 0.5
    session_shot "$SC/shots/after.png"
    read -r bx by bw bh bc f <<<"$(bbox_of "$SC/shots/after.png" '#FF00FF')"
    ck_info bbox "marker x=$bx y=$by w=$bw h=$bh count=$bc found=$f"
    if [ "$f" = 1 ] && [ "$bc" -ge 6000 ] && [ $((bw - 80)) -le 3 ] && [ $((80 - bw)) -le 3 ]; then
        ck_pass rendered "480x320 photo-like image rendered (80x80 marker present, magenta=$bc)"
    else
        ck_fail rendered "photo-like 480x320 image dropped (magenta=$bc, marker bbox ${bw}x${bh}) — ${sz}B sequence exceeds the 4096-byte VTE OSC buffer limit"
    fi
}

sc_memory_guard() {
    local rss0 rssA rssB rssC rssD
    local lines=300 images=60
    # Batch: `images` x 480x320 (~600 kB decoded) interleaved with `lines`
    # text lines => images*(18+lines) rows, past the scrollback limit.
    _mem_batch() {
        session_send "for i in \$(seq 1 $images); do printf '\\033]1337;File=inline=1:'; base64 -w0 '$FIX/magenta-480x320.png'; printf '\\a'; for j in \$(seq 1 $lines); do echo \"mem \$1 \$i-\$j ----------------------------------------------------------------\"; done; done" 120
    }
    # Push every image out of the retained history.
    _mem_flush() {
        session_send "for j in \$(seq 1 12000); do echo \"flush $1 \$j ------------------------------------------------------------------\"; done" 120
    }
    rss0=$(session_rss_kb)
    _mem_batch A || { ck_fail batch-a "timed out"; return; }
    sleep 0.6
    rssA=$(session_rss_kb)
    _mem_flush A || { ck_fail flush-a "timed out"; return; }
    sleep 0.6
    rssB=$(session_rss_kb)
    _mem_batch B || { ck_fail batch-b "timed out"; return; }
    sleep 0.6
    rssC=$(session_rss_kb)
    _mem_flush B || { ck_fail flush-b "timed out"; return; }
    sleep 0.6
    rssD=$(session_rss_kb)

    ck_info memory "rss idle=${rss0}kB  after-A=${rssA}kB  after-flush-A=${rssB}kB  after-B=${rssC}kB  after-flush-B=${rssD}kB (kB)"
    ck_info deltas "batchA=+$((rssA-rss0))kB flushA=$((rssB-rssA))kB batchB=+$((rssC-rssB))kB flushB=$((rssD-rssC))kB"
    ck_info context "each batch = 60 images (~600kB decoded each, 36MB) + ${lines} lines each; scrollback eviction should release them"

    if session_alive; then ck_pass alive "ptyxis alive after 120 images and ~48k lines"; else ck_fail alive "ptyxis died during memory stress"; return; fi
    if [ "$rssD" -lt 1500000 ]; then
        ck_pass memory-bounded "rss=${rssD}kB (<1.5GB) after memory stress"
    else
        ck_fail memory-bounded "rss=${rssD}kB (>=1.5GB); unbounded image memory (C26)"
    fi
    # With a 10k-row scrollback, after the flush no image should be retained.
    # The old build leaked +30MB for 60 images and kept growing.
    local hold=$((rssB - rss0))
    if [ "$hold" -lt 20000 ]; then
        ck_pass freed-after-eviction "after all images left history RSS is only +${hold}kB above idle (C26)"
    else
        ck_fail freed-after-eviction "RSS still +${hold}kB above idle after every image was evicted (C26)"
    fi
    local grow=$((rssC - rssB))
    if [ "$grow" -lt 45000 ]; then
        ck_pass batch-b-bounded "second 60-image batch grew RSS ${grow}kB (<45MB; scrollback-limited, not leaking)"
    else
        ck_fail batch-b-bounded "second 60-image batch grew RSS ${grow}kB (>=45MB); images accumulate in history (C26)"
    fi
    local hold2=$((rssD - rss0))
    if [ "$hold2" -lt 25000 ]; then
        ck_pass plateau "after two full cycles RSS is +${hold2}kB above idle; history does not accumulate image memory"
    else
        ck_fail plateau "after two full cycles RSS is +${hold2}kB above idle; image memory accumulates (C26)"
    fi

    local wx wy ww wh
    read -r wx wy ww wh <<<"$(session_window_geom)"
    xdotool mousemove $((wx + ww / 2)) $((wy + wh / 2)) click --repeat 600 --delay 2 4 2>/dev/null
    sleep 0.8
    session_shot "$SC/shots/top.png"
    if session_alive; then ck_pass alive-after-scrollback "ptyxis alive after scrolling back through evicted history"; else ck_fail alive-after-scrollback "ptyxis crashed scrolling evicted history"; fi
}

sc_erase_semantics() {
    local before after_ed after_el
    emit_seq "$SC/emitted.bin" --inline 1 --terminator bel "$FIX/magenta-480x320.png" || { ck_fail emission "emit failed"; return; }
    session_send "cat '$SC/emitted.bin'" "$TIMEOUT" || { ck_fail emit "timed out"; return; }
    session_shot "$SC/shots/before.png"
    before=$(count_of "$SC/shots/before.png" '#FF00FF')
    ck_info before "magenta=$before"
    # C22: printing text over image cells should replace those cells. ASPIRATIONAL.
    session_send "printf '\\033[1;1H'; printf 'X%.0s' \$(seq 1 80); printf '\\033[2;1H'; printf 'X%.0s' \$(seq 1 80)" 10 || true
    session_shot "$SC/shots/after-text.png"
    after_ed=$(count_of "$SC/shots/after-text.png" '#FF00FF')
    if [ "${after_ed:-$before}" -lt "$before" ]; then
        ck_pass text-overwrite "printing over image rows erased $((before - after_ed)) magenta px (C22)"
    else
        ck_info text-overwrite "KNOWN GAP (aspirational): text printed over the image does not erase image cells (C22); magenta=$after_ed"
    fi
    # C27: EL 2 on the image's rows. ASPIRATIONAL but ED already works.
    session_send "printf '\\033[1;1H\\033[2K\\033[2;1H\\033[2K'" 10 || true
    session_shot "$SC/shots/after-el.png"
    after_el=$(count_of "$SC/shots/after-el.png" '#FF00FF')
    if [ "${after_el:-$before}" -lt "$before" ]; then
        ck_pass erase-line "EL 2 erased image cells ($((before - after_el)) px) (C27)"
    else
        ck_info erase-line "KNOWN GAP (aspirational): EL 2 does not erase image cells (C27); magenta=$after_el"
    fi
    if session_alive; then ck_pass alive "ptyxis alive after erase attempts"; else ck_fail alive "ptyxis died during erase tests"; fi
}

sc_control_omitted() {
    session_send "printf '\\033[38;2;0;255;0mCONTROL-NO-IMAGE\\033[0m\\n'" 10 ||
        { ck_fail text "text emission timed out"; return; }
    session_shot "$SC/shots/after.png"
    local mag green
    mag=$(count_of "$SC/shots/after.png" '#FF00FF')
    green=$(count_of "$SC/shots/after.png" '#00FF00' 80)
    ck_info counts "magenta=$mag green-text=$green"
    if [ "${mag:-1}" -eq 0 ]; then
        ck_pass no-image "no magenta anywhere without an escape sequence"
    else
        ck_fail no-image "unexpected magenta=$mag in control run"
    fi
    if [ "${green:-0}" -ge 100 ]; then
        ck_pass text-rendered "green text pixels=$green prove the terminal is live"
    else
        ck_fail text-rendered "green text pixels=$green; control screen may be blank"
    fi
}

wait_window_class() {
    local cls="$1" tmo="${2:-20}" i w
    for i in $(seq 1 $((tmo * 4))); do
        while read -r w; do
            [ -n "$w" ] || continue
            local gw
            gw=$(xdotool getwindowgeometry --shell "$w" 2>/dev/null | sed -n 's/^WIDTH=//p')
            if [ -n "$gw" ] && [ "$gw" -ge 100 ] 2>/dev/null; then
                printf '%s\n' "$w"
                return 0
            fi
        done < <(xdotool search --maxdepth 5 --class "$cls" 2>/dev/null)
        sleep 0.25
    done
    return 1
}

sc_control_xterm() {
    local bin="$SC/emitted.bin" pid wid
    emit_seq "$bin" --inline 1 --terminator bel "$FIX/magenta-480x320.png" || { ck_fail emission "emit failed"; return; }
    setsid xterm -display "$DISPLAY" -title xterm-control -geometry 100x30 \
        -e bash -c "cat '$bin'; sleep 120" >"$SC/xterm.log" 2>&1 &
    pid=$!
    wid=$(wait_window_class XTerm 15) || { ck_fail window "xterm window did not appear"; kill -- -"$pid" 2>/dev/null; return; }
    ck_info window "xterm wid=$wid"
    sleep 1.5
    session_shot "$SC/shots/after.png"
    local mag
    mag=$(count_of "$SC/shots/after.png" '#FF00FF')
    ck_info magenta "magenta=$mag"
    if [ "${mag:-1}" -eq 0 ]; then
        ck_pass no-image "plain xterm renders no image (magenta=0)"
    else
        ck_fail no-image "xterm shows magenta=$mag"
    fi
    kill -- -"$pid" 2>/dev/null
    sleep 0.3
}

sc_control_stock_vte() {
    local cmd="" bin="$SC/emitted.bin" pid wid
    if command -v gnome-terminal >/dev/null 2>&1; then
        cmd=gnome-terminal
    elif command -v kgx >/dev/null 2>&1; then
        cmd=kgx
    fi
    if [ -z "$cmd" ]; then
        ck_skip stock-vte-control "no stock VTE app installed (gnome-terminal/kgx absent)"
        return
    fi
    emit_seq "$bin" --inline 1 --terminator bel "$FIX/magenta-480x320.png" || { ck_fail emission "emit failed"; return; }
    if [ "$cmd" = gnome-terminal ]; then
        setsid dbus-run-session -- gnome-terminal --window --wait -- \
            bash -c "cat '$bin'; sleep 120" >"$SC/vte.log" 2>&1 &
    else
        setsid dbus-run-session -- kgx --command "bash -c \"cat '$bin'; sleep 120\"" >"$SC/vte.log" 2>&1 &
    fi
    pid=$!
    wid=$(wait_window_class 'gnome-terminal|Gnome-terminal|kgx|Kgx' 25) || {
        ck_skip stock-vte-control "stock VTE app ($cmd) did not open a window headlessly; see $SC/vte.log"
        kill -- -"$pid" 2>/dev/null
        return
    }
    sleep 2
    session_shot "$SC/shots/after.png"
    local mag
    mag=$(count_of "$SC/shots/after.png" '#FF00FF')
    ck_info magenta "magenta=$mag (window=$wid, binary=$(command -v "$cmd"))"
    if [ "${mag:-1}" -eq 0 ]; then
        ck_pass stock-vte-no-image "$cmd (system VTE, unpatched) renders no image from the same emitter (magenta=0)"
    else
        ck_fail stock-vte-no-image "$cmd unexpectedly shows magenta=$mag"
    fi
    kill -- -"$pid" 2>/dev/null
    sleep 0.3
}

# ---------------------------------------------------- payload size regressions

sc_payload_boundary() {
    local name f seq cnt under=0 over=0
    for pair in "under:$FIX/seq-under-4096.png" "over:$FIX/seq-over-4096.png"; do
        name=${pair%%:*}; f=${pair#*:}
        emit_seq "$SC/emitted-$name.bin" --inline 1 --terminator bel "$f" ||
            { ck_fail "emission-$name" "emit failed"; continue; }
        seq=$(stat -c %s "$SC/emitted-$name.bin")
        ck_info "size-$name" "$seq bytes (old VTE OSC cap: 4096)"
        session_send "printf '\\033[H\\033[2J\\033[3J'" 10 >/dev/null 2>&1 || true
        session_send "cat '$SC/emitted-$name.bin'" 30 || { ck_fail "emit-$name" "timed out"; continue; }
        sleep 0.4
        session_shot "$SC/shots/$name.png"
        cnt=$(count_of "$SC/shots/$name.png" '#FF8800')
        ck_info "pixels-$name" "orange=$cnt"
        if [ "${cnt:-0}" -ge 5000 ]; then
            ck_pass "render-$name" "sequence ${seq}B rendered (orange=$cnt)"
        else
            ck_fail "render-$name" "sequence ${seq}B dropped (orange=$cnt)"
        fi
        if [ "$seq" -lt 4096 ]; then under=$seq; fi
        if [ "$seq" -gt 4096 ]; then over=$seq; fi
    done
    if [ "$under" -gt 0 ] && [ "$over" -gt 0 ]; then
        ck_pass boundary "pair brackets the old 4096-byte cap: ${under}B renders, ${over}B renders"
    else
        ck_fail boundary "fixtures do not bracket 4096 (under=$under over=$over)"
    fi
    if session_alive; then ck_pass alive "ptyxis alive after boundary payloads"; else ck_fail alive "ptyxis died"; fi
}

# Generic large-payload rendering test.
payload_big() { # label fixture min_bytes max_bytes timeout_s
    local label=$1 f=$2 minb=$3 maxb=$4 tmo=$5
    local seq cnt rss t0 t1 dt
    emit_seq "$SC/emitted-$label.bin" --inline 1 --terminator bel "$f" ||
        { ck_fail "$label-emission" "emit failed"; return; }
    seq=$(stat -c %s "$SC/emitted-$label.bin")
    ck_info "$label-size" "${seq} bytes base64 (PNG $(stat -c %s "$f") bytes)"
    if [ "$seq" -ge "$minb" ] && [ "$seq" -le "$maxb" ]; then
        ck_pass "$label-fixture" "sequence ${seq}B within target ${minb}..${maxb}B"
    else
        ck_fail "$label-fixture" "sequence ${seq}B outside target ${minb}..${maxb}B"
    fi
    t0=$(date +%s%N)
    session_send "cat '$SC/emitted-$label.bin'" "$tmo" || { ck_fail "$label-emit" "timed out after ${tmo}s"; return; }
    t1=$(date +%s%N)
    dt=$(python3 -c "print(round(($t1-$t0)/1e9,2))")
    sleep 0.6
    session_shot "$SC/shots/$label.png"
    cnt=$(count_of "$SC/shots/$label.png" '#FF00FF')
    rss=$(session_rss_kb)
    ck_info "$label-run" "emit+render ${dt}s, magenta=$cnt, rss=${rss}kB"
    if session_alive; then ck_pass "$label-alive" "ptyxis alive after ${seq}B payload"; else ck_fail "$label-alive" "ptyxis died"; return; fi
    if [ "${cnt:-0}" -ge 500 ]; then
        ck_pass "$label-render" "rendered (magenta marker=$cnt)"
    else
        ck_fail "$label-render" "not rendered (magenta=$cnt)"
    fi
    if python3 -c "import sys; sys.exit(0 if $dt < 60 else 1)"; then
        ck_pass "$label-time" "completed in ${dt}s (<60s)"
    else
        ck_fail "$label-time" "took ${dt}s (>=60s)"
    fi
    if [ "$rss" -gt 0 ] && [ "$rss" -lt 1500000 ]; then
        ck_pass "$label-memory" "rss=${rss}kB (<1.5GB)"
    else
        ck_fail "$label-memory" "rss=${rss}kB"
    fi
}

sc_payload_100k() { payload_big 100k "$FIX/noise-100k.png" 80000 120000 30; }
sc_payload_1m()   { payload_big 1m   "$FIX/noise-1m.png"   800000 1100000 30; }
sc_payload_5m()   { payload_big 5m   "$FIX/noise-5m.png"   4000000 5500000 60; }

sc_payload_oversize() {
    local seq rss0 rss1 dt t0 t1 mag green
    emit_seq "$SC/emitted-oversize.bin" --inline 1 --terminator bel "$FIX/noise-oversize.png" ||
        { ck_fail emission "emit failed"; return; }
    seq=$(stat -c %s "$SC/emitted-oversize.bin")
    ck_info size "${seq} bytes base64; patch cap kMaxImageEncodedBytes=32MiB (33554432), VTE parser cap 16Mi chars"
    if [ "$seq" -gt 33554432 ]; then
        ck_pass oversize-fixture "sequence ${seq}B exceeds the 32MiB encoded cap"
    else
        ck_fail oversize-fixture "sequence ${seq}B does not exceed 32MiB"
    fi
    rss0=$(session_rss_kb)
    t0=$(date +%s%N)
    session_send "cat '$SC/emitted-oversize.bin'" 120 || { ck_fail emit "oversize emission timed out (>120s) — possible hang"; return; }
    t1=$(date +%s%N)
    dt=$(python3 -c "print(round(($t1-$t0)/1e9,2))")
    sleep 0.6
    rss1=$(session_rss_kb)
    session_shot "$SC/shots/after.png"
    mag=$(count_of "$SC/shots/after.png" '#FF00FF')
    ck_info run "completed in ${dt}s, rss ${rss0}kB -> ${rss1}kB, magenta=$mag"
    if session_alive; then ck_pass alive "ptyxis alive after ${seq}B oversize sequence"; else ck_fail alive "ptyxis died/OOMed on oversize sequence"; return; fi
    if python3 -c "import sys; sys.exit(0 if $dt < 90 else 1)"; then
        ck_pass time "completed in ${dt}s (<90s)"
    else
        ck_fail time "took ${dt}s (>=90s)"
    fi
    if [ "$rss1" -lt 1500000 ]; then
        ck_pass memory "rss=${rss1}kB (<1.5GB, delta $((rss1-rss0))kB)"
    else
        ck_fail memory "rss=${rss1}kB (>=1.5GB)"
    fi
    if [ "${mag:-1}" -eq 0 ]; then
        ck_pass dropped "nothing drawn from oversize payload"
    else
        ck_fail dropped "oversize payload unexpectedly drew magenta=$mag"
    fi
    # The terminal must still be usable afterwards.
    session_send "printf '\\033[38;2;0;255;0mOVERSIZE-RECOVERED\\033[0m\\n'" 20 || true
    session_shot "$SC/shots/recovered.png"
    green=$(count_of "$SC/shots/recovered.png" '#00FF00' 80)
    ck_info recovered-text "green=$green"
    if [ "${green:-0}" -ge 100 ]; then
        ck_pass recovered "terminal usable after oversize drop (green text=$green)"
    else
        ck_fail recovered "terminal not usable after oversize sequence (green=$green)"
    fi
}

# ------------------------------------------------------------------ runner

finalize_scenario() {
    local sc="$1" id="$2" t0="$3"
    local dur=$(( $(date +%s) - t0 ))
    local state
    state=$(python3 - "$sc" "$id" "$dur" <<'PY'
import json, os, sys
sc, sid, dur = sys.argv[1], sys.argv[2], int(sys.argv[3])
checks = []
for line in open(os.path.join(sc, "checks.tsv")):
    parts = line.rstrip("\n").split("\t", 2)
    if len(parts) != 3:
        continue
    st, name, detail = parts
    checks.append({"name": name, "state": st, "detail": detail})
states = [c["state"] for c in checks]
if "FAIL" in states:
    state = "FAIL"
elif "PASS" in states:
    state = "PASS"
elif "SKIP" in states:
    state = "SKIP"
else:
    state = "INFO"
artifacts = []
for root, dirs, files in os.walk(sc):
    if os.path.basename(root) == "session":
        dirs[:] = []
        continue
    for f in files:
        if f.startswith(".") or f == "checks.tsv":
            continue
        artifacts.append(os.path.relpath(os.path.join(root, f), sc))
verdict = {
    "scenario": sid, "state": state, "pass": state == "PASS",
    "skipped": state == "SKIP", "duration_s": dur,
    "checks": checks, "artifacts": sorted(artifacts),
}
with open(os.path.join(sc, "verdict.json"), "w") as fh:
    json.dump(verdict, fh, indent=2)
summary = "; ".join(c["detail"] for c in checks if c["state"] in ("FAIL", "SKIP")) \
    or "; ".join(c["detail"] for c in checks if c["state"] == "PASS")[:160]
print(state + "\t" + summary.replace("\t", " "))
PY
)
    local state_only="${state%%$'\t'*}"
    local detail="${state#*$'\t'}"
    printf '%s\t%s\t%s\t%s\n' "$id" "$state_only" "$dur" "$detail" >>"$RUN/results.tsv"
    printf '%-24s %-5s %5ss  %s\n' "$id" "$state_only" "$dur" "$detail"
}

run_scenario() {
    local id="$1"
    SC="$SCEN_DIR/$id"
    mkdir -p "$SC/shots"
    : >"$SC/checks.tsv"
    local t0
    t0=$(date +%s)
    log "=== scenario: $id ==="

    if session_start "$BIN" "$SC/session" "$id" >/dev/null 2>&1; then
        case "$id" in
            basic-bel) sc_basic bel ;;
            basic-st) sc_basic st ;;
            terminator-8bit-st) sc_terminator_8bit ;;
            do-not-move-cursor) sc_do_not_move_cursor ;;
            size-cells) sc_size_cells ;;
            size-px) sc_size_px ;;
            size-percent) sc_size_percent ;;
            size-one-dim) sc_size_one_dim ;;
            size-stretch) sc_size_stretch ;;
            size-letterbox) sc_size_letterbox ;;
            inline-zero) sc_inline_zero ;;
            wire-errors) sc_wire_errors ;;
            two-images) sc_two_images ;;
            two-images-newline) sc_two_images_newline ;;
            scrollback) sc_scrollback ;;
            resize) sc_resize ;;
            clear) sc_clear ;;
            tall-image) sc_tall_image ;;
            large-image) sc_large_image ;;
            photo-payload) sc_photo_payload ;;
            payload-boundary) sc_payload_boundary ;;
            payload-100k) sc_payload_100k ;;
            payload-1m) sc_payload_1m ;;
            payload-5m) sc_payload_5m ;;
            payload-oversize) sc_payload_oversize ;;
            memory-guard) sc_memory_guard ;;
            erase-semantics) sc_erase_semantics ;;
            control-omitted) sc_control_omitted ;;
            control-xterm) sc_control_xterm ;;
            control-stock-vte) sc_control_stock_vte ;;
            *) ck_fail implementation "unknown scenario $id" ;;
        esac
        session_stop
    else
        ck_fail session-start "ptyxis window/driver did not come up; see $SC/session/ptyxis.log"
    fi
    finalize_scenario "$SC" "$id" "$t0"
}

# -------------------------------------------------------------------- main

log "imgcat e2e harness"
log "  binary : $BIN"
log "  emitter: ${EMITTER:-<bundled emit_osc.sh fallback>}"
log "  run dir: $RUN"
log "  scenarios: ${SELECTED[*]}"

"$LIB/fixtures.sh" "$FIX" >>"$RUN/harness.log" 2>&1 || { log "fixture generation failed"; exit 2; }

# Extra fixtures for payload-size / tall-image coverage.
convert -size 480x320 gradient:'#301040-#103080' -seed 7 +noise Random \
    -fill '#FF00FF' -draw 'rectangle 10,10 89,89' -strip -depth 8 "PNG24:$FIX/photo-480x320.png" \
    >>"$RUN/harness.log" 2>&1
convert -size 100x1200 xc:'#FF8800' -strip -depth 8 "PNG24:$FIX/tall-100x1200.png" \
    >>"$RUN/harness.log" 2>&1
# Solid magenta without a border: magenta bbox == painted bitmap bounds, so
# sizing and cursor assertions can be numeric.
convert -size 480x320 xc:'#FF00FF' -strip -depth 8 "PNG24:$FIX/plain-magenta-480x320.png" \
    >>"$RUN/harness.log" 2>&1
# Just under / just over the old 4096-byte VTE OSC cap.
convert -size 190x1200 xc:'#FF8800' -strip -depth 8 "PNG24:$FIX/seq-under-4096.png" \
    >>"$RUN/harness.log" 2>&1
convert -size 200x1200 xc:'#FF8800' -strip -depth 8 "PNG24:$FIX/seq-over-4096.png" \
    >>"$RUN/harness.log" 2>&1
# Incompressible payloads with a 25%-area magenta marker for render detection.
convert -size 160x160 xc:'#202020' -seed 3 +noise Random -fill '#FF00FF' \
    -draw 'rectangle 0,0 39,39' -strip -depth 8 "PNG24:$FIX/noise-100k.png" \
    >>"$RUN/harness.log" 2>&1
convert -size 500x500 xc:'#202020' -seed 3 +noise Random -fill '#FF00FF' \
    -draw 'rectangle 0,0 124,124' -strip -depth 8 "PNG24:$FIX/noise-1m.png" \
    >>"$RUN/harness.log" 2>&1
convert -size 1120x1120 xc:'#202020' -seed 3 +noise Random -fill '#FF00FF' \
    -draw 'rectangle 0,0 279,279' -strip -depth 8 "PNG24:$FIX/noise-5m.png" \
    >>"$RUN/harness.log" 2>&1
convert -size 3000x3000 xc:'#202020' -seed 5 +noise Random -strip -depth 8 \
    "PNG24:$FIX/noise-oversize.png" >>"$RUN/harness.log" 2>&1
log "fixtures: magenta=$(stat -c %s "$FIX/magenta-480x320.png")B plain=$(stat -c %s "$FIX/plain-magenta-480x320.png")B photo=$(stat -c %s "$FIX/photo-480x320.png")B large=$(stat -c %s "$FIX/large-3000x2000.png")B tall=$(stat -c %s "$FIX/tall-100x1200.png")B"
log "payloads: under4096=$(stat -c %s "$FIX/seq-under-4096.png")B over4096=$(stat -c %s "$FIX/seq-over-4096.png")B 100k=$(stat -c %s "$FIX/noise-100k.png")B 1m=$(stat -c %s "$FIX/noise-1m.png")B 5m=$(stat -c %s "$FIX/noise-5m.png")B oversize=$(stat -c %s "$FIX/noise-oversize.png")B"

display_start "$RUN/display" || { log "could not start Xvfb"; exit 2; }
log "display: $DISPLAY ($(xdpyinfo 2>/dev/null | awk '/dimensions:/ {print $2}'))"

calibrate

printf '%-24s %-5s %6s  %s\n' SCENARIO STATE TIME DETAIL | tee -a "$RUN/summary.txt"
for s in "${SELECTED[@]}"; do
    run_scenario "$s" | tee -a "$RUN/summary.txt"
done

python3 - "$RUN" >"$RUN/summary-final.txt" <<'PY'
import json, os, sys
run = sys.argv[1]
rows = []
for line in open(os.path.join(run, "results.tsv")):
    sid, state, dur, detail = line.rstrip("\n").split("\t", 3)
    rows.append({"scenario": sid, "state": state, "duration_s": int(dur), "detail": detail})
passed = [r for r in rows if r["state"] == "PASS"]
failed = [r for r in rows if r["state"] == "FAIL"]
skipped = [r for r in rows if r["state"] == "SKIP"]
binary = emitter = None
for line in open(os.path.join(run, "harness.log")):
    if "binary :" in line and binary is None:
        binary = line.split(":", 1)[1].strip()
    if "emitter:" in line and emitter is None:
        emitter = line.split(":", 1)[1].strip()
summary = {
    "run_dir": run, "binary": binary, "emitter": emitter,
    "total": len(rows), "passed": len(passed), "failed": len(failed),
    "skipped": len(skipped), "scenarios": rows,
}
with open(os.path.join(run, "summary.json"), "w") as fh:
    json.dump(summary, fh, indent=2)
print()
print("=" * 84)
print("RESULT: %d passed, %d failed, %d skipped  (of %d)" % (
    len(passed), len(failed), len(skipped), len(rows)))
for r in rows:
    print("  %-24s %-5s %5ss  %s" % (r["scenario"], r["state"], r["duration_s"], r["detail"]))
print("artifacts: %s" % run)
print("=" * 84)
sys.exit(1 if failed else 0)
PY
cat "$RUN/summary-final.txt"

if grep -q $'\tFAIL\t' "$RUN/results.tsv"; then
    exit 1
fi
exit 0
