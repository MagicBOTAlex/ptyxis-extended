#!/usr/bin/env bash
# Byte-exact emitter for iTerm2 OSC 1337 inline-image ("File") sequences.
#
# Requirements: bash, coreutils (base64, cmp, od). Standalone, no repo paths.
#
# Format emitted:
#   ESC ] 1337 ; File = ARGS : BASE64 TERMINATOR
# where TERMINATOR is BEL (0x07) or ST (ESC \ = 0x1b 0x5c), and BASE64 is a
# single unwrapped line. Nothing (not even a newline) follows the terminator.
#
# Usage:
#   source scripts/lib/emit_osc.sh
#   osc1337_file 'inline=1;width=20;height=10' image.png bel > out
#   osc1337_payload 'inline=1' image.png
#   scripts/lib/emit_osc.sh --args 'inline=1' --file X.png --term bel|st
#   scripts/lib/emit_osc.sh --selftest

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -euo pipefail
fi

OSC_START=$'\033]'
ST_TERM=$'\033\134'
BEL_TERM=$'\a'

_osc1337_usage() {
  printf 'usage: %s --args ARGS --file FILE --term bel|st\n       %s --selftest\n' \
    "${0##*/}" "${0##*/}"
}

# Single-line base64 of a file. GNU base64 wraps at 76 columns on stdin, so
# strip CR/LF instead of relying on a non-portable -w0 flag.
_osc1337_b64() {
  local file=$1 out
  out=$(base64 < "$file") || return 1
  printf '%s' "$out" | tr -d '\r\n'
}

# Emit every byte value 0x00-0xFF exactly once (deterministic binary fixture).
_osc_write_all_byte_values() {
  local i
  for ((i = 0; i < 256; i++)); do
    printf '%b' "\\$(printf '%03o' "$i")"
  done
}

osc1337_payload() {
  if [[ $# -ne 2 ]]; then
    printf 'usage: osc1337_payload ARGS FILE\n' >&2
    return 2
  fi
  local args=$1 file=$2 b64
  if [[ ! -f $file || ! -r $file ]]; then
    printf 'error: not a readable file: %s\n' "$file" >&2
    return 2
  fi
  b64=$(_osc1337_b64 "$file") || {
    printf 'error: base64 failed for: %s\n' "$file" >&2
    return 1
  }
  printf '1337;File=%s:%s' "$args" "$b64"
}

osc1337_file() {
  if [[ $# -ne 3 ]]; then
    printf 'usage: osc1337_file ARGS FILE bel|st\n' >&2
    return 2
  fi
  local args=$1 file=$2 term=$3 payload
  case $term in
    bel | st) ;;
    *)
      printf 'error: terminator must be "bel" or "st", got: %s\n' "$term" >&2
      return 2
      ;;
  esac
  payload=$(osc1337_payload "$args" "$file") || return 1
  printf '%s%s' "$OSC_START" "$payload"
  case $term in
    bel) printf '%s' "$BEL_TERM" ;;
    st) printf '%s' "$ST_TERM" ;;
  esac
}

# ---------------------------------------------------------------------------
# selftest
# ---------------------------------------------------------------------------

_osc_selftest_state() {
  OSC_CHECKS=0
  OSC_FAILS=0
}

_osc_pass() {
  OSC_CHECKS=$((OSC_CHECKS + 1))
  printf 'ok: %s\n' "$1"
}

_osc_fail() {
  OSC_CHECKS=$((OSC_CHECKS + 1))
  OSC_FAILS=$((OSC_FAILS + 1))
  printf 'FAIL: %s\n' "$1" >&2
}

# Extract the base64 body from an emitted sequence: skip prefix bytes, drop
# the terminator.
_osc_extract_b64() { # outfile b64out prefix_len term_len
  local total blen
  total=$(wc -c < "$1")
  blen=$((total - $3 - $4))
  tail -c "+$(($3 + 1))" "$1" | head -c "$blen" > "$2"
}

_osc_b64_charset_clean() { # b64file
  local stray
  stray=$(LC_ALL=C tr -d 'A-Za-z0-9+/=' < "$1" | LC_ALL=C tr -d '\r\n' | wc -c)
  [[ $stray -eq 0 ]]
}

