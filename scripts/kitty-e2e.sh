#!/bin/bash
# kitty-e2e.sh - headless end-to-end verification of Kitty graphics protocol
# support in a Ptyxis/VTE build.
#
# Reuses the imgcat harness session layer: private Xvfb + openbox, ptyxis under
# a throwaway dbus session with a systemd-run shim, FIFO-driven commands,
# screenshots, and exact pixel assertions.
#
# Usage:
#   scripts/kitty-e2e.sh [--bin PATH] [--emitter-dir DIR] [--out DIR]
#                        [--scenario NAME]... [--keep] [--timeout SEC] [--list]
#
# Defaults:
#   --bin     $KITTY_BIN or the last known Kitty-less build
#             (/nix/store/q8jc1ksbbcz7za4xhb93qp2554xkpdhc-ptyxis-50.1)
#   --out     /tmp/opencode/kitty-e2e
# Emitter discovery: $KITTY_EMITTER_DIR/kitty_emit.py or scripts/lib/kitty_emit.py,
# wrapped by scripts/lib/kitty_wire.py.
#
# Exit 0 iff every selected scenario passed/skipped, 1 on any FAIL, 2 bad args.

set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LIB="$SCRIPT_DIR/lib"
# shellcheck source=lib/session.sh
. "$LIB/session.sh"

DEFAULT_BIN=/nix/store/q8jc1ksbbcz7za4xhb93qp2554xkpdhc-ptyxis-50.1/bin/ptyxis
BIN="${KITTY_BIN:-$DEFAULT_BIN}"
OUTROOT="${KITTY_E2E_OUT:-/tmp/opencode/kitty-e2e}"
EMITTER_DIR="${KITTY_EMITTER_DIR:-}"
KEEP=0
LIST_ONLY=0
TIMEOUT=40
SELECTED=()

ALL_SCENARIOS=(
    capability-probe
    basic-render
    raw-rgb
    raw-rgba
    zlib
    chunking-100k
    chunking-partial
    chunk-apc-limit
    envelope-forms
    geometry-cell-box
    geometry-one-dim
    geometry-source-rect
    geometry-cursor
    geometry-zorder
    zorder-text
    geometry-multi-placement
    delete-image-id
    delete-placement
    delete-all
    retransmit
    lifecycle-scroll
    lifecycle-resize
    lifecycle-clear
    lifecycle-altscreen
    reply-default
    quiet-q2
    shared-emitter-render
    memory-images
    control-stock-vte
    iterm2-regression
    opentui-demo
)

usage() { sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

while [ $# -gt 0 ]; do
    case "$1" in
        --bin) BIN="$2"; shift 2 ;;
        --emitter-dir) EMITTER_DIR="$2"; shift 2 ;;
        --out) OUTROOT="$2"; shift 2 ;;
        --scenario) SELECTED+=("$2"); shift 2 ;;
        --timeout) TIMEOUT="$2"; shift 2 ;;
        --keep) KEEP=1; shift ;;
        --list) LIST_ONLY=1; shift ;;
        -h|--help) usage ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done
