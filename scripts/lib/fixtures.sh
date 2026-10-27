#!/usr/bin/env bash
# Deterministic test-image fixtures for iTerm2 OSC 1337 inline-image tests.
#
# Requirements: bash, ImageMagick 6 (`convert`, `identify`).
# No repo-specific paths; standalone.
#
# Usage:
#   source scripts/lib/fixtures.sh && imgcat_make_fixtures OUTDIR
#   scripts/lib/fixtures.sh OUTDIR
#   scripts/lib/fixtures.sh --selftest
#
# Fixtures (all 8-bit RGB PNG, no alpha, tIME/date chunks excluded):
#   magenta-480x320.png   magenta #FF00FF, 2px white border, 16x16 cyan #00FFFF at (24,24)
#   large-3000x2000.png   green #00A000, 100x100 magenta #FF00FF at (50,50)
#   probe-96x64.png       blue #3366FF, 2px white border, 8x8 yellow #FFFF00 at (8,8)

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -euo pipefail
fi

FIXTURE_MAGENTA="magenta-480x320.png"
FIXTURE_LARGE="large-3000x2000.png"
FIXTURE_PROBE="probe-96x64.png"
FIXTURE_NAMES=("$FIXTURE_MAGENTA" "$FIXTURE_LARGE" "$FIXTURE_PROBE")

# Deterministic PNG writer: PNG24 (truecolor, 8-bit) and no timestamp chunks.
_fixtures_convert() {
  local out=$1
  shift
  convert "$@" \
    -strip -depth 8 \
    -define png:exclude-chunks=date,time \
    -define png:compression-level=9 \
    "PNG24:$out"
}

