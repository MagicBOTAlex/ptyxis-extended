#!/bin/bash
# session.sh - headless Ptyxis session management for imgcat end-to-end tests.
#
# Provides:
#   pick_display                 -> echoes an unused ":N"
#   display_start DISPLAY OUTDIR -> starts Xvfb + openbox, exports DISPLAY
#   display_stop                 -> kills Xvfb/openbox started by display_start
#   session_start BIN OUTDIR     -> starts ptyxis under a private dbus session
#   session_send "bash code"     -> runs code inside the terminal, waits for it
#   session_shot PATH            -> screenshots the root window
#   session_window_geom          -> "X Y W H" of the ptyxis window (screen coords)
#   session_alive                -> 0 if ptyxis process is still running
#   session_rss_kb               -> ptyxis RSS in kB
#   session_stop                 -> tears the ptyxis session down
#
# All state lives in the OUTDIR passed to session_start, so several test runs
# can execute concurrently on different displays.

set -u

# Default baseline build supplied by the harness owner.
IMGCAT_BASELINE_BIN=/nix/store/k4dqrarb5ixcf9hjawwafh440fgc9jvg-ptyxis-50.1/bin/ptyxis

pick_display() {
    local start="${1:-70}" i
    for i in $(seq "$start" $((start + 200))); do
        if [ ! -e "/tmp/.X11-unix/X$i" ] && [ ! -e "/tmp/.X$i-lock" ]; then
            printf ':%s\n' "$i"
            return 0
        fi
    done
    return 1
}

# Start Xvfb and openbox. Retries on display collisions.
display_start() {
    local out="$1" tries=0 d
    mkdir -p "$out"
    while [ "$tries" -lt 10 ]; do
        tries=$((tries + 1))
        d=$(pick_display $((70 + ($$ + tries * 17) % 200)))
        Xvfb "$d" -screen 0 1400x900x24 -nolisten tcp >"$out/xvfb.log" 2>&1 &
        DISPLAY_XVFB_PID=$!
        local sock="/tmp/.X11-unix/X${d#:}"
        local i
        for i in $(seq 1 60); do
            [ -S "$sock" ] && break
            sleep 0.1
        done
        sleep 0.3
        if kill -0 "$DISPLAY_XVFB_PID" 2>/dev/null && [ -S "$sock" ]; then
            DISPLAY_NUM="$d"
            export DISPLAY="$d"
            openbox >"$out/openbox.log" 2>&1 &
            DISPLAY_OPENBOX_PID=$!
            sleep 0.7
            return 0
        fi
        kill "$DISPLAY_XVFB_PID" 2>/dev/null
        wait "$DISPLAY_XVFB_PID" 2>/dev/null
    done
    echo "display_start: could not start Xvfb" >&2
    return 1
}

display_stop() {
    [ -n "${DISPLAY_XVFB_PID:-}" ] && kill "$DISPLAY_XVFB_PID" 2>/dev/null
    [ -n "${DISPLAY_OPENBOX_PID:-}" ] && kill "$DISPLAY_OPENBOX_PID" 2>/dev/null
    wait "$DISPLAY_XVFB_PID" 2>/dev/null
    wait "$DISPLAY_OPENBOX_PID" 2>/dev/null
    if [ -n "${DISPLAY_NUM:-}" ]; then
        rm -f "/tmp/.X11-unix/X${DISPLAY_NUM#:}" "/tmp/.X${DISPLAY_NUM#:}-lock" 2>/dev/null
    fi
    DISPLAY_XVFB_PID=""
    DISPLAY_OPENBOX_PID=""
}

# Create the systemd-run shim. ptyxis probes for systemd before using
# `systemd-run` to spawn a transient scope; exiting 1 makes has_systemd() false
# so --standalone --execute spawns the shell directly (the sandbox has no PID 1
# systemd).
_make_shim() {
    local out="$1"
    mkdir -p "$out/shim"
    cat >"$out/shim/systemd-run" <<'EOF'
#!/bin/sh
# Sandbox shim: pretend systemd is unavailable so ptyxis runs children directly.
exit 1
EOF
    chmod +x "$out/shim/systemd-run"
}