_osc_b64_len_ok() { # b64file payloadfile
  local n want got
  n=$(wc -c < "$2")
  want=$(( ((n + 2) / 3) * 4 ))
  got=$(wc -c < "$1")
  [[ $got -eq $want ]]
}

_osc_wrap_free() { # b64file
  # No CR/LF anywhere in the encoded body.
  local raw stripped
  raw=$(wc -c < "$1")
  stripped=$(LC_ALL=C tr -d '\r\n' < "$1" | wc -c)
  [[ $raw -eq $stripped ]]
}

_osc_roundtrip_ok() { # b64file original
  local decoded="$OSC_TMP/decoded.bin"
  if ! base64 -d < "$1" > "$decoded" 2>/dev/null; then
    return 1
  fi
  cmp -s "$decoded" "$2"
}

osc_selftest() {
  local had_e=0
  case $- in *e*) had_e=1 ;; esac
  set +e

  _osc_selftest_state
  local tmp
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/osc1337-selftest.XXXXXX")
  if [[ -z $tmp || ! -d $tmp ]]; then
    printf 'FAIL: could not create temp dir\n' >&2
    return 1
  fi
  OSC_TMP=$tmp

  local plain="$tmp/plain.txt"
  local bin="$tmp/binary-512.bin"
  local spaced_dir="$tmp/dir with space"
  local spaced="$spaced_dir/payload é.bin"
  local empty="$tmp/empty.bin"
  local prefix="$tmp/prefix.bel"
  local esc_bs="$tmp/esc-backslash"

  printf 'iTerm2 OSC 1337 payload test\n' > "$plain"
  : > "$empty"
  printf '\033\134' > "$esc_bs"
  printf '\033]1337;File=inline=1:' > "$prefix"
  mkdir -p -- "$spaced_dir"

  # Deterministic 512-byte fixture containing every byte value twice:
  # NUL, control bytes, 0x80-0xFF and non-ASCII UTF-8 all present.
  {
    _osc_write_all_byte_values
    _osc_write_all_byte_values
  } > "$bin"
  cp -- "$bin" "$spaced"

  if [[ $(wc -c < "$bin") -eq 512 ]]; then
    _osc_pass 'binary fixture is 512 bytes (non-ASCII + NUL)'
  else
    _osc_fail 'binary fixture is 512 bytes (non-ASCII + NUL)'
  fi
  if od -An -tu1 "$bin" | tr -s ' ' '\n' | grep -qx 0 &&
    od -An -tu1 "$bin" | tr -s ' ' '\n' | grep -qx 255; then
    _osc_pass 'binary fixture contains NUL (0x00) and 0xFF bytes'
  else
    _osc_fail 'binary fixture contains NUL (0x00) and 0xFF bytes'
  fi

  # --- 1. bel, inline=1: shape and exact prefix ---
  if osc1337_file 'inline=1' "$plain" bel > "$tmp/out.bel"; then
    _osc_pass 'emit bel (inline=1)'
  else
    _osc_fail 'emit bel (inline=1)'
  fi

  if head -c "$(wc -c < "$prefix")" "$tmp/out.bel" | cmp -s - "$prefix"; then
    _osc_pass 'bel prefix is byte-exact ESC]1337;File=inline=1:'
  else
    _osc_fail 'bel prefix is byte-exact ESC]1337;File=inline=1:'
  fi

  if tail -c 1 "$tmp/out.bel" | cmp -s - <(printf '\a'); then
    _osc_pass 'bel terminated by BEL (0x07)'
  else
    _osc_fail 'bel terminated by BEL (0x07)'
  fi

  _osc_extract_b64 "$tmp/out.bel" "$tmp/out.bel.b64" 21 1
  if _osc_roundtrip_ok "$tmp/out.bel.b64" "$plain"; then
    _osc_pass 'bel base64 decodes byte-identical to input'
  else
    _osc_fail 'bel base64 decodes byte-identical to input'
  fi
  if _osc_b64_charset_clean "$tmp/out.bel.b64"; then
    _osc_pass 'bel base64 body is unwrapped, no newlines, valid charset'
  else
    _osc_fail 'bel base64 body is unwrapped, no newlines, valid charset'
  fi
  if _osc_wrap_free "$tmp/out.bel.b64"; then
    _osc_pass 'bel base64 body contains no CR/LF'
  else
    _osc_fail 'bel base64 body contains no CR/LF'
  fi
  if _osc_b64_len_ok "$tmp/out.bel.b64" "$plain"; then
    _osc_pass 'bel base64 length matches 4*ceil(n/3)'
  else
    _osc_fail 'bel base64 length matches 4*ceil(n/3)'
  fi
  if [[ $(wc -c < "$tmp/out.bel") -eq $((21 + $(wc -c < "$tmp/out.bel.b64") + 1)) ]]; then
    _osc_pass 'bel sequence has no trailing bytes after terminator'
  else
    _osc_fail 'bel sequence has no trailing bytes after terminator'
  fi

  # --- 2. st terminator ---
  if osc1337_file 'inline=1' "$plain" st > "$tmp/out.st"; then
    _osc_pass 'emit st (inline=1)'
  else
    _osc_fail 'emit st (inline=1)'
  fi
  if tail -c 2 "$tmp/out.st" | cmp -s - "$esc_bs"; then
    _osc_pass 'st terminated by ESC \ (0x1b 0x5c)'
  else
    _osc_fail 'st terminated by ESC \\ (0x1b 0x5c)'
  fi
  if head -c 21 "$tmp/out.st" | cmp -s - "$prefix"; then
    _osc_pass 'st prefix is byte-exact ESC]1337;File=inline=1:'
  else
    _osc_fail 'st prefix is byte-exact ESC]1337;File=inline=1:'
  fi
  _osc_extract_b64 "$tmp/out.st" "$tmp/out.st.b64" 21 2
  if _osc_roundtrip_ok "$tmp/out.st.b64" "$plain"; then
    _osc_pass 'st base64 decodes byte-identical to input'
  else
    _osc_fail 'st base64 decodes byte-identical to input'
  fi
  if [[ $(wc -c < "$tmp/out.st") -eq $((21 + $(wc -c < "$tmp/out.st.b64") + 2)) ]]; then
    _osc_pass 'st sequence has no trailing bytes after terminator'
  else
    _osc_fail 'st sequence has no trailing bytes after terminator'
  fi

  # --- 3. arbitrary ARGS are passed through verbatim ---
  local args1='inline=1;width=20;height=10'
  local args2='inline=1;doNotMoveCursor=1'
  local pfx1="$tmp/prefix-args1" pfx2="$tmp/prefix-args2"
  printf '\033]1337;File=%s:' "$args1" > "$pfx1"
  printf '\033]1337;File=%s:' "$args2" > "$pfx2"

  if osc1337_file "$args1" "$plain" bel > "$tmp/out.args1" &&
    head -c "$(wc -c < "$pfx1")" "$tmp/out.args1" | cmp -s - "$pfx1"; then
    _osc_pass "ARGS preserved verbatim: $args1"
  else
    _osc_fail "ARGS preserved verbatim: $args1"
  fi
  if osc1337_file "$args2" "$plain" st > "$tmp/out.args2" &&
    head -c "$(wc -c < "$pfx2")" "$tmp/out.args2" | cmp -s - "$pfx2"; then
    _osc_pass "ARGS preserved verbatim: $args2"
  else
    _osc_fail "ARGS preserved verbatim: $args2"
  fi

  # --- 4. payload helper == body of full sequence ---
  if osc1337_payload "$args1" "$plain" > "$tmp/payload.txt"; then
    _osc_pass 'osc1337_payload emitted'
  else
    _osc_fail 'osc1337_payload emitted'
  fi
  # payload == sequence minus leading ESC+']' and trailing terminator
  local seqbody="$tmp/seqbody.txt"
  tail -c "+3" "$tmp/out.args1" | head -c "$(($(wc -c < "$tmp/out.args1") - 3))" > "$seqbody"
  if cmp -s "$tmp/payload.txt" "$seqbody"; then
    _osc_pass 'osc1337_payload matches sequence body (no ESC, no terminator)'
  else
    _osc_fail 'osc1337_payload matches sequence body (no ESC, no terminator)'
  fi
  if [[ $(head -c 12 "$tmp/payload.txt") == '1337;File=in' ]]; then
    _osc_pass 'osc1337_payload starts with 1337;File='
  else
    _osc_fail 'osc1337_payload starts with 1337;File='
  fi

  # --- 5. binary / non-ASCII fixture round-trips ---
  if osc1337_file 'inline=1' "$bin" bel > "$tmp/out.bin" &&
    tail -c "+22" "$tmp/out.bin" | head -c "$(($(wc -c < "$tmp/out.bin") - 22))" > "$tmp/out.bin.b64" &&
    _osc_roundtrip_ok "$tmp/out.bin.b64" "$bin"; then
    _osc_pass 'binary non-ASCII fixture round-trips byte-identically'
  else
    _osc_fail 'binary non-ASCII fixture round-trips byte-identically'
  fi

  # --- 6. path with spaces and non-ASCII filename ---
  if osc1337_file 'inline=1' "$spaced" bel > "$tmp/out.spaced" &&
    tail -c "+22" "$tmp/out.spaced" | head -c "$(($(wc -c < "$tmp/out.spaced") - 22))" > "$tmp/out.spaced.b64" &&
    _osc_roundtrip_ok "$tmp/out.spaced.b64" "$spaced"; then
    _osc_pass 'path with spaces + non-ASCII filename round-trips'
  else
    _osc_fail 'path with spaces + non-ASCII filename round-trips'
  fi

  # --- 7. empty file edge case ---
  if osc1337_file 'inline=1' "$empty" st > "$tmp/out.empty" &&
    head -c 21 "$tmp/out.empty" | cmp -s - "$prefix" &&
    [[ $(wc -c < "$tmp/out.empty") -eq 23 ]]; then
    _osc_pass 'empty file yields empty base64 body'
  else
    _osc_fail 'empty file yields empty base64 body'
  fi

  # --- 8. invalid terminator is rejected ---
  if osc1337_file 'inline=1' "$plain" bogus > /dev/null 2>&1; then
    _osc_fail 'invalid terminator rejected'
  else
    _osc_pass 'invalid terminator rejected (nonzero exit)'
  fi

  # --- 9. missing file is rejected ---
  if osc1337_file 'inline=1' "$tmp/does-not-exist" bel > /dev/null 2>&1; then
    _osc_fail 'missing file rejected'
  else
    _osc_pass 'missing file rejected (nonzero exit)'
  fi

  rm -rf -- "$tmp"
  unset OSC_TMP

  if [[ $OSC_FAILS -eq 0 ]]; then
    printf 'emit_osc selftest PASS (%d checks)\n' "$OSC_CHECKS"
  else
    printf 'emit_osc selftest FAIL (%d/%d checks failed)\n' "$OSC_FAILS" "$OSC_CHECKS" >&2
  fi

  if [[ $had_e -eq 1 ]]; then set -e; fi
  [[ $OSC_FAILS -eq 0 ]]
}

# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

osc_main() {
  local args='' file='' term='' want_selftest=0 have_args=0 have_file=0 have_term=0
  while [[ $# -gt 0 ]]; do
    case $1 in
      --args)
        [[ $# -ge 2 ]] || {
          printf 'error: --args requires a value\n' >&2
          return 2
        }
        args=$2 have_args=1
        shift 2
        ;;
      --file)
        [[ $# -ge 2 ]] || {
          printf 'error: --file requires a value\n' >&2
          return 2
        }
        file=$2 have_file=1
        shift 2
        ;;
      --term)
        [[ $# -ge 2 ]] || {
          printf 'error: --term requires a value\n' >&2
          return 2
        }
        term=$2 have_term=1
        shift 2
        ;;
      --selftest)
        want_selftest=1
        shift
        ;;
      -h | --help)
        _osc1337_usage
        return 0
        ;;
      *)
        printf 'error: unknown argument: %s\n' "$1" >&2
        _osc1337_usage >&2
        return 2
        ;;
    esac
  done

  if [[ $want_selftest -eq 1 ]]; then
    osc_selftest
    return
  fi
  if [[ $have_args -eq 0 || $have_file -eq 0 || $have_term -eq 0 ]]; then
    _osc1337_usage >&2
    return 2
  fi
  osc1337_file "$args" "$file" "$term"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  osc_main "$@"
fi