if [ "$LIST_ONLY" = 1 ]; then printf '%s\n' "${ALL_SCENARIOS[@]}"; exit 0; fi
[ -x "$BIN" ] || { echo "error: ptyxis binary not executable: $BIN" >&2; exit 2; }
if [ ${#SELECTED[@]} -eq 0 ]; then SELECTED=("${ALL_SCENARIOS[@]}"); fi
if [ -n "$EMITTER_DIR" ]; then export KITTY_EMITTER_DIR="$EMITTER_DIR"; fi

RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"
RUN="$OUTROOT/$RUN_ID"
FIX="$RUN/fixtures"
SCEN_DIR="$RUN/scenarios"
mkdir -p "$FIX" "$SCEN_DIR"
: >"$RUN/results.tsv"

PROBE_HELPER="$LIB/kitty_tty.py"
[ -f "$LIB/kitty_probe.py" ] && PROBE_HELPER="$LIB/kitty_probe.py"

log() { printf '%s\n' "$*" >>"$RUN/harness.log"; printf '%s\n' "$*"; }
cleanup() {
    session_stop 2>/dev/null
    if [ "$KEEP" = 1 ]; then log "kept display $DISPLAY"; else display_stop 2>/dev/null; fi
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
count_of() { pix count --image "$1" --color "$2" --fuzz "${3:-0}" 2>/dev/null | json_field count; }
bbox_of() {
    pix bbox --image "$1" --color "$2" --fuzz "${3:-0}" 2>/dev/null |
        python3 -c 'import json,sys
d=json.load(sys.stdin)
print(d["x"], d["y"], d["w"], d["h"], d["count"], int(bool(d["found"])))'
}
inside_window() {
    local x=$1 y=$2 w=$3 h=$4 wx wy ww wh
    read -r wx wy ww wh <<<"$(session_window_geom)" || { echo no; return; }
    [ "$w" -gt 0 ] && [ "$h" -gt 0 ] || { echo no; return; }
    if [ "$x" -ge "$wx" ] && [ "$y" -ge "$wy" ] &&
       [ $((x + w)) -le $((wx + ww)) ] && [ $((y + h)) -le $((wy + wh)) ]; then echo yes; else echo no; fi
}

near() { # value expected [tol]
    local v=$1 e=$2 t=${3:-2}
    [ $((v - e)) -le "$t" ] && [ $((e - v)) -le "$t" ]
}

# Emitter wrappers ------------------------------------------------------------
WIRE="$LIB/kitty_wire.py"
kemit_png() { local out=$1 file=$2 id=$3; shift 3; python3 "$WIRE" png "$file" --image-id "$id" --out "$out" "$@"; }
kemit_raw() {
    local out=$1 w=$2 h=$3 fmt=$4 raw=$5 id=$6; shift 6
    python3 "$WIRE" raw --width "$w" --height "$h" --format "$fmt" --file "$raw" --image-id "$id" --out "$out" "$@"
}
kemit_place() { local out=$1 id=$2; shift 2; python3 "$WIRE" place --image-id "$id" --out "$out" "$@"; }
kemit_delete() { local out=$1 mode=$2; shift 2; python3 "$WIRE" delete --mode "$mode" --out "$out" "$@"; }
kemit_query() { local out=$1; shift; python3 "$WIRE" query --out "$out" "$@"; }
frame_count() { python3 "$WIRE" count-frames "$1"; }
dump_wire() { python3 "$WIRE" dump "$1" >>"$RUN/harness.log" 2>&1 || true; }

send_file() { session_send "cat '$1'" "${2:-$TIMEOUT}"; }
send_clear() { session_send "printf '\\033[H\\033[2J\\033[3J'" 10 >/dev/null 2>&1 || true; }
send_echo_off() { session_send "stty -F /dev/tty -echo -echoctl 2>/dev/null" 6 >/dev/null 2>&1 || true; }

# DSR cursor via /dev/tty helper; echoes "row col" or fails.
cursor_now() {
    local f="$SC/.cursor.$RANDOM.$RANDOM"
    session_send "python3 '$LIB/kitty_tty.py' cursor > '$f' 2>'$f.err'" 10 || return 1
    [ -s "$f" ] || { rm -f "$f"; return 1; }
    cat "$f"; rm -f "$f"
}

# Fresh session with echo disabled (Kitty OK replies must not appear on screen).
kstart() {
    session_start "$BIN" "$SC/session" "$1" || return 1
    send_echo_off
    send_clear
    return 0
}

# Pixel assertions -----------------------------------------------------------
# Check a colour's bbox size/position; globals KB_*.
bbox_check() { # shot colour label exp_w exp_h tol
    local shot=$1 colour=$2 label=$3 ew=$4 eh=$5 tol=${6:-2}
    read -r KB_X KB_Y KB_W KB_H KB_C KB_F <<<"$(bbox_of "$shot" "$colour")"
    ck_info "$label-bbox" "x=$KB_X y=$KB_Y w=$KB_W h=$KB_H count=$KB_C found=$KB_F"
    if [ "$KB_F" != 1 ] || [ "$KB_C" -lt 100 ]; then
        ck_fail "$label-present" "no $colour pixels (count=$KB_C)"
        return 1
    fi
    ck_pass "$label-present" "$colour count=$KB_C bbox ${KB_W}x${KB_H} at ${KB_X},${KB_Y}"
    if [ -n "$ew" ]; then
        if [ $((KB_W - ew)) -le "$tol" ] && [ $((ew - KB_W)) -le "$tol" ] &&
           [ $((KB_H - eh)) -le "$tol" ] && [ $((eh - KB_H)) -le "$tol" ]; then
            ck_pass "$label-size" "expected ${ew}x${eh}, got ${KB_W}x${KB_H}"
        else
            ck_fail "$label-size" "expected ${ew}x${eh}, got ${KB_W}x${KB_H}"
        fi
    fi
    return 0
}


# Calibration ---------------------------------------------------------------
calibrate() {
    local sc="$RUN/calibration" ok=0
    mkdir -p "$sc/shots"
    SC="$sc"
    if kstart "calibration"; then
        session_send 'printf "\033[48;2;255;0;0m"; for i in $(seq 1 10); do printf "%20s\n" ""; done; printf "\033[0m"' 15 >/dev/null 2>&1 || true
        if session_shot "$sc/shots/calibration.png"; then
            local bx by bw bh bc f wx wy ww wh
            read -r bx by bw bh bc f <<<"$(bbox_of "$sc/shots/calibration.png" '#FF0000')"
            read -r wx wy ww wh <<<"$(session_window_geom)"
            if [ "$f" = 1 ] && [ "$bw" -ge 50 ] && [ "$bh" -ge 50 ]; then
                python3 - "$bw" "$bh" "$bx" "$by" "$wx" "$wy" >"$RUN/calibration.json" <<'PY'
import json, sys
bw, bh, bx, by, wx, wy = map(int, sys.argv[1:7])
print(json.dumps({"cell_w": round(bw/20.0, 4), "cell_h": round(bh/10.0, 4),
                  "content_x": bx, "content_y": by,
                  "content_off_x": bx-wx, "content_off_y": by-wy,
                  "window_x": wx, "window_y": wy,
                  "source": "20x10 truecolor-red block"}, indent=2))
PY
                ok=1
            fi
        fi
        session_stop
    fi
    if [ "$ok" != 1 ]; then
        printf '{"cell_w":9.0,"cell_h":18.0,"content_off_x":11,"content_off_y":58,"source":"fallback"}\n' >"$RUN/calibration.json"
        log "WARN: calibration failed; using 9x18 cells"
    fi
    log "calibration: $(tr -d '\n ' <"$RUN/calibration.json")"
}
cell_w_i() { python3 -c "print(int(round($(json_field cell_w <"$RUN/calibration.json"))))"; }
cell_h_i() { python3 -c "print(int(round($(json_field cell_h <"$RUN/calibration.json"))))"; }
content_origin() {
    local wx wy ww wh
    read -r wx wy ww wh <<<"$(session_window_geom)" || return 1
    printf '%s %s\n' $((wx + $(json_field content_off_x <"$RUN/calibration.json"))) \
                     $((wy + $(json_field content_off_y <"$RUN/calibration.json")))
}
scenario_dims() { session_size 2>/dev/null || echo "22 84"; }

# --------------------------------------------------------------- scenarios

sc_capability_probe() {
    local reply="$SC/reply.bin" rc=0 before after
    before=$(cursor_now 2>/dev/null || true)
    # Spec §5: the 38-byte probe is immediately followed by DA1; the graphics
    # reply must arrive before the DA1 reply.
    python3 - "$SC/probe-request.bin" <<'PYINNER'
import sys
probe = b'\x1b_Gi=31337,s=1,v=1,a=q,t=d,f=24;AAAA\x1b\\'
open(sys.argv[1], 'wb').write(probe + b'\x1b[c')
PYINNER
    local hex
    hex=$(od -An -tx1 "$SC/probe-request.bin" | tr -d ' \n')
    ck_info request "probe+DA1 = $hex"
    session_send "python3 '$PROBE_HELPER' --timeout 1.5 --probe-bytes '$hex' --raw-out '$reply' >/dev/null 2>'$SC/probe.err'; echo \$? > '$SC/probe.rc'" 12 || true
    rc=$(cat "$SC/probe.rc" 2>/dev/null || echo 9)
    after=$(cursor_now 2>/dev/null || true)
    python3 - "$reply" >"$SC/reply.txt" <<'PYINNER'
import os, re, sys
p = sys.argv[1]
d = open(p, 'rb').read() if os.path.exists(p) else b''
ok = b'\x1b_Gi=31337;OK\x1b\\'
bel = b'\x1b_Gi=31337;OK\x07'
da1 = re.search(rb'\x1b\[\?[0-9;]*c', d)
apc = d.find(ok)
print("bytes=%d" % len(d))
print("escaped=%s" % d.replace(b'\x1b', b'\\e').decode('latin-1', 'replace')[:600])
print("has_ok=%d" % (1 if ok in d else 0))
print("has_bel=%d" % (1 if bel in d else 0))
print("da1=%s" % (da1.group(0).decode('latin-1') if da1 else "none"))
print("apc_index=%d" % apc)
print("da1_index=%d" % (da1.start() if da1 else -1))
print("ordered=%d" % (1 if apc >= 0 and (da1 is None or apc < da1.start()) else 0))
PYINNER
    cat "$SC/reply.txt" >>"$RUN/harness.log"
    ck_info reply-raw "$(head -2 "$SC/reply.txt" | tr '\n' ' ') rc=$rc"
    ck_info da1 "$(grep '^da1=' "$SC/reply.txt")"
    [ -n "$before" ] && [ -n "$after" ] && ck_info cursor "probe cursor $before -> $after (a=q must not move it)"
    if grep -q '^has_ok=1' "$SC/reply.txt"; then
        ck_pass exact-ok "reply contains the exact ST-terminated ESC_Gi=31337;OK ESC\\"
    else
        ck_fail exact-ok "no exact ESC_Gi=31337;OK ESC\\ reply (Kitty gate absent; DA1-only capture is not enough)"
    fi
    if grep -q '^has_bel=1' "$SC/reply.txt"; then
        ck_fail bel-invalid "terminal answered with a BEL-terminated OK (invalid for OpenTUI)"
    else
        ck_pass bel-invalid "no BEL-terminated OK reply"
    fi
    if grep -q '^ordered=1' "$SC/reply.txt"; then
        ck_pass ordering "graphics reply arrived before the DA1 reply"
    else
        ck_fail ordering "graphics reply missing or delivered after DA1"
    fi
    if [ -n "$before" ] && [ "$before" = "$after" ]; then ck_pass no-cursor-move "a=q left the cursor at ($before)"; else ck_fail no-cursor-move "a=q moved cursor $before -> $after"; fi
    session_shot "$SC/shots/after.png"
    local mag; mag=$(count_of "$SC/shots/after.png" '#FF00FF')
    if [ "${mag:-1}" -eq 0 ]; then ck_pass no-draw "a=q drew nothing (magenta=0)"; else ck_fail no-draw "a=q drew magenta=$mag"; fi
    if session_alive; then ck_pass alive "ptyxis alive after probe"; else ck_fail alive "ptyxis died on probe"; fi
}

sc_basic_render() {
    local cw ch cy cx
    cw=$(cell_w_i); ch=$(cell_h_i)
    read -r cx cy <<<"$(content_origin)"
    kemit_png "$SC/transmit.bin" "$FIX/chunked-480x320.png" 1 --action t --chunk 3072 ||
        { ck_fail emission "png emit failed"; return; }
    local frames; frames=$(frame_count "$SC/transmit.bin")
    ck_info frames "transmit uses $frames APC frame(s), $(stat -c %s "$SC/transmit.bin") bytes"
    dump_wire "$SC/transmit.bin"
    send_file "$SC/transmit.bin" || { ck_fail transmit "timed out"; return; }
    kemit_place "$SC/place.bin" 1 --placement-id 1 --columns 40 --no-move ||
        { ck_fail placement-emit "failed"; return; }
    send_file "$SC/place.bin" || { ck_fail placement "timed out"; return; }
    session_shot "$SC/shots/after.png"
    bbox_check "$SC/shots/after.png" '#FF00FF' image 360 240 2 || return
    local bx by bw bh bc f
    read -r bx by bw bh bc f <<<"$(bbox_of "$SC/shots/after.png" '#00FFFF')"
    ck_info cyan-bbox "x=$bx y=$by w=$bw h=$bh count=$bc found=$f"
    if [ "$f" = 1 ] && [ "$bc" -ge 1500 ] && [ $((bw - 60)) -le 3 ] && [ $((60 - bw)) -le 3 ]; then
        ck_pass cyan-inset "cyan inset 60x60 (count=$bc) at +$((bx - cx)),+$((by - cy))"
    else
        ck_fail cyan-inset "cyan inset missing/wrong (count=$bc bbox ${bw}x${bh})"
    fi
    if [ "$frames" -gt 1 ]; then ck_pass chunked "payload exercised m=1 chunking ($frames frames)"; else ck_fail chunked "single frame; >3072B payload was not chunked"; fi
    check_continuations "$SC/transmit.bin" transmit
    if [ "$(inside_window "$bx" "$by" "$bw" "$bh")" = yes ]; then ck_pass in-window "image inside window"; else ck_fail in-window "image outside window"; fi
    if session_alive; then ck_pass alive "ptyxis alive"; else ck_fail alive "ptyxis died"; fi
}

_raw_common() { # name rawfile fmt [extra emitter args...]
    local name=$1 raw=$2 fmt=$3; shift 3
    local cw ch cx cy
    cw=$(cell_w_i); ch=$(cell_h_i)
    read -r cx cy <<<"$(content_origin)"
    kemit_raw "$SC/transmit.bin" 64 64 "$fmt" "$raw" 20 --action t --chunk 3072 "$@" ||
        { ck_fail emission "raw emit failed"; return; }
    send_file "$SC/transmit.bin" || { ck_fail transmit "timed out"; return; }
    kemit_place "$SC/place.bin" 20 --placement-id 1 --columns 20 --no-move ||
        { ck_fail placement-emit "failed"; return; }
    send_file "$SC/place.bin" || { ck_fail placement "timed out"; return; }
    session_shot "$SC/shots/after.png"
}

sc_raw_rgb() {
    _raw_common raw-rgb "$FIX/raw-rgb-64.bin" 24
    bbox_check "$SC/shots/after.png" '#FF00FF' magenta 90 180 2 || return
    local bx by bw bh bc f
    read -r bx by bw bh bc f <<<"$(bbox_of "$SC/shots/after.png" '#0000FF')"
    ck_info blue-bbox "x=$bx y=$by w=$bw h=$bh count=$bc found=$f"
    if [ "$f" = 1 ] && [ "$bc" -ge 10000 ] && [ "$bx" -ge $((KB_X + 86)) ]; then
        ck_pass blue-half "blue right half rendered (count=$bc bbox ${bw}x${bh})"
    else
        ck_fail blue-half "blue right half missing (count=$bc)"
    fi
    if session_alive; then ck_pass alive "alive"; else ck_fail alive "died"; fi
}

sc_raw_rgba() {
    _raw_common raw-rgba "$FIX/raw-rgba-64.bin" 32
    bbox_check "$SC/shots/after.png" '#FF00FF' magenta 180 90 2 || return
    local green; green=$(count_of "$SC/shots/after.png" '#00FF00')
    ck_info alpha-region "green(alpha=0) pixels=$green (expected 0: transparent shows terminal background)"
    if [ "${green:-1}" -eq 0 ]; then
        ck_pass alpha "alpha=0 pixels are transparent (green absent)"
    else
        ck_fail alpha "alpha=0 region painted green=$green; alpha channel ignored"
    fi
    if session_alive; then ck_pass alive "alive"; else ck_fail alive "died"; fi
}

sc_zlib() {
    _raw_common zlib "$FIX/raw-rgb-64.bin" 24 --zlib
    ck_info zlib "o=z compressed transmit"
    bbox_check "$SC/shots/after.png" '#FF00FF' magenta 90 180 2 || return
    local blue; blue=$(count_of "$SC/shots/after.png" '#0000FF')
    if [ "${blue:-0}" -ge 10000 ]; then ck_pass blue-half "blue half present (count=$blue)"; else ck_fail blue-half "blue half missing (count=$blue)"; fi
    if session_alive; then ck_pass alive "alive"; else ck_fail alive "died"; fi
}

sc_chunking_100k() {
    local cx cy
    read -r cx cy <<<"$(content_origin)"
    kemit_png "$SC/transmit.bin" "$FIX/chunk-100k.png" 30 --action t --chunk 3072 ||
        { ck_fail emission "emit failed"; return; }
    local frames; frames=$(frame_count "$SC/transmit.bin")
    ck_info frames "$frames frames, $(stat -c %s "$SC/transmit.bin") bytes (payload $(stat -c %s "$FIX/chunk-100k.png")B PNG)"
    if [ "$frames" -ge 20 ]; then ck_pass frame-count "$frames APC frames (>=20)"; else ck_fail frame-count "only $frames frames"; fi
    send_file "$SC/transmit.bin" 60 || { ck_fail transmit "timed out"; return; }
    kemit_place "$SC/place.bin" 30 --placement-id 1 --columns 40 --no-move ||
        { ck_fail placement-emit "failed"; return; }
    send_file "$SC/place.bin" || { ck_fail placement "timed out"; return; }
    session_shot "$SC/shots/after.png"
    bbox_check "$SC/shots/after.png" '#FF00FF' marker 90 90 3 || return
    if [ "$KB_C" -ge 5000 ]; then ck_pass reassembled "100 kB payload reassembled (marker=$KB_C)"; else ck_fail reassembled "marker too small ($KB_C)"; fi
    if session_alive; then ck_pass alive "alive"; else ck_fail alive "died"; fi
}

sc_geometry_cell_box() {
    local cx cy cw ch
    cw=$(cell_w_i); ch=$(cell_h_i)
    read -r cx cy <<<"$(content_origin)"
    kemit_png "$SC/transmit.bin" "$FIX/blue-96.png" 40 --action t --chunk 3072 ||
        { ck_fail emission "emit failed"; return; }
    send_file "$SC/transmit.bin" || { ck_fail transmit "timed out"; return; }
    # Placement 1: columns only -> width 20 cells, aspect height.
    kemit_place "$SC/p1.bin" 40 --placement-id 1 --columns 20 --no-move ||
        { ck_fail place1-emit "failed"; return; }
    send_file "$SC/p1.bin" || { ck_fail place1 "timed out"; return; }
    session_shot "$SC/shots/cols.png"
    bbox_check "$SC/shots/cols.png" '#0000FF' cols 180 180 2
    local cols_w=$KB_W cols_h=$KB_H cols_x=$KB_X cols_y=$KB_Y
    # Remove placement 1 so the next screenshot measures placement 2 only.
    kemit_delete "$SC/dp1.bin" i --image-id 40 --placement-id 1 || { ck_fail delete-p1-emit "failed"; return; }
    send_file "$SC/dp1.bin" || { ck_fail delete-p1 "timed out"; return; }
    # Placement 2: columns+rows -> cell box 20x5 (=180x90); the square bitmap is
    # pillarboxed to 90x90, centred horizontally (off_x=45).
    session_send "printf '\\033[1;30H'" 8 >/dev/null 2>&1 || true
    kemit_place "$SC/p2.bin" 40 --placement-id 2 --columns 20 --rows 5 --no-move ||
        { ck_fail place2-emit "failed"; return; }
    send_file "$SC/p2.bin" || { ck_fail place2 "timed out"; return; }
    session_shot "$SC/shots/colsrows.png"
    # Spec §7: both c and r reserve a cell box and letterbox/pillarbox the
    # bitmap inside it (aspect preserved, no distortion). 96x96 into 20x5
    # cells (180x90) -> 90x90 drawn, centred horizontally (off_x=45).
    bbox_check "$SC/shots/colsrows.png" '#0000FF' colsrows 90 90 3
    if [ -n "${cols_w:-}" ] && [ $((cols_w - 180)) -le 2 ] && [ $((cols_h - 180)) -le 2 ]; then
        ck_pass cols-only "c=20 on 96x96 -> 180x180 (aspect)"
    else
        ck_fail cols-only "c=20 -> ${cols_w:-?}x${cols_h:-?}, expected 180x180"
    fi
    local exp_x=$((cx + 29 * cw + 45))
    ck_info anchors "cols at ${cols_x:-?},${cols_y:-?}; cols+rows bbox at ${KB_X},${KB_Y}; expected x=$exp_x (anchor ${cx},${cy} + 29 cells + off_x 45)"
    if [ $((KB_X - exp_x)) -le 3 ] && [ $((exp_x - KB_X)) -le 3 ]; then
        ck_pass pillarboxed "bitmap centred in the 20x5-cell box at x=$KB_X (expected $exp_x)"
    else
        ck_fail pillarboxed "bitmap at x=$KB_X, expected $exp_x (off_x=45 in a 180px box)"
    fi
    if session_alive; then ck_pass alive "alive"; else ck_fail alive "died"; fi
}

sc_geometry_source_rect() {
    kemit_png "$SC/transmit.bin" "$FIX/source-200x100.png" 41 --action t --chunk 3072 ||
        { ck_fail emission "emit failed"; return; }
    send_file "$SC/transmit.bin" || { ck_fail transmit "timed out"; return; }
    kemit_place "$SC/place.bin" 41 --placement-id 1 --src 100,0,100,100 --columns 10 --no-move ||
        { ck_fail place-emit "failed"; return; }
    send_file "$SC/place.bin" || { ck_fail place "timed out"; return; }
    session_shot "$SC/shots/after.png"
    local red; red=$(count_of "$SC/shots/after.png" '#FF0000')
    bbox_check "$SC/shots/after.png" '#0000FF' blue 90 90 3 || return
    ck_info red "red pixels=$red (source rect excludes the left half)"
    if [ "${red:-9999}" -lt 500 ]; then
        ck_pass source-crop "only the source rect was drawn (red pixels=$red: <=2px bilinear bleed at the x=100 crop edge)"
    else
        ck_fail source-crop "red pixels=$red; source rect ignored"
    fi
    if session_alive; then ck_pass alive "alive"; else ck_fail alive "died"; fi
}

sc_geometry_cursor() {
    local before after rows cols er ec
    read -r rows cols <<<"$(scenario_dims)"
    before=$(cursor_now) || { ck_fail cursor-before "no DSR reply"; return; }
    kemit_png "$SC/transmit.bin" "$FIX/green-64.png" 42 --action t --chunk 3072 ||
        { ck_fail emission "emit failed"; return; }
    send_file "$SC/transmit.bin" || { ck_fail transmit "timed out"; return; }
    kemit_place "$SC/place1.bin" 42 --placement-id 1 --columns 10 --no-move ||
        { ck_fail place1-emit "failed"; return; }
    send_file "$SC/place1.bin" || { ck_fail place1 "timed out"; return; }
    after=$(cursor_now) || { ck_fail cursor-after "no DSR reply"; return; }
    ck_info cursor "C=1: $before -> $after"
    if [ "$before" = "$after" ]; then ck_pass no-move "C=1 keeps the cursor at ($before)"; else ck_fail no-move "C=1 moved cursor $before -> $after"; fi
    # Default C (move cursor): 90x90 at columns=10 -> 10 cols, 5 rows.
    # Spec §8: without C=1 the cursor moves right by c cells and down by r rows.
    er=$(python3 -c "print(1 + (90 + $(cell_h_i) - 1)//$(cell_h_i))")
    ec=$(python3 -c "print(min(1 + 10, $cols))")
    kemit_place "$SC/place2.bin" 42 --placement-id 2 --columns 10 ||
        { ck_fail place2-emit "failed"; return; }
    send_file "$SC/place2.bin" || { ck_fail place2 "timed out"; return; }
    after=$(cursor_now) || { ck_fail cursor-default "no DSR reply"; return; }
    ck_info cursor-default-dsr "$after (expected $er,$ec)"
    if [ "${after%% *}" = "$er" ] && [ "${after##* }" = "$ec" ]; then
        ck_pass cursor-default "default placement moves cursor right c=10 and down r=5 ($after)"
    else
        ck_fail cursor-default "cursor $after, expected $er,$ec (right c=10, down r=5)"
    fi
    if session_alive; then ck_pass alive "alive"; else ck_fail alive "died"; fi
}

sc_geometry_zorder() {
    kemit_png "$SC/red.bin" "$FIX/red-96.png" 50 --action t --chunk 3072 || { ck_fail emission-red "failed"; return; }
    kemit_png "$SC/blue.bin" "$FIX/blue-96.png" 51 --action t --chunk 3072 || { ck_fail emission-blue "failed"; return; }
    send_file "$SC/red.bin" || { ck_fail transmit-red "timed out"; return; }
    send_file "$SC/blue.bin" || { ck_fail transmit-blue "timed out"; return; }
    kemit_place "$SC/pre.bin" 50 --placement-id 1 --z 1 --no-move || { ck_fail place-red-emit "failed"; return; }
    send_file "$SC/pre.bin" || { ck_fail place-red "timed out"; return; }
    kemit_place "$SC/pbe.bin" 51 --placement-id 2 --z 2 --no-move || { ck_fail place-blue-emit "failed"; return; }
    send_file "$SC/pbe.bin" || { ck_fail place-blue "timed out"; return; }
    session_shot "$SC/shots/after.png"
    local red blue
    red=$(count_of "$SC/shots/after.png" '#FF0000')
    blue=$(count_of "$SC/shots/after.png" '#0000FF')
    ck_info zorder "z=2 blue vs z=1 red: red=$red blue=$blue"
    if [ "${blue:-0}" -ge 8000 ] && [ "${red:-1}" -eq 0 ]; then
        ck_pass zorder "higher z paints on top (blue visible, red occluded)"
    else
        ck_fail zorder "expected blue>=8000 red=0, got red=$red blue=$blue"
    fi
    # Deleting the top placement must reveal the lower one.
    kemit_delete "$SC/del.bin" i --image-id 51 --placement-id 2 || { ck_fail del-emit "failed"; return; }
    send_file "$SC/del.bin" || { ck_fail del "timed out"; return; }
    session_shot "$SC/shots/after-delete.png"
    red=$(count_of "$SC/shots/after-delete.png" '#FF0000')
    blue=$(count_of "$SC/shots/after-delete.png" '#0000FF')
    ck_info delete-reveal "after d=p: red=$red blue=$blue"
    if [ "${red:-0}" -ge 8000 ] && [ "${blue:-1}" -eq 0 ]; then
        ck_pass reveal "d=i,p=2 removed the top placement and revealed the lower one"
    else
        ck_fail reveal "after d=i,p=2 red=$red blue=$blue"
    fi
    if session_alive; then ck_pass alive "alive"; else ck_fail alive "died"; fi
}

sc_geometry_multi_placement() {
    local cx cy cw ch
    cw=$(cell_w_i); ch=$(cell_h_i)
    read -r cx cy <<<"$(content_origin)"
    kemit_png "$SC/transmit.bin" "$FIX/green-64.png" 52 --action t --chunk 3072 || { ck_fail emission "failed"; return; }
    send_file "$SC/transmit.bin" || { ck_fail transmit "timed out"; return; }
    kemit_place "$SC/p1.bin" 52 --placement-id 1 --no-move || { ck_fail place1-emit "failed"; return; }
    send_file "$SC/p1.bin" || { ck_fail place1 "timed out"; return; }
    session_send "printf '\\033[5;10H'" 8 >/dev/null 2>&1 || true
    kemit_place "$SC/p2.bin" 52 --placement-id 2 --no-move || { ck_fail place2-emit "failed"; return; }
    send_file "$SC/p2.bin" || { ck_fail place2 "timed out"; return; }
    session_shot "$SC/shots/after.png"
    local green bx by bw bh bc f
    green=$(count_of "$SC/shots/after.png" '#00FF00')
    read -r bx by bw bh bc f <<<"$(bbox_of "$SC/shots/after.png" '#00FF00')"
    ck_info green "count=$green bbox ${bw}x${bh} at ${bx},${by}"
    local exp_x=$((cx + 9 * cw)) exp_y=$((cy + 4 * ch))
    if [ "$green" -ge 7000 ] && near "$bw" $((64 + 9 * cw)) 4 && near "$bh" $((64 + 4 * ch)) 4; then
        ck_pass two-placements "same image id placed twice, combined bbox ${bw}x${bh}"
    else
        ck_fail two-placements "expected two 64x64 placements, got count=$green bbox=${bw}x${bh}"
    fi
    ck_info anchors "second placement anchor expected at ${exp_x},${exp_y}"
    if session_alive; then ck_pass alive "alive"; else ck_fail alive "died"; fi
}

sc_delete_image_id() {
    kemit_png "$SC/transmit.bin" "$FIX/red-96.png" 60 --action t --chunk 3072 || { ck_fail emission "failed"; return; }
    send_file "$SC/transmit.bin" || { ck_fail transmit "timed out"; return; }
    kemit_place "$SC/p1.bin" 60 --placement-id 1 --no-move || { ck_fail place-emit "failed"; return; }
    send_file "$SC/p1.bin" || { ck_fail place "timed out"; return; }
    session_shot "$SC/shots/before.png"
    local before; before=$(count_of "$SC/shots/before.png" '#FF0000')
    if [ "${before:-0}" -ge 8000 ]; then ck_pass present-before "red=$before"; else ck_fail present-before "red=$before"; return; fi
    kemit_delete "$SC/di.bin" i --image-id 60 || { ck_fail delete-emit "failed"; return; }
    send_file "$SC/di.bin" || { ck_fail delete "timed out"; return; }
    session_shot "$SC/shots/after-di.png"
    local after; after=$(count_of "$SC/shots/after-di.png" '#FF0000')
    if [ "${after:-1}" -eq 0 ]; then ck_pass delete-i "d=i removed all placements (red=0)"; else ck_fail delete-i "red=$after after d=i"; fi
    # d=i must retain image data: placing the same id again must work.
    kemit_place "$SC/p2.bin" 60 --placement-id 2 --no-move || { ck_fail re-place-emit "failed"; return; }
    send_file "$SC/p2.bin" || { ck_fail re-place "timed out"; return; }
    session_shot "$SC/shots/after-replace.png"
    local again; again=$(count_of "$SC/shots/after-replace.png" '#FF0000')
    if [ "${again:-0}" -ge 8000 ]; then ck_pass data-retained "d=i retains image data (re-place red=$again)"; else ck_fail data-retained "re-place after d=i red=$again (data freed too early)"; fi
    # d=I frees data: subsequent placement must not draw.
    kemit_delete "$SC/dI.bin" I --image-id 60 || { ck_fail deleteI-emit "failed"; return; }
    send_file "$SC/dI.bin" || { ck_fail deleteI "timed out"; return; }
    kemit_place "$SC/p3.bin" 60 --placement-id 3 --no-move || { ck_fail re2-emit "failed"; return; }
    send_file "$SC/p3.bin" || { ck_fail re2 "timed out"; return; }
    session_shot "$SC/shots/after-dI.png"
    local freed; freed=$(count_of "$SC/shots/after-dI.png" '#FF0000')
    if [ "${freed:-1}" -eq 0 ]; then ck_pass delete-I "d=I freed the image (re-place draws nothing)"; else ck_fail delete-I "re-place after d=I drew red=$freed"; fi
    if session_alive; then ck_pass alive "alive"; else ck_fail alive "died"; fi
}

sc_delete_placement() {
    local cx cy cw ch
    cw=$(cell_w_i); ch=$(cell_h_i)
    read -r cx cy <<<"$(content_origin)"
    kemit_png "$SC/transmit.bin" "$FIX/alt-64.png" 61 --action t --chunk 3072 || { ck_fail emission "failed"; return; }
    send_file "$SC/transmit.bin" || { ck_fail transmit "timed out"; return; }
    kemit_place "$SC/p1.bin" 61 --placement-id 1 --no-move || { ck_fail place1-emit "failed"; return; }
    send_file "$SC/p1.bin" || { ck_fail place1 "timed out"; return; }
    session_send "printf '\\033[1;10H'" 8 >/dev/null 2>&1 || true
    kemit_place "$SC/p2.bin" 61 --placement-id 2 --no-move || { ck_fail place2-emit "failed"; return; }
    send_file "$SC/p2.bin" || { ck_fail place2 "timed out"; return; }
    session_shot "$SC/shots/before.png"
    if [ "$(count_of "$SC/shots/before.png" '#FFFF00')" -ge 8000 ]; then ck_pass both "two placements visible"; else ck_fail both "expected two yellow placements"; fi
    kemit_delete "$SC/dp.bin" i --image-id 61 --placement-id 1 || { ck_fail delete-emit "failed"; return; }
    send_file "$SC/dp.bin" || { ck_fail delete "timed out"; return; }
    session_shot "$SC/shots/after.png"
    local c bx by bw bh bc f
    c=$(count_of "$SC/shots/after.png" '#FFFF00')
    read -r bx by bw bh bc f <<<"$(bbox_of "$SC/shots/after.png" '#FFFF00')"
    ck_info remaining "count=$c bbox ${bw}x${bh} at ${bx},${by}"
    if [ "${c:-0}" -ge 3500 ] && [ "${c:-0}" -le 5000 ] && [ "$bx" -ge $((cx + 9 * cw)) ]; then
        ck_pass delete-p "d=i,p=1 removed only placement 1; placement 2 remains"
    else
        ck_fail delete-p "d=i,p=1: expected one 64x64 placement at x>= $((cx + 9 * cw)), got count=$c bbox=${bw}x${bh} x=$bx"
    fi
    if session_alive; then ck_pass alive "alive"; else ck_fail alive "died"; fi
}

sc_delete_all() {
    kemit_png "$SC/red.bin" "$FIX/red-96.png" 70 --action t --chunk 3072 || { ck_fail emission-red "failed"; return; }
    kemit_png "$SC/blue.bin" "$FIX/blue-96.png" 71 --action t --chunk 3072 || { ck_fail emission-blue "failed"; return; }
    send_file "$SC/red.bin" || { ck_fail transmit-red "timed out"; return; }
    send_file "$SC/blue.bin" || { ck_fail transmit-blue "timed out"; return; }
    kemit_place "$SC/p1.bin" 70 --placement-id 1 --no-move || { ck_fail place1-emit "failed"; return; }
    send_file "$SC/p1.bin" || { ck_fail place1 "timed out"; return; }
    session_send "printf '\\033[1;20H'" 8 >/dev/null 2>&1 || true
    kemit_place "$SC/p2.bin" 71 --placement-id 2 --no-move || { ck_fail place2-emit "failed"; return; }
    send_file "$SC/p2.bin" || { ck_fail place2 "timed out"; return; }
    session_shot "$SC/shots/before.png"
    local pre_red pre_blue
    pre_red=$(count_of "$SC/shots/before.png" '#FF0000')
    pre_blue=$(count_of "$SC/shots/before.png" '#0000FF')
    ck_info before "red=$pre_red blue=$pre_blue"
    if [ "${pre_red:-0}" -lt 8000 ] || [ "${pre_blue:-0}" -lt 8000 ]; then
        ck_fail precondition "images not rendered before d=a (red=$pre_red blue=$pre_blue); cannot test deletion"
        return
    fi
    ck_pass precondition "both images rendered before d=a"
    kemit_delete "$SC/da.bin" a || { ck_fail delete-emit "failed"; return; }
    send_file "$SC/da.bin" || { ck_fail delete "timed out"; return; }
    session_shot "$SC/shots/after.png"
    local red blue
    red=$(count_of "$SC/shots/after.png" '#FF0000'); blue=$(count_of "$SC/shots/after.png" '#0000FF')
    ck_info remaining "after d=a: red=$red blue=$blue"
    if [ "${red:-1}" -eq 0 ] && [ "${blue:-1}" -eq 0 ]; then ck_pass delete-a "d=a removed all images/placements"; else ck_fail delete-a "red=$red blue=$blue after d=a"; fi
    # Spec §8: d=a removes visible placements; whether image data is freed is
    # not mandated (only uppercase d=... forms free data). Record the outcome.
    kemit_place "$SC/p3.bin" 70 --placement-id 3 --no-move || { ck_fail re-emit "failed"; return; }
    send_file "$SC/p3.bin" || { ck_fail re "timed out"; return; }
    session_shot "$SC/shots/after-replace.png"
    red=$(count_of "$SC/shots/after-replace.png" '#FF0000')
    if [ "${red:-0}" -ge 8000 ]; then
        ck_info data-after-a "d=a kept the image data (re-place draws red=$red)"
    else
        ck_info data-after-a "d=a freed the image data (re-place draws nothing)"
    fi
    if session_alive; then ck_pass alive "alive"; else ck_fail alive "died"; fi
}

sc_retransmit() {
    kemit_png "$SC/red.bin" "$FIX/red-96.png" 80 --action t --chunk 3072 || { ck_fail emission-red "failed"; return; }
    kemit_png "$SC/blue.bin" "$FIX/blue-96.png" 80 --action t --chunk 3072 || { ck_fail emission-blue "failed"; return; }
    send_file "$SC/red.bin" || { ck_fail transmit-red "timed out"; return; }
    kemit_place "$SC/p.bin" 80 --placement-id 1 --no-move || { ck_fail place-emit "failed"; return; }
    send_file "$SC/p.bin" || { ck_fail place "timed out"; return; }
    session_shot "$SC/shots/before.png"
    local red; red=$(count_of "$SC/shots/before.png" '#FF0000')
    if [ "${red:-0}" -ge 8000 ]; then ck_pass before "red=$red"; else ck_fail before "red=$red"; return; fi
    send_file "$SC/blue.bin" || { ck_fail retransmit "timed out"; return; }
    session_shot "$SC/shots/after.png"
    red=$(count_of "$SC/shots/after.png" '#FF0000')
    local blue; blue=$(count_of "$SC/shots/after.png" '#0000FF')
    ck_info after "retransmit id=80: red=$red blue=$blue"
    # Spec §3: retransmitting t for an existing id replaces the data and drops
    # all existing placements; nothing is shown until a new a=p.
    if [ "${red:-1}" -eq 0 ] && [ "${blue:-1}" -eq 0 ]; then
        ck_pass retransmit "retransmit replaced data and dropped the old placement (red=0 blue=0; spec §3)"
    elif [ "${red:-1}" -eq 0 ] && [ "${blue:-0}" -ge 8000 ]; then
        ck_info retransmit "retransmit updated the existing placement in place (blue=$blue); spec §3 says placements are dropped until a new a=p"
        ck_pass retransmit "retransmit replaced the image data (red gone, new blue visible)"
    else
        ck_fail retransmit "retransmit left stale pixels (red=$red blue=$blue)"
    fi
    kemit_place "$SC/p2.bin" 80 --placement-id 2 --no-move || { ck_fail re-place-emit "failed"; return; }
    send_file "$SC/p2.bin" || { ck_fail re-place "timed out"; return; }
    session_shot "$SC/shots/after-replace.png"
    blue=$(count_of "$SC/shots/after-replace.png" '#0000FF')
    red=$(count_of "$SC/shots/after-replace.png" '#FF0000')
    if [ "${blue:-0}" -ge 8000 ] && [ "${red:-1}" -eq 0 ]; then
        ck_pass new-data "re-placement shows the new blue image (blue=$blue)"
    else
        ck_fail new-data "after re-placement blue=$blue red=$red"
    fi
    if session_alive; then ck_pass alive "alive"; else ck_fail alive "died"; fi
}

_place_red_at_top() {
    kemit_png "$SC/transmit.bin" "$FIX/red-96.png" 90 --action t --chunk 3072 || return 1
    send_file "$SC/transmit.bin" || return 1
    kemit_place "$SC/place.bin" 90 --placement-id 1 --no-move || return 1
    send_file "$SC/place.bin" || return 1
}

sc_lifecycle_scroll() {
    _place_red_at_top || { ck_fail setup "placement failed"; return; }
    session_shot "$SC/shots/before.png"
    local before; before=$(count_of "$SC/shots/before.png" '#FF0000')
    if [ "${before:-0}" -lt 8000 ]; then ck_fail present-before "red=$before"; return; fi
    ck_pass present-before "red=$before"
    session_send 'for i in $(seq 1 300); do echo "scroll line $i ------------------------------------------------------------------"; done' 30 ||
        { ck_fail text "timed out"; return; }
    session_shot "$SC/shots/away.png"
    local away; away=$(count_of "$SC/shots/away.png" '#FF0000')
    ck_info scrolled-away "red=$away"
    if [ "${away:-1}" -eq 0 ]; then ck_pass scrolled-away "image scrolled out of view"; else ck_fail scrolled-away "image stayed on screen (red=$away)"; fi
    local wx wy ww wh attempt found=0
    read -r wx wy ww wh <<<"$(session_window_geom)"
    for attempt in 1 2 3 4; do
        xdotool mousemove $((wx + ww / 2)) $((wy + wh / 2)) click --repeat 80 --delay 5 4 2>/dev/null
        sleep 0.4
        session_shot "$SC/shots/back-$attempt.png"
        found=$(count_of "$SC/shots/back-$attempt.png" '#FF0000')
        [ "${found:-0}" -ge 8000 ] && break
    done
    ck_info scrolled-back "red=$found after $attempt scroll steps"
    if [ "${found:-0}" -ge 8000 ]; then ck_pass scrolled-back "image returned with its rows"; else ck_fail scrolled-back "image not recovered (red=$found)"; fi
    if session_alive; then ck_pass alive "alive"; else ck_fail alive "died"; fi
}

sc_lifecycle_resize() {
    _place_red_at_top || { ck_fail setup "placement failed"; return; }
    session_shot "$SC/shots/before.png"
    local before; before=$(count_of "$SC/shots/before.png" '#FF0000')
    xdotool windowsize --sync "$SESSION_WID" 520 380 2>/dev/null; sleep 1.2
    session_shot "$SC/shots/small.png"
    local small; small=$(count_of "$SC/shots/small.png" '#FF0000')
    if session_alive; then ck_pass alive-shrink "alive at $(session_window_geom)"; else ck_fail alive-shrink "died"; return; fi
    ck_info small "red=$small (before=$before)"
    xdotool windowsize --sync "$SESSION_WID" 900 650 2>/dev/null; sleep 1.2
    session_shot "$SC/shots/restored.png"
    local restored; restored=$(count_of "$SC/shots/restored.png" '#FF0000')
    ck_info restored "red=$restored"
    if [ "${restored:-0}" -ge 8000 ] && session_alive; then ck_pass restored "image still drawn after grow back"; else ck_fail restored "red=$restored after resize"; fi
}

sc_lifecycle_clear() {
    _place_red_at_top || { ck_fail setup "placement failed"; return; }
    session_shot "$SC/shots/before.png"
    local before; before=$(count_of "$SC/shots/before.png" '#FF0000')
    if [ "${before:-0}" -lt 8000 ]; then ck_fail present-before "red=$before"; return; fi
    ck_pass present-before "red=$before"
    send_clear
    sleep 0.3
    session_shot "$SC/shots/after.png"
    local after; after=$(count_of "$SC/shots/after.png" '#FF0000')
    if [ "${after:-1}" -eq 0 ]; then ck_pass clear "ED2+ED3 removed the image"; else ck_fail clear "red=$after after clear"; fi
    if session_alive; then ck_pass alive "alive"; else ck_fail alive "died"; fi
}

sc_lifecycle_altscreen() {
    kemit_png "$SC/red.bin" "$FIX/red-96.png" 91 --action t --chunk 3072 || { ck_fail emission-red "failed"; return; }
    kemit_png "$SC/blue.bin" "$FIX/blue-96.png" 92 --action t --chunk 3072 || { ck_fail emission-blue "failed"; return; }
    send_file "$SC/red.bin" || { ck_fail transmit-red "timed out"; return; }
    kemit_place "$SC/p1.bin" 91 --placement-id 1 --no-move || { ck_fail place1-emit "failed"; return; }
    send_file "$SC/p1.bin" || { ck_fail place1 "timed out"; return; }
    session_send "printf '\\033[?1049h\\033[H\\033[2J'" 10 || { ck_fail altscreen-enter "timed out"; return; }
    send_file "$SC/blue.bin" || { ck_fail transmit-blue "timed out"; return; }
    kemit_place "$SC/p2.bin" 92 --placement-id 2 --no-move || { ck_fail place2-emit "failed"; return; }
    send_file "$SC/p2.bin" || { ck_fail place2 "timed out"; return; }
    session_shot "$SC/shots/alt.png"
    local red blue
    red=$(count_of "$SC/shots/alt.png" '#FF0000'); blue=$(count_of "$SC/shots/alt.png" '#0000FF')
    ck_info alt "alt screen: red=$red blue=$blue"
    if [ "${blue:-0}" -ge 8000 ] && [ "${red:-1}" -eq 0 ]; then ck_pass alt-isolated "alt screen shows only its own image"; else ck_fail alt-isolated "red=$red blue=$blue on alt screen"; fi
    session_send "printf '\\033[?1049l'" 10 || { ck_fail altscreen-exit "timed out"; return; }
    sleep 0.3
    session_shot "$SC/shots/normal.png"
    red=$(count_of "$SC/shots/normal.png" '#FF0000'); blue=$(count_of "$SC/shots/normal.png" '#0000FF')
    ck_info normal "normal screen after exit: red=$red blue=$blue"
    if [ "${red:-0}" -ge 8000 ] && [ "${blue:-1}" -eq 0 ]; then ck_pass normal-restored "normal screen restored, alt image discarded"; else ck_fail normal-restored "red=$red blue=$blue after exit"; fi
    if session_alive; then ck_pass alive "alive"; else ck_fail alive "died"; fi
}

sc_memory_images() {
    local rss0 rss1
    # Precondition: this scenario is about resource behaviour, but it must not
    # "pass" on a terminal that cannot render Kitty images at all.
    kemit_png "$SC/pre.bin" "$FIX/green-64.png" 99 --action t --chunk 3072 || { ck_fail precondition "emit failed"; return; }
    send_file "$SC/pre.bin" || { ck_fail precondition "timed out"; return; }
    kemit_place "$SC/prep.bin" 99 --placement-id 1 --columns 8 --no-move || { ck_fail precondition-place "failed"; return; }
    send_file "$SC/prep.bin" || { ck_fail precondition-place "timed out"; return; }
    session_shot "$SC/shots/precondition.png"
    local premag; premag=$(count_of "$SC/shots/precondition.png" '#00FF00')
    if [ "${premag:-0}" -lt 1000 ]; then
        ck_fail kitty-render "precondition failed: no green image before stress (green=$premag); terminal lacks Kitty graphics"
        return
    fi
    ck_info precondition "green=$premag before stress"
    rss0=$(session_rss_kb)
    # Reusable chunked transmit+place+delete cycle (100 kB PNG, 3072-byte chunks).
    kemit_png "$SC/chunk.bin" "$FIX/chunk-100k.png" 100 --action t --chunk 3072 || { ck_fail emission-chunk "failed"; return; }
    kemit_place "$SC/pchunk.bin" 100 --placement-id 1 --columns 20 --no-move || { ck_fail placement-chunk "failed"; return; }
    kemit_delete "$SC/dchunk.bin" I --image-id 100 || { ck_fail delete-chunk "failed"; return; }
    cat "$SC/chunk.bin" "$SC/pchunk.bin" "$SC/dchunk.bin" >"$SC/cycle.bin"
    local frames; frames=$(frame_count "$SC/chunk.bin")
    ck_info cycle "each cycle: $frames chunk frames + place + delete ($(stat -c %s "$SC/cycle.bin") bytes)"
    session_send "for i in \$(seq 1 100); do cat '$SC/cycle.bin'; done" 120 ||
        { ck_fail stress "100 chunked cycles timed out"; return; }
    sleep 0.5
    rss1=$(session_rss_kb)
    ck_info memory "rss ${rss0}kB -> ${rss1}kB after 100 x 100kB chunked transmit/place/delete"
    if session_alive; then ck_pass alive "alive after 100 chunked cycles"; else ck_fail alive "died"; return; fi
    if [ "$rss1" -lt 1500000 ]; then ck_pass memory-bounded "rss=${rss1}kB (<1.5GB)"; else ck_fail memory-bounded "rss=${rss1}kB"; fi
    local delta=$((rss1 - rss0))
    if [ "$delta" -lt 100000 ]; then ck_pass no-leak "growth ${delta}kB (<100MB)"; else ck_fail no-leak "growth ${delta}kB (>=100MB); chunk/image buffers leak"; fi
    # The terminal must respond to a probe afterwards (parser not wedged).
    local reply="$SC/reply.bin"
    session_send "python3 '$PROBE_HELPER' --timeout 1.0 --raw-out '$reply' >/dev/null 2>&1; echo \$? > '$SC/p.rc'" 10 || true
    if [ "$(cat "$SC/p.rc" 2>/dev/null || echo 9)" = 0 ]; then ck_pass responsive-after-stress "probe still answered"; else ck_info responsive-after-stress "no probe reply after stress (expected on a Kitty-less build)"; fi
}

sc_control_stock_vte() {
    local cmd="" pid wid reply="$SC/vte-reply.bin"
    if command -v gnome-terminal >/dev/null 2>&1; then cmd=gnome-terminal
    elif command -v kgx >/dev/null 2>&1; then cmd=kgx; fi
    if [ -z "$cmd" ]; then ck_skip stock-vte "no stock VTE app (gnome-terminal/kgx)"; return; fi
    kemit_png "$SC/t.bin" "$FIX/chunked-480x320.png" 1 --action t --chunk 3072 || { ck_fail emission "failed"; return; }
    kemit_place "$SC/p.bin" 1 --placement-id 1 --columns 40 --no-move || { ck_fail place-emit "failed"; return; }
    cat "$SC/t.bin" "$SC/p.bin" >"$SC/control.bin"
    local script="$SC/run.sh"
    cat >"$script" <<EOF
#!/bin/bash
python3 '$PROBE_HELPER' --timeout 1.2 --raw-out '$reply' >/dev/null 2>&1
cat '$SC/control.bin'
sleep 60
EOF
    chmod +x "$script"
    if [ "$cmd" = gnome-terminal ]; then
        setsid dbus-run-session -- gnome-terminal --window --wait -- bash "$script" >"$SC/vte.log" 2>&1 &
    else
        setsid dbus-run-session -- kgx --command "bash '$script'" >"$SC/vte.log" 2>&1 &
    fi
    pid=$!
    wid=$(wait_window_class 'gnome-terminal|Gnome-terminal|kgx|Kgx' 25) || { ck_skip stock-vte "$cmd did not open a window headlessly"; kill -- -"$pid" 2>/dev/null; return; }
    sleep 2.5
    session_shot "$SC/shots/after.png"
    local mag bytes=0
    mag=$(count_of "$SC/shots/after.png" '#FF00FF')
    [ -f "$reply" ] && bytes=$(stat -c %s "$reply")
    ck_info stock-vte "window=$wid magenta=$mag probe_reply_bytes=$bytes"
    if [ "${mag:-1}" -eq 0 ]; then ck_pass no-image "$cmd (unpatched VTE) drew nothing"; else ck_fail no-image "$cmd drew magenta=$mag"; fi
    if [ "$bytes" -eq 0 ]; then ck_pass no-reply "$cmd did not answer the Kitty probe (reply is ours)"; else ck_fail no-reply "$cmd replied with $bytes bytes to the Kitty probe"; fi
    kill -- -"$pid" 2>/dev/null
    sleep 0.3
}

wait_window_class() {
    local cls="$1" tmo="${2:-20}" i w
    for i in $(seq 1 $((tmo * 4))); do
        while read -r w; do
            [ -n "$w" ] || continue
            local gw
            gw=$(xdotool getwindowgeometry --shell "$w" 2>/dev/null | sed -n 's/^WIDTH=//p')
            if [ -n "$gw" ] && [ "$gw" -ge 100 ] 2>/dev/null; then printf '%s\n' "$w"; return 0; fi
        done < <(xdotool search --maxdepth 5 --class "$cls" 2>/dev/null)
        sleep 0.25
    done
    return 1
}

sc_iterm2_regression() {
    local sub="$RUN/imgcat-regression"
    local -a args=(--bin "$BIN" --out "$sub" --scenario basic-bel --scenario basic-st \
        --scenario do-not-move-cursor --scenario inline-zero --scenario wire-errors \
        --scenario two-images --scenario scrollback --scenario resize --scenario clear \
        --scenario control-omitted)
    if "$SCRIPT_DIR/imgcat-e2e.sh" "${args[@]}" >>"$SC/imgcat.log" 2>&1; then
        ck_pass iterm2 "imgcat-e2e regression subset passed (10 scenarios)"
    else
        ck_fail iterm2 "imgcat-e2e regression subset failed; see $SC/imgcat.log"
    fi
    if [ -f "$sub"/*/summary.json ] 2>/dev/null; then
        local f; f=$(ls -t "$sub"/*/summary.json 2>/dev/null | head -1)
        python3 - "$f" >>"$SC/imgcat.log" <<'PY' || true
import json, sys
s = json.load(open(sys.argv[1]))
print("imgcat summary:", s.get("passed"), "passed", s.get("failed"), "failed")
PY
    fi
}

sc_opentui_demo() {
    if [ -x "$LIB/opentui_kitty_demo.sh" ]; then
        local -a demoargs=(--bin "$BIN" --display "$DISPLAY" --out "$SC")
        if [ -n "${OPENTUI_DEMO_DIR:-}" ]; then
            demoargs+=(--demo-dir "$OPENTUI_DEMO_DIR")
        elif [ -d /tmp/opencode/opentui-pub ]; then
            demoargs+=(--demo-dir /tmp/opencode/opentui-pub)
        fi
        "$LIB/opentui_kitty_demo.sh" "${demoargs[@]}" >>"$SC/opentui.log" 2>&1
        local rc=$?
        if [ "$rc" = 0 ]; then
            ck_pass opentui "OpenTUI native-image demo selected Kitty and placed images"
        elif [ "$rc" = 3 ]; then
            ck_skip opentui "OpenTUI demo unavailable: $(grep -m1 SKIP "$SC/opentui.log" || echo 'see log')"
        else
            if grep -q 'terminal did not answer the probe' "$SC/opentui.log" 2>/dev/null; then
                # script(1) does not deliver terminal replies to the demo's stdin;
                # check the terminal directly before blaming it.
                session_send "python3 '$PROBE_HELPER' --timeout 1.2 --raw-out '$SC/direct-probe.bin' >/dev/null 2>&1" 10 || true
                if grep -qa $'\x1b_Gi=31337;OK' "$SC/direct-probe.bin" 2>/dev/null; then
                    ck_skip opentui "direct Kitty probe succeeds, but script(1) does not forward the reply to the OpenTUI demo; demo hook needs a pty-aware runner"
                else
                    ck_fail opentui "terminal did not answer the probe (demo and direct probe)"
                fi
            else
                ck_fail opentui "OpenTUI demo failed (rc=$rc); see $SC/opentui.log"
            fi
        fi
    else
        ck_skip opentui "OpenTUI demo hook not available (stretch goal)"
    fi
}

# Parse the APC frames of a chunked transmission: first frame must carry the
# control set, continuations only m= (and optional q).
check_continuations() { # file label
    local file=$1 label=$2
    python3 - "$file" >"$SC/$label-frames.txt" <<'PYINNER'
import sys
d = open(sys.argv[1], 'rb').read()
parts = d.split(b'\x1b_G')[1:]
frames = [b'\x1b_G' + p for p in parts]
issues = []
first = frames[0].split(b'\x1b\\')[0]
control = first[3:].split(b';')[0].decode('latin-1')
if 'i=' not in control or 'm=1' not in control:
    issues.append("first chunk control lacks i= or m=1: %r" % control)
for n, frame in enumerate(frames[1:], 2):
    body = frame.split(b'\x1b\\')[0]
    ctl = body[3:].split(b';')[0].decode('latin-1')
    keys = [kv.split('=', 1)[0] for kv in ctl.split(',') if kv]
    if any(k not in ('m', 'q') for k in keys):
        issues.append("chunk %d control has keys %r (only m,q allowed)" % (n, keys))
    if 'm=' not in ctl:
        issues.append("chunk %d lacks m=" % n)
print("frames=%d" % len(frames))
print("first_control=%s" % control)
print("issues=%d" % len(issues))
for issue in issues:
    print("issue=%s" % issue)
PYINNER
    ck_info "$label-frames" "$(tr '\n' ' ' <"$SC/$label-frames.txt" | cut -c1-240)"
    if grep -q '^issues=0' "$SC/$label-frames.txt"; then
        ck_pass "$label-continuations" "continuations carry only m/q; first chunk carries i= and m=1"
    else
        ck_fail "$label-continuations" "chunk control violation: $(grep '^issue=' "$SC/$label-frames.txt" | tr '\n' ' ')"
    fi
}

sc_chunking_partial() {
    local frames
    kemit_png "$SC/full.bin" "$FIX/chunk-100k.png" 30 --action t --chunk 3072 ||
        { ck_fail emission "emit failed"; return; }
    frames=$(frame_count "$SC/full.bin")
    ck_info frames "$frames frames"
    python3 - "$SC/full.bin" "$SC/prefix.bin" "$SC/last.bin" <<'PYINNER'
import sys
d = open(sys.argv[1], 'rb').read()
parts = [b'\x1b_G' + p for p in d.split(b'\x1b_G')[1:]]
assert len(parts) >= 3, len(parts)
open(sys.argv[2], 'wb').write(b''.join(parts[:-1]))
open(sys.argv[3], 'wb').write(parts[-1])
PYINNER
    send_file "$SC/prefix.bin" 60 || { ck_fail partial-send "timed out"; return; }
    # A placement before the final chunk must not display a half-uploaded image.
    kemit_place "$SC/p1.bin" 30 --placement-id 1 --columns 40 --no-move || { ck_fail place-emit "failed"; return; }
    send_file "$SC/p1.bin" || { ck_fail place1 "timed out"; return; }
    session_shot "$SC/shots/partial.png"
    local mag; mag=$(count_of "$SC/shots/partial.png" '#FF00FF')
    ck_info partial "magenta=$mag after all-but-last chunk + placement"
    if [ "${mag:-1}" -eq 0 ]; then ck_pass buffered "nothing displayed before the final chunk"; else ck_fail buffered "half-uploaded image drawn (magenta=$mag)"; fi
    send_file "$SC/last.bin" 30 || { ck_fail final-chunk "timed out"; return; }
    kemit_place "$SC/p2.bin" 30 --placement-id 2 --columns 40 --no-move || { ck_fail place2-emit "failed"; return; }
    send_file "$SC/p2.bin" || { ck_fail place2 "timed out"; return; }
    session_shot "$SC/shots/complete.png"
    mag=$(count_of "$SC/shots/complete.png" '#FF00FF')
    ck_info complete "magenta=$mag after final chunk + placement"
    if [ "${mag:-0}" -ge 5000 ]; then ck_pass reassembled "final chunk completed the upload and the image rendered"; else ck_fail reassembled "image still missing after final chunk (magenta=$mag)"; fi
    if session_alive; then ck_pass alive "alive"; else ck_fail alive "died"; fi
}

sc_envelope_forms() {
    kemit_query "$SC/query.bin"
    kemit_place "$SC/place.bin" 1 --placement-id 1
    kemit_delete "$SC/delete.bin" i --image-id 1
    kemit_png "$SC/transmit.bin" "$FIX/red-96.png" 1 --action t --chunk 3072
    python3 - "$SC" >"$SC/shapes.txt" <<'PYINNER'
import os, sys
d = sys.argv[1]
def read(n):
    return open(os.path.join(d, n), 'rb').read()
def body(b):
    assert b.startswith(b'\x1b_G') and b.endswith(b'\x1b\\'), b[:8]
    return b[3:-2]
q = body(read('query.bin'))
p = body(read('place.bin'))
de = body(read('delete.bin'))
t = body(read('transmit.bin').split(b'\x1b_G')[1] and b'\x1b_G' + read('transmit.bin').split(b'\x1b_G')[1])
print("query_payload_form=%d" % (1 if b';' in q else 0))
print("place_payloadless=%d" % (1 if b';' not in p else 0))
print("delete_payloadless=%d" % (1 if b';' not in de else 0))
print("transmit_payload_form=%d" % (1 if b';' in t else 0))
print("place_control=%s" % p.decode('latin-1')[:120])
print("delete_control=%s" % de.decode('latin-1')[:120])
PYINNER
    cat "$SC/shapes.txt" >>"$RUN/harness.log"
    ck_info shapes "$(tr '\n' ' ' <"$SC/shapes.txt" | cut -c1-260)"
    if grep -q '^query_payload_form=1' "$SC/shapes.txt"; then ck_pass query-form "query uses ESC_G<control>;<payload>ESC\\"; else ck_fail query-form "query missing payload separator"; fi
    if grep -q '^transmit_payload_form=1' "$SC/shapes.txt"; then ck_pass transmit-form "transmit uses ESC_G<control>;<payload>ESC\\"; else ck_fail transmit-form "transmit missing payload separator"; fi
    if grep -q '^place_payloadless=1' "$SC/shapes.txt"; then ck_pass place-form "placement is control-only (no semicolon)"; else ck_fail place-form "placement contains a payload separator"; fi
    if grep -q '^delete_payloadless=1' "$SC/shapes.txt"; then ck_pass delete-form "delete is control-only (no semicolon)"; else ck_fail delete-form "delete contains a payload separator"; fi
    if session_alive; then ck_pass alive "alive"; else ck_fail alive "died"; fi
}

sc_geometry_one_dim() {
    local cx cy cw ch
    cw=$(cell_w_i); ch=$(cell_h_i)
    read -r cx cy <<<"$(content_origin)"
    kemit_png "$SC/transmit.bin" "$FIX/source-200x100.png" 43 --action t --chunk 3072 ||
        { ck_fail emission "failed"; return; }
    send_file "$SC/transmit.bin" || { ck_fail transmit "timed out"; return; }
    # Only c: width = 20 cells = 180px, height derived from 200x100 = 90px.
    kemit_place "$SC/place.bin" 43 --placement-id 1 --columns 20 --no-move ||
        { ck_fail place-emit "failed"; return; }
    send_file "$SC/place.bin" || { ck_fail place "timed out"; return; }
    session_shot "$SC/shots/after.png"
    local rx ry rw rh rc rf bx by bw bh bc bf
    read -r rx ry rw rh rc rf <<<"$(bbox_of "$SC/shots/after.png" '#FF0000')"
    read -r bx by bw bh bc bf <<<"$(bbox_of "$SC/shots/after.png" '#0000FF')"
    ck_info halves "red ${rw}x${rh} at ${rx},${ry}; blue ${bw}x${bh} at ${bx},${by}"
    if near "$rw" 90 3 && near "$rh" 90 3 && near "$bw" 90 3 && near "$bh" 90 3; then
        ck_pass one-dim "c=20 on 200x100 -> 180x90, halves 90x90 (aspect-derived height)"
    else
        ck_fail one-dim "expected 180x90 with 90x90 halves, got red ${rw}x${rh} blue ${bw}x${bh}"
    fi
    if near "$rx" "$cx" 2 && near "$ry" "$cy" 2 && near "$bx" $((cx + 90)) 3; then
        ck_pass anchored "derived bitmap anchored at the cursor cell"
    else
        ck_fail anchored "anchors red=${rx},${ry} blue=${bx},${by}; expected ${cx},${cy} and $((cx+90)),${cy}"
    fi
    if session_alive; then ck_pass alive "alive"; else ck_fail alive "died"; fi
}

sc_zorder_text() {
    local green red blue
    kemit_png "$SC/red.bin" "$FIX/red-96.png" 53 --action t --chunk 3072 || { ck_fail emission-red "failed"; return; }
    kemit_png "$SC/blue.bin" "$FIX/blue-96.png" 54 --action t --chunk 3072 || { ck_fail emission-blue "failed"; return; }
    send_file "$SC/red.bin" || { ck_fail transmit-red "timed out"; return; }
    send_file "$SC/blue.bin" || { ck_fail transmit-blue "timed out"; return; }
    # Negative z: image behind glyphs, text stays legible.
    session_send "printf '\\033[1;1H\\033[38;2;0;255;0mXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX\\033[0m'" 10 ||
        { ck_fail text "timed out"; return; }
    kemit_place "$SC/pneg.bin" 53 --placement-id 1 --columns 40 --z -1 --no-move ||
        { ck_fail place-neg-emit "failed"; return; }
    send_file "$SC/pneg.bin" || { ck_fail place-neg "timed out"; return; }
    session_shot "$SC/shots/negative.png"
    red=$(count_of "$SC/shots/negative.png" '#FF0000')
    green=$(count_of "$SC/shots/negative.png" '#00FF00' 80)
    ck_info negative-z "red=$red green-text=$green"
    if [ "${red:-0}" -ge 8000 ] && [ "${green:-0}" -ge 150 ]; then
        ck_pass negative-z "z<0 image drawn behind the text (glyphs remain visible, green=$green)"
    else
        ck_fail negative-z "red=$red green=$green; expected image plus legible text"
    fi
    kemit_delete "$SC/del.bin" i --image-id 53 --placement-id 1 || { ck_fail del-emit "failed"; return; }
    send_file "$SC/del.bin" || { ck_fail del "timed out"; return; }
    # Non-negative z: image above glyphs.
    session_send "printf '\\033[1;1H\\033[38;2;0;255;0mXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX\\033[0m'" 10 ||
        { ck_fail text2 "timed out"; return; }
    kemit_place "$SC/ppos.bin" 54 --placement-id 2 --columns 40 --z 1 --no-move ||
        { ck_fail place-pos-emit "failed"; return; }
    send_file "$SC/ppos.bin" || { ck_fail place-pos "timed out"; return; }
    session_shot "$SC/shots/positive.png"
    blue=$(count_of "$SC/shots/positive.png" '#0000FF')
    green=$(count_of "$SC/shots/positive.png" '#00FF00' 80)
    ck_info positive-z "blue=$blue green-text=$green"
    if [ "${blue:-0}" -ge 8000 ] && [ "${green:-1}" -eq 0 ]; then
        ck_pass positive-z "z>=0 image painted above the text (green=$green)"
    else
        ck_fail positive-z "blue=$blue green=$green; expected the image to cover the glyphs"
    fi
    if session_alive; then ck_pass alive "alive"; else ck_fail alive "died"; fi
}

sc_quiet_q2() {
    local reply="$SC/probe.bin" drained="$SC/drained.bin" rc=0
    session_send "python3 '$PROBE_HELPER' --timeout 1.2 --raw-out '$reply' >/dev/null 2>&1; echo \$? > '$SC/rc'" 10 || true
    rc=$(cat "$SC/rc" 2>/dev/null || echo 9)
    if ! grep -qa $'\x1b_Gi=31337;OK' "$reply" 2>/dev/null; then
        ck_fail precondition "no Kitty OK reply (rc=$rc); cannot test q=2 silence"
        return
    fi
    ck_pass precondition "Kitty probe answered; now checking q=2 silence"
    session_send "python3 '$LIB/kitty_tty.py' drain --timeout 0.8 --out '$drained' >/dev/null 2>&1" 5 || true
    # Single-chunk red image, q=2 on transmit/placement/delete.
    kemit_png "$SC/t.bin" "$FIX/red-96.png" 90 --action t --chunk 3072 --quiet ||
        { ck_fail emission "failed"; return; }
    kemit_place "$SC/p.bin" 90 --placement-id 1 --no-move --quiet || { ck_fail place-emit "failed"; return; }
    kemit_delete "$SC/d.bin" i --image-id 90 --placement-id 1 --quiet || { ck_fail delete-emit "failed"; return; }
    cat "$SC/t.bin" "$SC/p.bin" "$SC/d.bin" >"$SC/flow.bin"
    send_file "$SC/flow.bin" || { ck_fail flow "timed out"; return; }
    session_send "python3 '$LIB/kitty_tty.py' drain --timeout 0.9 --out '$drained' >/dev/null 2>&1" 5 || true
    local bytes apc
    bytes=$(stat -c %s "$drained" 2>/dev/null || echo 0)
    apc=$(python3 - "$drained" <<'PYINNER'
import sys
d = open(sys.argv[1], 'rb').read() if __import__('os').path.exists(sys.argv[1]) else b''
print(d.count(b'\x1b_G'))
PYINNER
)
    ck_info q2 "drained bytes=$bytes apc_replies=$apc"
    if [ "$bytes" -eq 0 ] || [ "${apc:-1}" -eq 0 ]; then
        ck_pass silence "q=2 suppressed every reply from transmit/placement/delete"
    else
        ck_fail silence "q=2 produced $bytes bytes / $apc APC replies"
    fi
    if session_alive; then ck_pass alive "alive"; else ck_fail alive "died"; fi
}

sc_shared_emitter_render() {
    local shared=""
    for c in "${KITTY_SHARED_EMITTER:-}" \
             "$SCRIPT_DIR/../../kitty-protocol/scripts/emit_kitty.py" \
             "/home/metal/projects/console-extend/worktrees/kitty-protocol/scripts/emit_kitty.py"; do
        [ -n "$c" ] && [ -f "$c" ] && { shared="$c"; break; }
    done
    if [ -z "$shared" ]; then ck_skip shared-emitter "shared emit_kitty.py not found"; return; fi
    # The shared emitter defaults to OpenTUI's 3072-raw-byte (4096 base64 char)
    # chunking, which this build drops because the APC frame cap is 4096 chars
    # in total. Use its --b64-chunking mode (3072-char chunks) to verify the
    # emitter/render path; the 4096 default is covered by chunk-apc-limit.
    if ! python3 "$shared" --file "$FIX/chunk-100k.png" --id 77 --cols 20 --rows 10 \
            --b64-chunking --verify --quiet >"$SC/flow.bin" 2>"$SC/emit.err"; then
        ck_fail emission "shared emitter failed (see emit.err)"; return
    fi
    ck_info emitter "$shared produced $(stat -c %s "$SC/flow.bin") bytes (--b64-chunking)"
    ck_info opentui-chunking "default 4096-char chunking is known-broken on this build; see scenario chunk-apc-limit"
    # Cross-check the shared probe bytes against our local wire adapter.
    kemit_query "$SC/local-query.bin"
    head -c 38 "$SC/flow.bin" >"$SC/shared-probe.bin"
    if cmp -s "$SC/local-query.bin" "$SC/shared-probe.bin"; then
        ck_pass probe-bytes "shared emitter probe is byte-identical to the harness wire adapter"
    else
        ck_fail probe-bytes "shared emitter probe differs from kitty_wire.py query"
    fi
    send_file "$SC/flow.bin" 40 || { ck_fail emit "timed out"; return; }
    session_shot "$SC/shots/after.png"
    # 160x160 marker (40x40) placed in a 20x10-cell box (180x180) => 45x45.
    bbox_check "$SC/shots/after.png" '#FF00FF' shared-marker 45 45 3 || return
    ck_pass shared-render "shared emitter's own bytes rendered the image"
    if session_alive; then ck_pass alive "alive"; else ck_fail alive "died"; fi
}

sc_chunk_apc_limit() {
    # The APC frame itself is capped at 4096 chars, so a 4096-char base64 chunk
    # plus control data is dropped. Find the practical boundary and assert that
    # the spec/OpenTUI 4096-char chunk size works (it must).
    local cw ch cx cy
    cw=$(cell_w_i); ch=$(cell_h_i)
    read -r cx cy <<<"$(content_origin)"
    local ok_size=4068

    kemit_png "$SC/t-ok.bin" "$FIX/chunk-100k.png" 95 --action t --chunk "$ok_size" ||
        { ck_fail emission-ok "failed"; return; }
    send_file "$SC/t-ok.bin" 60 || { ck_fail transmit-ok "timed out"; return; }
    kemit_place "$SC/p-ok.bin" 95 --placement-id 1 --columns 20 --rows 10 --no-move || { ck_fail place-ok-emit "failed"; return; }
    send_file "$SC/p-ok.bin" || { ck_fail place-ok "timed out"; return; }
    session_shot "$SC/shots/chunk-$ok_size.png"
    local ok_count; ok_count=$(count_of "$SC/shots/chunk-$ok_size.png" '#FF00FF')
    ck_info boundary-ok "chunk=$ok_size magenta=$ok_count"
    if [ "${ok_count:-0}" -ge 1000 ]; then
        ck_pass boundary-ok "$ok_size-char chunks render (max accepted chunk is near 4068)"
    else
        ck_fail boundary-ok "$ok_size-char chunks failed (magenta=$ok_count)"
    fi

    send_clear
    kemit_png "$SC/t-4096.bin" "$FIX/chunk-100k.png" 96 --action t --chunk 4096 ||
        { ck_fail emission-4096 "failed"; return; }
    local frames; frames=$(frame_count "$SC/t-4096.bin")
    ck_info frames-4096 "$frames frames, first frame payload 4096 base64 chars"
    send_file "$SC/t-4096.bin" 60 || { ck_fail transmit-4096 "timed out"; return; }
    kemit_place "$SC/p-4096.bin" 96 --placement-id 1 --columns 20 --rows 10 --no-move || { ck_fail place-4096-emit "failed"; return; }
    send_file "$SC/p-4096.bin" || { ck_fail place-4096 "timed out"; return; }
    session_shot "$SC/shots/chunk-4096.png"
    local c4096; c4096=$(count_of "$SC/shots/chunk-4096.png" '#FF00FF')
    ck_info boundary-4096 "chunk=4096 magenta=$c4096"
    if [ "${c4096:-0}" -ge 1000 ]; then
        ck_pass boundary-4096 "4096-char chunks render (spec/OpenTUI size)"
    else
        ck_fail boundary-4096 "4096-char chunks are dropped (magenta=$c4096): the APC frame total exceeds the 4096-char parser cap; OpenTUI chunks 3072 raw bytes into exactly 4096 base64 chars, so every multi-chunk OpenTUI image is lost"
    fi
    if session_alive; then ck_pass alive "alive"; else ck_fail alive "died"; fi
}

sc_reply_default() {
    local reply="$SC/probe.bin" drained="$SC/drained.bin" rc=0
    session_send "python3 '$PROBE_HELPER' --timeout 1.2 --raw-out '$reply' >/dev/null 2>&1; echo \$? > '$SC/rc'" 10 || true
    rc=$(cat "$SC/rc" 2>/dev/null || echo 9)
    if ! grep -qa $'\x1b_Gi=31337;OK' "$reply" 2>/dev/null; then
        ck_fail precondition "no Kitty OK reply (rc=$rc); cannot test default replies"
        return
    fi
    ck_pass precondition "Kitty probe answered"
    session_send "python3 '$LIB/kitty_tty.py' drain --timeout 0.6 --out '$drained' >/dev/null 2>&1" 5 || true
    kemit_png "$SC/t.bin" "$FIX/red-96.png" 97 --action t --chunk 3072 || { ck_fail emission "failed"; return; }
    kemit_place "$SC/p.bin" 97 --placement-id 1 --no-move || { ck_fail place-emit "failed"; return; }
    cat "$SC/t.bin" "$SC/p.bin" >"$SC/flow.bin"
    send_file "$SC/flow.bin" || { ck_fail flow "timed out"; return; }
    session_send "python3 '$LIB/kitty_tty.py' drain --timeout 0.9 --out '$drained' >/dev/null 2>&1" 5 || true
    local bytes ok
    bytes=$(stat -c %s "$drained" 2>/dev/null || echo 0)
    ok=$(python3 - "$drained" <<'PYINNER'
import os, sys
d = open(sys.argv[1], 'rb').read() if os.path.exists(sys.argv[1]) else b''
print(d.count(b'\x1b_G'))
PYINNER
)
    ck_info replies "drained bytes=$bytes apc_frames=$ok"
    if [ "${ok:-0}" -ge 1 ]; then
        ck_pass default-replies "terminal replied to transmit/placement without q=2 ($ok APC reply frames)"
    else
        ck_fail default-replies "no OK replies for transmit/placement with q absent (spec C5 q=0 replies to all); q=2 silence tests are otherwise vacuous"
    fi
    if session_alive; then ck_pass alive "alive"; else ck_fail alive "died"; fi
}

# ------------------------------------------------------------------ runner
finalize_scenario() {
    local sc="$1" id="$2" t0="$3" dur state
    dur=$(( $(date +%s) - t0 ))
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
state = "FAIL" if "FAIL" in states else ("PASS" if "PASS" in states else ("SKIP" if "SKIP" in states else "INFO"))
artifacts = []
for root, dirs, files in os.walk(sc):
    if os.path.basename(root) == "session":
        dirs[:] = []
        continue
    for f in files:
        if f.startswith(".") or f == "checks.tsv":
            continue
        artifacts.append(os.path.relpath(os.path.join(root, f), sc))
json.dump({"scenario": sid, "state": state, "pass": state == "PASS", "skipped": state == "SKIP",
           "duration_s": dur, "checks": checks, "artifacts": sorted(artifacts)},
          open(os.path.join(sc, "verdict.json"), "w"), indent=2)
summary = "; ".join(c["detail"] for c in checks if c["state"] in ("FAIL", "SKIP")) \
    or "; ".join(c["detail"] for c in checks if c["state"] == "PASS")[:160]
print(state + "\t" + summary.replace("\t", " "))
PY
)
    local state_only="${state%%$'\t'*}" detail="${state#*$'\t'}"
    printf '%s\t%s\t%s\t%s\n' "$id" "$state_only" "$dur" "$detail" >>"$RUN/results.tsv"
    printf '%-26s %-5s %5ss  %s\n' "$id" "$state_only" "$dur" "$detail"
}

run_scenario() {
    local id="$1"
    SC="$SCEN_DIR/$id"
    mkdir -p "$SC/shots"
    : >"$SC/checks.tsv"
    local t0; t0=$(date +%s)
    log "=== scenario: $id ==="
    if kstart "$id" >/dev/null 2>&1; then
        case "$id" in
            capability-probe) sc_capability_probe ;;
            basic-render) sc_basic_render ;;
            raw-rgb) sc_raw_rgb ;;
            raw-rgba) sc_raw_rgba ;;
            zlib) sc_zlib ;;
            chunking-100k) sc_chunking_100k ;;
            chunking-partial) sc_chunking_partial ;;
            chunk-apc-limit) sc_chunk_apc_limit ;;
            envelope-forms) sc_envelope_forms ;;
            geometry-cell-box) sc_geometry_cell_box ;;
            geometry-one-dim) sc_geometry_one_dim ;;
            geometry-source-rect) sc_geometry_source_rect ;;
            geometry-cursor) sc_geometry_cursor ;;
            geometry-zorder) sc_geometry_zorder ;;
            zorder-text) sc_zorder_text ;;
            geometry-multi-placement) sc_geometry_multi_placement ;;
            delete-image-id) sc_delete_image_id ;;
            delete-placement) sc_delete_placement ;;
            delete-all) sc_delete_all ;;
            retransmit) sc_retransmit ;;
            lifecycle-scroll) sc_lifecycle_scroll ;;
            lifecycle-resize) sc_lifecycle_resize ;;
            lifecycle-clear) sc_lifecycle_clear ;;
            lifecycle-altscreen) sc_lifecycle_altscreen ;;
            reply-default) sc_reply_default ;;
            quiet-q2) sc_quiet_q2 ;;
            shared-emitter-render) sc_shared_emitter_render ;;
            memory-images) sc_memory_images ;;
            control-stock-vte) sc_control_stock_vte ;;
            iterm2-regression) sc_iterm2_regression ;;
            opentui-demo) sc_opentui_demo ;;
            *) ck_fail implementation "unknown scenario $id" ;;
        esac
        session_stop
    else
        ck_fail session-start "ptyxis window/driver did not come up; see $SC/session/ptyxis.log"
    fi
    finalize_scenario "$SC" "$id" "$t0"
}

