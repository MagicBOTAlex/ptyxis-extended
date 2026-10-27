#!/bin/bash
# opentui_kitty_demo.sh - optional Kitty-graphics check using OpenTUI's own demo.
#
# Runs @opentui/core's native image demo inside a target Ptyxis/VTE window on an
# X display, lets the real terminal answer (or ignore) OpenTUI's Kitty graphics
# probe (`ESC _ G i=31337,s=1,v=1,a=q,t=d,f=24;AAAA ST`), records everything the
# demo writes to the tty with `script`, screenshots the window, and reports
# whether the Kitty path was selected (`_Ga=t` transmit + `_Ga=p` placement) or
# OpenTUI fell back to Unicode blocks.
#
# Usage:
#   scripts/lib/opentui_kitty_demo.sh [--bin PATH] [--display :N]
#                                     [--demo-dir DIR] [--out DIR] [--timeout SEC]
#
#   --bin       ptyxis binary (default: $IMGCAT_BIN or the harness baseline)
#   --display   existing X display; if omitted a private Xvfb is started
#   --demo-dir  prepared demo dir (default: $OPENTUI_DEMO_DIR, else prepared
#               under <out>/work from $OPENTUI_CHECKOUT with @opentui/core
#               $OPENTUI_CORE_VERSION, default 0.7.0)
#   --out       artifact dir (default /tmp/opencode/opentui-kitty-demo)
#   --timeout   seconds to wait for the demo transcript (default 8)
#
# Exit status: 0 PASS (query + transmit + placement), 1 FAIL (terminal did not
# answer, demo failed, or no Kitty traffic), 2 setup/usage error, 3 SKIP (bun,
# script(1), or demo sources unavailable).
#
# Artifacts: <out>/<run-id>/{verdict.json,summary.txt,demo.typescript,
#            screenshot.png,ptyxis.log}. See scripts/opentui-kitty-findings.md.
#
# This hook is deliberately optional: it exercises the *client* path of a real
# terminal and does not replace the OSC 1337 pixel assertions in imgcat-e2e.sh.

set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=session.sh
. "$SCRIPT_DIR/session.sh"

BIN="${IMGCAT_BIN:-$IMGCAT_BASELINE_BIN}"
DISPLAY_OPT="${DISPLAY:-}"
DEMO_DIR="${OPENTUI_DEMO_DIR:-}"
OUTROOT="${OPENTUI_KITTY_DEMO_OUT:-/tmp/opencode/opentui-kitty-demo}"
TIMEOUT=8
CHECKOUT="${OPENTUI_CHECKOUT:-/home/metal/projects/console-extend/opentui}"
CORE_VERSION="${OPENTUI_CORE_VERSION:-0.7.0}"
BUN="${BUN:-/home/metal/.bun/bin/bun}"
STARTED_DISPLAY=0

while [ $# -gt 0 ]; do
    case "$1" in
        --bin) BIN="$2"; shift 2 ;;
        --display) DISPLAY_OPT="$2"; shift 2 ;;
        --demo-dir) DEMO_DIR="$2"; shift 2 ;;
        --out) OUTROOT="$2"; shift 2 ;;
        --timeout) TIMEOUT="$2"; shift 2 ;;
        -h|--help) sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"
OUT="$OUTROOT/$RUN_ID"
mkdir -p "$OUT"
SUMMARY="$OUT/summary.txt"
TS="$OUT/demo.typescript"
VERDICT="$OUT/verdict.json"
: >"$SUMMARY"

log() { printf '%s\n' "$*" | tee -a "$SUMMARY"; }
finish() {
    session_stop 2>/dev/null
    # script(1) runs in its own session; stop it by its unique transcript path
    # so a detached demo cannot outlive the harness run.
    [ -n "${TS:-}" ] && pkill -TERM -f -- "$TS" 2>/dev/null
    if [ "$STARTED_DISPLAY" = 1 ]; then display_stop 2>/dev/null; fi
}

need() { command -v "$1" >/dev/null 2>&1; }

if [ ! -x "$BIN" ]; then echo "error: ptyxis binary not executable: $BIN" >&2; exit 2; fi
if ! need script; then log "SKIP: script(1) not installed"; exit 3; fi
if [ ! -x "$BUN" ]; then log "SKIP: bun not found at $BUN"; exit 3; fi

# ---------------------------------------------------------------- demo workdir
if [ -n "$DEMO_DIR" ] && [ -f "$DEMO_DIR/src/native-image-demo.ts" ] &&
   [ -d "$DEMO_DIR/node_modules/@opentui/core" ]; then
    WORK="$DEMO_DIR"
else
    WORK="$OUT/work"
    if [ ! -f "$CHECKOUT/packages/examples/src/native-image-demo.ts" ]; then
        log "SKIP: no demo sources (set OPENTUI_CHECKOUT or --demo-dir)"
        exit 3
    fi
    log "preparing demo workdir in $WORK (@opentui/core@$CORE_VERSION)"
    mkdir -p "$WORK/src/lib" "$WORK/src/assets"
    cp "$CHECKOUT/packages/examples/src/native-image-demo.ts" "$WORK/src/"
    cp "$CHECKOUT/packages/examples/src/lib/standalone-keys.ts" "$WORK/src/lib/"
    cp "$CHECKOUT/packages/examples/src/assets/"{image-demo.gif,image-demo.png,dragon.jpg,image-demo.webp} \
        "$WORK/src/assets/"
    cat >"$WORK/package.json" <<EOF
{"name":"opentui-kitty-demo","private":true,"type":"module","dependencies":{"@opentui/core":"$CORE_VERSION"}}
EOF
    if ! (cd "$WORK" && "$BUN" install >"$OUT/bun-install.log" 2>&1); then
        log "SKIP: bun install failed (see bun-install.log)"
        exit 3
    fi
