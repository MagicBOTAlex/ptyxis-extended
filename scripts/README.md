# imgcat end-to-end verification harness

Machine-checkable proof that a Ptyxis/VTE build renders iTerm2 `OSC 1337 ; File=`
inline images (`imgcat`, the protocol WezTerm also implements) as real raster
pixels, not Unicode/block placeholders.

The harness runs the target binary headlessly on a private Xvfb display, drives a
deterministic terminal session, emits real PNGs with the shared team emitter,
screenshots the X root window, and asserts exact pixel counts and bounding boxes.
Every scenario writes a JSON verdict; the process exit code is 1 if any scenario
failed.

## Usage

```sh
# Baseline build (the default):
scripts/imgcat-e2e.sh

# A newer build:
scripts/imgcat-e2e.sh --bin /nix/store/<hash>-ptyxis-50.1/bin/ptyxis

# One or more scenarios:
scripts/imgcat-e2e.sh --scenario basic-bel --scenario size-px

# List scenarios / keep the display alive for inspection:
scripts/imgcat-e2e.sh --list
scripts/imgcat-e2e.sh --keep
```

Options: `--bin PATH`, `--emitter PATH`, `--out DIR`, `--scenario NAME`
(repeatable), `--timeout SEC`, `--keep`, `--list`.

Defaults:

| item | value |
| --- | --- |
| binary | `/nix/store/k4dqrarb5ixcf9hjawwafh440fgc9jvg-ptyxis-50.1/bin/ptyxis` |
| emitter | `$IMGCAT_EMITTER`, `scripts/lib/emit_imgcat.py`, or the sibling `imgcat-protocol/scripts/emit_imgcat.py`; falls back to `scripts/lib/emit_osc.sh` |
| artifacts | `/tmp/opencode/imgcat-e2e/<run-id>/` |

Exit status: `0` all selected scenarios passed or skipped, `1` any failed, `2`
bad invocation.

## What it does per scenario

1. Starts (once per run) `Xvfb :<unused>` at 1400x900x24 plus `openbox`.
2. For each scenario starts `dbus-run-session -- ptyxis --standalone -x "bash driver.sh ..."`
   with `XDG_RUNTIME_DIR` private and `GTK_A11Y=none`.
3. Prepends a shim directory whose `systemd-run` exits 1. The sandbox has no
   systemd, so this makes `has_systemd()` false and ptyxis actually execs the
   command. The driver touches `driver.started`, which is how the harness proves
   `--standalone --execute` spawned a shell.
4. The driver reads base64-encoded bash snippets from a FIFO (not from the tty),
   so command completion is acknowledged deterministically via ack files instead
   of sleeps. `printf '\033[6n'` + a read from `/dev/tty` provides exact DSR
   cursor-position checks.
5. Screenshots with `import -window root` once two consecutive frames match
   (cursor-blink tolerant).
6. Asserts with `scripts/lib/pixels.py` (exact RGB counts, bounding boxes,
   fractions) and writes `<scenario>/verdict.json`.

## Scenarios

| scenario | what it proves |
| --- | --- |
| `basic-bel` | native-size image renders at the cursor; BEL terminator; cursor ends bottom-right (C18) |
| `basic-st` | same with `ESC \` (ST) terminator |
| `terminator-8bit-st` | 7-bit OSC + 8-bit `0x9c` ST, and fully 8-bit OSC `0x9d` + `0x9c` (C2) |
| `do-not-move-cursor` | `doNotMoveCursor=1` leaves the cursor exactly in place; plain form advances it (C20) |
| `size-cells` | `width=20;height=10` reserves a 20x10-cell box, bitmap letterboxed/centred (C13/C16) |
| `size-px` | `width=200px` -> 200px wide, aspect-derived height (C10/C12) |
| `size-percent` | `width=50%` of the viewport (C10) |
| `size-one-dim` | `width=20` only -> height derived from aspect (C12) |
| `inline-zero` | `inline=0` draws nothing, cursor unchanged (C17) |
| `wire-errors` | invalid base64, truncated payload, missing terminator: silent drop, no cursor move (C2/C9) |
| `two-images` | back-to-back images sit side by side on the first image's bottom row (C23) |
| `two-images-newline` | a newline separates images cleanly |
| `scrollback` | 300 lines scroll the image away; scrolling back recovers it at the same anchor with the cyan inset intact (C25) |
| `resize` | shrink/grow keeps the process alive and the image unscaled and anchored (C29) |
| `clear` | `ED 2` + `ED 3` removes the image |
| `tall-image` | explicit tall box scrolls rather than being squeezed to the viewport (C15) |
| `large-image` | 3000x2000 PNG: no hang/OOM, downscaled to fit, aspect preserved |
| `photo-payload` | a normal 480x320 noisy PNG (~440 KB, ~590 KB sequence) renders |
| `scrollback-eviction` | 60 images + 12k lines: alive, memory bounded (C26) |
| `erase-semantics` | **aspirational** text-overwrite / `EL 2` cell erasure (C22/C27); reported as a known gap, never fails the suite |
| `control-omitted` | no escape sequence -> no image, while text still renders |
| `control-xterm` | the same bytes in xterm draw nothing |
| `control-stock-vte` | the same bytes in system VTE (gnome-terminal, unpatched) draw nothing; skipped if absent |

## Artifacts

```
/tmp/opencode/imgcat-e2e/<run-id>/
  harness.log
  calibration.json            # measured cell size + content origin
  fixtures/                   # deterministic PNGs used by every run
  scenarios/<name>/
    emitted*.bin              # exact bytes written to the tty
    shots/*.png               # screenshots
    checks.tsv                # one line per assertion
    verdict.json              # machine-readable result
  summary.txt, summary.json, results.tsv
```

## Helper libraries

- `scripts/lib/fixtures.sh` — deterministic PNG fixtures (`magenta-480x320.png`
  is 480x320 magenta with a 2px white border and a 16x16 cyan square at (24,24)).
- `scripts/lib/emit_osc.sh` — standalone byte-exact OSC 1337 emitter and the
  fallback when the shared `emit_imgcat.py` is unavailable.
- `scripts/lib/pixels.py` — Pillow-based pixel assertions (`count`, `bbox`,
  `assert`, `diff`, `dominant`), JSON output and pass/fail exit codes.
- `scripts/lib/session.sh` — Xvfb/openbox/dbus session, FIFO driver, DSR cursor
  queries, stable screenshots, process-group teardown.

Self-tests:

```sh
scripts/lib/fixtures.sh --selftest
scripts/lib/emit_osc.sh --selftest
python3 scripts/lib/test_pixels.py
```

## Known caveats

- Cell size is measured at runtime (20x10 truecolor red block); the default font
  yields 9x18 px, but nothing is hard-coded.
- The 2px border in `magenta-480x320.png` means the *magenta interior* bbox is
  476x316, not 480x320. Assertions use the interior and the cyan inset offset
  (+22,+22 from the magenta origin).
- `control-stock-vte` uses the distro `gnome-terminal`/system VTE. On this
  sandbox it was installed with apt explicitly to provide an unpatched control;
  the scenario skips cleanly when neither `gnome-terminal` nor `kgx` exists.
- Images whose OSC sequence exceeds VTE's 4096-byte OSC string limit are dropped
  before the patch ever sees them (see the report); this is why `large-image`
  and `photo-payload` fail on small, highly-compressible fixtures only if the
  payload crosses that threshold.