session_start() {
    local bin="$1" out="$2" title="${3:-imgcat-test}"
    SESSION_BIN="$bin"
    SESSION_OUT="$out"
    SESSION_SEQ=0
    mkdir -p "$out/runtime" "$out/shots"
    chmod 700 "$out/runtime"
    _make_shim "$out"

    SESSION_FIFO="$out/driver.fifo"
    SESSION_READY="$out/driver.started"
    rm -f "$SESSION_FIFO" "$SESSION_READY" "$out"/.done-*
    mkfifo "$SESSION_FIFO"

    cat >"$out/driver.sh" <<'EOF'
#!/bin/bash
# Runs as the terminal's foreground process. Reads base64-encoded bash
# snippets from a FIFO, evals them, and touches an ack file. Not a shell
# prompt: nothing is read from the tty, so output is fully deterministic.
OUT="$1"
exec 3<>"$2"
touch "$OUT/driver.started"
while IFS= read -r line <&3; do
    case "$line" in
        __EXIT__) break ;;
        '') continue ;;
    esac
    eval "$(printf '%s' "$line" | base64 -d)"
done
EOF
    chmod +x "$out/driver.sh"

    # The Xvfb display is private to this harness; clear any stale ptyxis
    # windows from a previous scenario so window lookup is unambiguous.
    local w
    for w in $(xdotool search --maxdepth 5 --class ptyxis 2>/dev/null); do
        xdotool windowclose "$w" 2>/dev/null
    done
    local wi
    for wi in $(seq 1 40); do
        [ -z "$(xdotool search --maxdepth 5 --class ptyxis 2>/dev/null)" ] && break
        sleep 0.1
    done

    local shim="$out/shim"
    # setsid => one process group we can reliably kill.
    env -u DBUS_SESSION_BUS_ADDRESS \
        DISPLAY="$DISPLAY" \
        XDG_RUNTIME_DIR="$out/runtime" \
        GTK_A11Y=none \
        GSK_RENDERER=cairo \
        PATH="$shim:$PATH" \
        setsid dbus-run-session -- "$bin" --standalone -x \
        "bash $out/driver.sh $out $SESSION_FIFO" \
        >"$out/ptyxis.log" 2>&1 &
    SESSION_PID=$!

    local i
    for i in $(seq 1 120); do
        [ -e "$SESSION_READY" ] && break
        sleep 0.25
    done
    if [ ! -e "$SESSION_READY" ]; then
        # Do not fail yet: window may exist but the command did not start.
        echo "session_start: driver not ready" >&2
        return 1
    fi

    SESSION_WID=""
    for i in $(seq 1 80); do
        local w geom gw gh
        local best_area=0 best=""
        while read -r w; do
            [ -n "$w" ] || continue
            geom=$(xdotool getwindowgeometry --shell "$w" 2>/dev/null) || continue
            gw=$(printf '%s\n' "$geom" | sed -n 's/^WIDTH=//p')
            gh=$(printf '%s\n' "$geom" | sed -n 's/^HEIGHT=//p')
            [ -n "$gw" ] && [ -n "$gh" ] || continue
            if [ "$gw" -ge 200 ] 2>/dev/null; then
                if [ $((gw * gh)) -gt "$best_area" ]; then
                    best_area=$((gw * gh))
                    best="$w"
                fi
            fi
        done < <(xdotool search --maxdepth 5 --class ptyxis 2>/dev/null)
        if [ -n "$best" ]; then
            SESSION_WID="$best"
            break
        fi
        sleep 0.25
    done
    if [ -z "$SESSION_WID" ]; then
        echo "session_start: no ptyxis window found" >&2
        return 1
    fi
    # Record the UI process for this scenario (used for RSS and teardown).
    SESSION_UI_PID=$(pgrep -f -- "^$bin --standalone.*$out" 2>/dev/null | head -1)
    # Let the first frame settle.
    sleep 0.5
    return 0
}

# Run a bash snippet inside the terminal. Returns after it has finished.
session_send() {
    local code="$1" tmo="${2:-30}"
    SESSION_SEQ=$((SESSION_SEQ + 1))
    local ack="$SESSION_OUT/.done-$SESSION_SEQ"
    rm -f "$ack"
    local wrapped="$code
__rc=\$?
touch '$ack'
"
    printf '%s\n' "$(printf '%s' "$wrapped" | base64 -w0)" >"$SESSION_FIFO"

    local waited=0
    while [ ! -e "$ack" ]; do
        if ! kill -0 "$SESSION_PID" 2>/dev/null; then
            echo "session_send: session died while running snippet" >&2
            return 1
        fi
        sleep 0.05
        waited=$((waited + 1))
        if [ "$waited" -gt $((tmo * 20)) ]; then
            echo "session_send: timeout after ${tmo}s" >&2
            return 1
        fi
    done
    return 0
}