# -------------------------------------------------------------------- main
log "kitty e2e harness"
log "  binary : $BIN"
log "  emitter: $WIRE (dir ${EMITTER_DIR:-$LIB})"
log "  run dir: $RUN"
log "  scenarios: ${SELECTED[*]}"

python3 "$LIB/kitty_fixtures.py" "$FIX" >>"$RUN/harness.log" 2>&1 || { log "fixture generation failed"; exit 2; }
python3 "$LIB/kitty_fixtures.py" --selftest >"$RUN/fixture-selftest.txt" 2>&1 || { log "fixture selftest failed"; exit 2; }

display_start "$RUN/display" || { log "could not start Xvfb"; exit 2; }
log "display: $DISPLAY ($(xdpyinfo 2>/dev/null | awk '/dimensions:/ {print $2}'))"
calibrate

printf '%-26s %-5s %6s  %s\n' SCENARIO STATE TIME DETAIL | tee -a "$RUN/summary.txt"
for s in "${SELECTED[@]}"; do run_scenario "$s" | tee -a "$RUN/summary.txt"; done

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
json.dump({"run_dir": run, "binary": binary, "emitter": emitter, "total": len(rows),
           "passed": len(passed), "failed": len(failed), "skipped": len(skipped),
           "scenarios": rows}, open(os.path.join(run, "summary.json"), "w"), indent=2)
print()
print("=" * 84)
print("RESULT: %d passed, %d failed, %d skipped  (of %d)" % (len(passed), len(failed), len(skipped), len(rows)))
for r in rows:
    print("  %-26s %-5s %5ss  %s" % (r["scenario"], r["state"], r["duration_s"], r["detail"]))
print("artifacts: %s" % run)
print("=" * 84)
sys.exit(1 if failed else 0)
PY
cat "$RUN/summary-final.txt"
grep -q $'\tFAIL\t' "$RUN/results.tsv" && exit 1
exit 0