fi

# ---------------------------------------------------------------- X display
if [ -z "$DISPLAY_OPT" ]; then
    if ! display_start "$OUT/display" 2>>"$SUMMARY"; then
        log "error: could not start Xvfb"
        exit 2
    fi
    STARTED_DISPLAY=1
else
    export DISPLAY="$DISPLAY_OPT"
fi
trap finish EXIT

log "bin=$BIN display=$DISPLAY demo=$WORK"

if ! session_start "$BIN" "$OUT" >/dev/null 2>>"$SUMMARY"; then
    log "FAIL: ptyxis session did not start"
    python3 - "$VERDICT" "$BIN" "$DISPLAY" <<'PY'
import json, sys
json.dump({"verdict": "FAIL", "reason": "ptyxis session did not start",
           "bin": sys.argv[2], "display": sys.argv[3]}, open(sys.argv[1], "w"), indent=2)
PY
    exit 1
fi

# Run the demo under script(1) so the terminal's replies still travel through
# the pty while every byte the demo writes is recorded in the transcript.
# script's stdout and stdin must stay on the tty: that is how the query reaches
# the terminal and how the terminal's reply gets back to the demo. Only the
# demo's stderr is discarded.
DEMO_CMD="cd '$WORK' && env -u TERM_PROGRAM -u KITTY_WINDOW_ID TERM=xterm-256color \
setsid script -q -f -e -c '$BUN src/native-image-demo.ts' '$TS' 2>/dev/null &"

session_send "$DEMO_CMD" 10 >/dev/null 2>>"$SUMMARY" || true

# Wait for the transcript to stop growing (demo settles after first paint).
prev=-1 stable=0 waited=0
while [ "$waited" -lt $((TIMEOUT * 10)) ]; do
    sleep 0.1
    waited=$((waited + 1))
    size=0
    [ -f "$TS" ] && size=$(stat -c %s "$TS" 2>/dev/null || echo 0)
    if [ "$size" -gt 0 ] && [ "$size" = "$prev" ]; then
        stable=$((stable + 1))
        [ "$stable" -ge 8 ] && break
    else
        stable=0
    fi
    prev=$size
done

session_shot "$OUT/screenshot.png" 8 >/dev/null 2>&1 || log "warn: screenshot failed"
session_stop 2>/dev/null

if [ ! -s "$TS" ]; then
    log "FAIL: demo produced no transcript"
    python3 - "$VERDICT" "$BIN" "$DISPLAY" <<'PY'
import json, sys
json.dump({"verdict": "FAIL", "reason": "demo produced no transcript",
           "bin": sys.argv[2], "display": sys.argv[3]}, open(sys.argv[1], "w"), indent=2)
PY
    exit 1
fi

# ---------------------------------------------------------------- analysis
python3 - "$TS" "$VERDICT" "$BIN" "$DISPLAY" "$OUT/screenshot.png" <<'PY' | tee -a "$SUMMARY"
import json, re, sys

ts, verdict_path, bin_path, display, shot = sys.argv[1:6]
data = open(ts, "rb").read()

def sequences():
    # APC graphics strings: ESC _ G ... ST
    return [m.group(0) for m in re.finditer(rb"\x1b_G[\s\S]*?\x1b\\", data)]

def action(seq):
    body = seq[3:-2]
    if b"a=q" in body:
        return "query"
    if b"a=t" in body:
        return "transmit"
    if b"a=p" in body:
        return "placement"
    if b"a=d" in body:
        return "delete"
    return "chunk"

counts = {"query": 0, "transmit": 0, "placement": 0, "delete": 0, "chunk": 0}
first = {}
for seq in sequences():
    name = action(seq)
    counts[name] += 1
    first.setdefault(name, seq)

block_glyphs = sum(data.count(g) for g in
                   ["▀".encode(), "▄".encode(), "▛".encode(), "▜".encode(),
                    "▙".encode(), "▟".encode(), "▘".encode(), "▝".encode()])

kitty_ok = counts["query"] >= 1 and counts["transmit"] >= 1 and counts["placement"] >= 1
if kitty_ok:
    verdict, reason = "PASS", "terminal answered the probe; demo used Kitty transmit+placement"
elif counts["query"] == 0:
    verdict, reason = "FAIL", "demo never sent the Kitty graphics query"
elif block_glyphs > 0:
    verdict, reason = "FAIL", "terminal did not answer the probe; demo fell back to Unicode blocks"
else:
    verdict, reason = "FAIL", "query sent but no Kitty transmit/placement observed"

result = {
    "verdict": verdict,
    "reason": reason,
    "bin": bin_path,
    "display": display,
    "kitty_query": counts["query"] > 0,
    "transmit_a_t": counts["transmit"],
    "placement_a_p": counts["placement"],
    "delete": counts["delete"],
    "payload_chunks": counts["chunk"],
    "unicode_block_glyphs": block_glyphs,
    "transcript": ts,
    "screenshot": shot,
    "first_query": first.get("query", b"")[:120].decode("latin1"),
    "first_transmit": first.get("transmit", b"")[:160].decode("latin1"),
    "first_placement": first.get("placement", b"")[:160].decode("latin1"),
}
json.dump(result, open(verdict_path, "w"), indent=2)
print(f"{verdict}: {reason}")
print(f"query={counts['query']} transmit={counts['transmit']} "
      f"placement={counts['placement']} blocks={block_glyphs}")
sys.exit(0 if verdict == "PASS" else 1)
PY
rc=${PIPESTATUS[0]}
exit "$rc"