# Screenshot the whole root window. Retries until two consecutive captures are
# nearly identical (cursor blink tolerance) or the deadline passes.
session_shot() {
    local path="$1" max="${2:-6}"
    mkdir -p "$(dirname "$path")"
    local prev="" i
    for i in $(seq 1 "$max"); do
        import -window root "$path" 2>/dev/null || return 1
        if [ -n "$prev" ]; then
            local ae
            ae=$(compare -metric AE "$prev" "$path" null: 2>&1 | tr -dc '0-9')
            if [ -z "$ae" ] || [ "${ae:-999999}" -lt 400 ] 2>/dev/null; then
                rm -f "$prev"
                return 0
            fi
            rm -f "$prev"
        fi
        prev="${path%.png}.prev-$$.png"
        cp "$path" "$prev"
        sleep 0.3
    done
    rm -f "$prev"
    return 0
}

session_window_geom() {
    [ -n "${SESSION_WID:-}" ] || return 1
    local g
    g=$(xdotool getwindowgeometry --shell "$SESSION_WID" 2>/dev/null) || return 1
    local x y w h
    x=$(printf '%s\n' "$g" | sed -n 's/^X=//p')
    y=$(printf '%s\n' "$g" | sed -n 's/^Y=//p')
    w=$(printf '%s\n' "$g" | sed -n 's/^WIDTH=//p')
    h=$(printf '%s\n' "$g" | sed -n 's/^HEIGHT=//p')
    printf '%s %s %s %s\n' "$x" "$y" "$w" "$h"
}

session_alive() {
    kill -0 "${SESSION_PID:-0}" 2>/dev/null
}

# RSS of the ptyxis UI process (not the agent), in kB.
session_rss_kb() {
    local pid
    pid=$(pgrep -f -- "^$SESSION_BIN --standalone.*$SESSION_OUT" 2>/dev/null | head -1)
    [ -n "$pid" ] || { echo 0; return; }
    awk '/VmRSS/ {print $2}' "/proc/$pid/status" 2>/dev/null || echo 0
}

session_pid() {
    pgrep -f -- "^$SESSION_BIN --standalone.*$SESSION_OUT" 2>/dev/null | head -1
}

# Query the terminal cursor position via DSR (ESC[6n). Returns "row col".
# Uses the pty (not the FIFO) for the reply, with raw/no-echo temporarily set.
session_cursor() {
    local out="$SESSION_OUT/cursor.$$-$RANDOM"
    session_send "stty -F /dev/tty raw -echo 2>/dev/null; printf '\\033[6n'; IFS= read -t 0.6 -r _r < /dev/tty; printf '%s' \"\$_r\" > '$out'; stty -F /dev/tty sane 2>/dev/null" 8 || return 1
    local raw row col
    raw=$(cat "$out" 2>/dev/null)
    row=$(printf '%s' "$raw" | sed -n 's/.*\[\([0-9][0-9]*\);\([0-9][0-9]*\)R.*/\1/p')
    col=$(printf '%s' "$raw" | sed -n 's/.*\[\([0-9][0-9]*\);\([0-9][0-9]*\)R.*/\2/p')
    rm -f "$out"
    [ -n "$row" ] && [ -n "$col" ] || return 1
    printf '%s %s\n' "$row" "$col"
}

# Terminal grid size as reported by the pty: "rows cols".
session_size() {
    local out="$SESSION_OUT/size.$$-$RANDOM"
    session_send "stty -F /dev/tty size > '$out' 2>/dev/null" 6 || return 1
    cat "$out" 2>/dev/null
    rm -f "$out"
}

session_stop() {
    local ui="${SESSION_UI_PID:-}" i w
    if [ -n "${SESSION_PID:-}" ]; then
        kill -TERM -- "-$SESSION_PID" 2>/dev/null
        [ -n "$ui" ] && kill -TERM "$ui" 2>/dev/null
        for i in $(seq 1 25); do
            kill -0 "$SESSION_PID" 2>/dev/null || break
            sleep 0.1
        done
        kill -KILL -- "-$SESSION_PID" 2>/dev/null
        [ -n "$ui" ] && kill -KILL "$ui" 2>/dev/null
        wait "$SESSION_PID" 2>/dev/null
    fi
    # Kill anything still holding this scenario's driver (unique path).
    if [ -n "${SESSION_OUT:-}" ]; then
        pkill -TERM -f -- "$SESSION_OUT/driver.sh" 2>/dev/null
    fi
    # Close/finish any ptyxis window left on our private display.
    for w in $(xdotool search --maxdepth 5 --class ptyxis 2>/dev/null); do
        xdotool windowclose "$w" 2>/dev/null
    done
    for i in $(seq 1 40); do
        [ -z "$(xdotool search --maxdepth 5 --class ptyxis 2>/dev/null)" ] && break
        sleep 0.1
    done
    SESSION_PID=""
    SESSION_WID=""
    SESSION_UI_PID=""
}