imgcat_make_fixtures() {
  if [[ $# -ne 1 || -z ${1:-} ]]; then
    printf 'usage: imgcat_make_fixtures OUTDIR\n' >&2
    return 2
  fi
  local outdir=$1
  mkdir -p -- "$outdir" || return 1

  _fixtures_convert "$outdir/$FIXTURE_MAGENTA" \
    -size 480x320 "xc:#FF00FF" +antialias \
    -fill '#FFFFFF' -draw 'rectangle 0,0 479,1 rectangle 0,318 479,319 rectangle 0,0 1,319 rectangle 478,0 479,319' \
    -fill '#00FFFF' -draw 'rectangle 24,24 39,39' || return 1

  _fixtures_convert "$outdir/$FIXTURE_LARGE" \
    -size 3000x2000 "xc:#00A000" +antialias \
    -fill '#FF00FF' -draw 'rectangle 50,50 149,149' || return 1

  _fixtures_convert "$outdir/$FIXTURE_PROBE" \
    -size 96x64 "xc:#3366FF" +antialias \
    -fill '#FFFFFF' -draw 'rectangle 0,0 95,1 rectangle 0,62 95,63 rectangle 0,0 1,63 rectangle 94,0 95,63' \
    -fill '#FFFF00' -draw 'rectangle 8,8 15,15' || return 1
}

# ---------------------------------------------------------------------------
# selftest
# ---------------------------------------------------------------------------

_fixtures_selftest_state() {
  FIXTURES_CHECKS=0
  FIXTURES_FAILS=0
}

_fixtures_pass() {
  FIXTURES_CHECKS=$((FIXTURES_CHECKS + 1))
  printf 'ok: %s\n' "$1"
}

_fixtures_fail() {
  FIXTURES_CHECKS=$((FIXTURES_CHECKS + 1))
  FIXTURES_FAILS=$((FIXTURES_FAILS + 1))
  printf 'FAIL: %s\n' "$1" >&2
}

_fixtures_geometry_is() { # file WxH
  local got
  got=$(identify -format '%wx%h' "$1" 2>/dev/null) || return 1
  [[ $got == "$2" ]]
}

_fixtures_depth_is() { # file depth
  local got
  got=$(identify -format '%z' "$1" 2>/dev/null) || return 1
  [[ $got == "$2" ]]
}

_fixtures_colors_is() { # file count
  local got
  got=$(identify -format '%k' "$1" 2>/dev/null) || return 1
  [[ $got == "$2" ]]
}

_fixtures_pixel_is() { # file x y 'srgb(r,g,b)'
  local got
  got=$(identify -format "%[pixel:p{$2,$3}]" "$1" 2>/dev/null) || return 1
  got=$(printf '%s' "$got" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
  [[ $got == "$4" ]]
}

# Space-separated PNG chunk type list, parsed from the raw file. Used to prove
# no timestamp/text chunks (tIME/tEXt/...) survive the writer options.
_fixtures_png_chunks() {
  local file=$1 size pos=8 type len
  local -a b
  local chunks=''
  size=$(wc -c < "$file") || return 1
  while [[ $pos -lt $size ]]; do
    read -r -a b <<< "$(od -An -tu1 -j "$pos" -N 4 "$file")" || return 1
    [[ ${#b[@]} -eq 4 ]] || return 1
    len=$((b[0] * 16777216 + b[1] * 65536 + b[2] * 256 + b[3]))
    type=$(dd if="$file" bs=1 skip=$((pos + 4)) count=4 2>/dev/null) || return 1
    chunks+="$type "
    [[ $type == IEND ]] && break
    pos=$((pos + 12 + len))
  done
  printf '%s' "$chunks"
}

_fixtures_check_pixels() { # file label + triples "x y color"...
  local file=$1 label=$2
  shift 2
  local x y color desc
  while [[ $# -ge 3 ]]; do
    x=$1 y=$2 color=$3
    shift 3
    desc="$label pixel ($x,$y) = $color"
    if _fixtures_pixel_is "$file" "$x" "$y" "$color"; then
      _fixtures_pass "$desc"
    else
      _fixtures_fail "$desc (got $(identify -format "%[pixel:p{$x,$y}]" "$file" 2>/dev/null))"
    fi
  done
}

fixtures_selftest() {
  local had_e=0
  case $- in *e*) had_e=1 ;; esac
  set +e

  _fixtures_selftest_state
  local tmp
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/imgcat-fixtures.XXXXXX")
  if [[ -z $tmp || ! -d $tmp ]]; then
    printf 'FAIL: could not create temp dir\n' >&2
    return 1
  fi

  local run1="$tmp/run1" run2="$tmp/run2"
  if imgcat_make_fixtures "$run1" && imgcat_make_fixtures "$run2"; then
    _fixtures_pass 'generated fixtures twice'
  else
    _fixtures_fail 'generated fixtures twice'
    rm -rf -- "$tmp"
    [[ $had_e -eq 1 ]] && set -e
    return 1
  fi

  local name f1 f2 size
  for name in "${FIXTURE_NAMES[@]}"; do
    f1="$run1/$name"
    f2="$run2/$name"

    if [[ -s $f1 ]]; then
      _fixtures_pass "$name exists and is non-empty"
    else
      _fixtures_fail "$name exists and is non-empty"
      continue
    fi

    if cmp -s "$f1" "$f2"; then
      size=$(wc -c < "$f1")
      _fixtures_pass "$name byte-identical across runs ($size bytes)"
    else
      _fixtures_fail "$name byte-identical across runs"
    fi

    if [[ $(wc -c < "$f1") -lt 65536 ]]; then
      _fixtures_pass "$name compact (< 65536 bytes)"
    else
      _fixtures_fail "$name compact (< 65536 bytes)"
    fi

    if _fixtures_depth_is "$f1" 8; then
      _fixtures_pass "$name 8-bit depth"
    else
      _fixtures_fail "$name 8-bit depth"
    fi

    local chunks
    chunks=$(_fixtures_png_chunks "$f1")
    if [[ $chunks == IHDR*IDAT*IEND* && $chunks != *tIME* && $chunks != *tEXt* &&
      $chunks != *zTXt* && $chunks != *iTXt* ]]; then
      _fixtures_pass "$name chunks only IHDR/IDAT/IEND (no tIME/tEXt): $chunks"
    else
      _fixtures_fail "$name chunks only IHDR/IDAT/IEND (no tIME/tEXt): ${chunks:-<unparsed>}"
    fi
  done

  # Sniff PNG signature, not some other format.
  local sig
  sig=$(head -c 8 "$run1/$FIXTURE_MAGENTA" | od -An -tx1 | tr -d ' \n')
  if [[ $sig == 89504e470d0a1a0a ]]; then
    _fixtures_pass 'PNG signature present'
  else
    _fixtures_fail 'PNG signature present'
  fi

  # --- magenta-480x320 ---
  local magenta="$run1/$FIXTURE_MAGENTA"
  if _fixtures_geometry_is "$magenta" 480x320; then
    _fixtures_pass "$FIXTURE_MAGENTA size 480x320"
  else
    _fixtures_fail "$FIXTURE_MAGENTA size 480x320"
  fi
  if _fixtures_colors_is "$magenta" 3; then
    _fixtures_pass "$FIXTURE_MAGENTA has exactly 3 colors"
  else
    _fixtures_fail "$FIXTURE_MAGENTA has exactly 3 colors"
  fi
  _fixtures_check_pixels "$magenta" "$FIXTURE_MAGENTA" \
    0 0 'srgb(255,255,255)' \
    479 0 'srgb(255,255,255)' \
    0 319 'srgb(255,255,255)' \
    479 319 'srgb(255,255,255)' \
    0 100 'srgb(255,255,255)' \
    100 0 'srgb(255,255,255)' \
    2 100 'srgb(255,0,255)' \
    24 24 'srgb(0,255,255)' \
    39 39 'srgb(0,255,255)' \
    23 24 'srgb(255,0,255)' \
    40 24 'srgb(255,0,255)' \
    24 23 'srgb(255,0,255)' \
    24 40 'srgb(255,0,255)'

  # --- large-3000x2000 ---
  local large="$run1/$FIXTURE_LARGE"
  if _fixtures_geometry_is "$large" 3000x2000; then
    _fixtures_pass "$FIXTURE_LARGE size 3000x2000"
  else
    _fixtures_fail "$FIXTURE_LARGE size 3000x2000"
  fi
  if _fixtures_colors_is "$large" 2; then
    _fixtures_pass "$FIXTURE_LARGE has exactly 2 colors"
  else
    _fixtures_fail "$FIXTURE_LARGE has exactly 2 colors"
  fi
  _fixtures_check_pixels "$large" "$FIXTURE_LARGE" \
    0 0 'srgb(0,160,0)' \
    2999 1999 'srgb(0,160,0)' \
    50 50 'srgb(255,0,255)' \
    149 149 'srgb(255,0,255)' \
    49 50 'srgb(0,160,0)' \
    150 50 'srgb(0,160,0)' \
    50 49 'srgb(0,160,0)' \
    50 150 'srgb(0,160,0)'

  # --- probe-96x64 ---
  local probe="$run1/$FIXTURE_PROBE"
  if _fixtures_geometry_is "$probe" 96x64; then
    _fixtures_pass "$FIXTURE_PROBE size 96x64"
  else
    _fixtures_fail "$FIXTURE_PROBE size 96x64"
  fi
  if _fixtures_colors_is "$probe" 3; then
    _fixtures_pass "$FIXTURE_PROBE has exactly 3 colors"
  else
    _fixtures_fail "$FIXTURE_PROBE has exactly 3 colors"
  fi
  _fixtures_check_pixels "$probe" "$FIXTURE_PROBE" \
    0 0 'srgb(255,255,255)' \
    95 63 'srgb(255,255,255)' \
    2 32 'srgb(51,102,255)' \
    8 8 'srgb(255,255,0)' \
    15 15 'srgb(255,255,0)' \
    7 8 'srgb(51,102,255)' \
    16 8 'srgb(51,102,255)' \
    8 7 'srgb(51,102,255)' \
    8 16 'srgb(51,102,255)'

  rm -rf -- "$tmp"

  if [[ $FIXTURES_FAILS -eq 0 ]]; then
    printf 'fixtures selftest PASS (%d checks)\n' "$FIXTURES_CHECKS"
  else
    printf 'fixtures selftest FAIL (%d/%d checks failed)\n' "$FIXTURES_FAILS" "$FIXTURES_CHECKS" >&2
  fi

  if [[ $had_e -eq 1 ]]; then set -e; fi
  [[ $FIXTURES_FAILS -eq 0 ]]
}

# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

fixtures_usage() {
  printf 'usage: %s OUTDIR\n       %s --selftest\n' "${0##*/}" "${0##*/}"
}

fixtures_main() {
  case ${1:-} in
    --selftest)
      fixtures_selftest
      ;;
    -h | --help)
      fixtures_usage
      ;;
    '' | -*)
      fixtures_usage >&2
      return 2
      ;;
    *)
      if [[ $# -ne 1 ]]; then
        fixtures_usage >&2
        return 2
      fi
      imgcat_make_fixtures "$1"
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  fixtures_main "$@"
fi
