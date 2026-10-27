# Kitty graphics end-to-end harness

`scripts/kitty-e2e.sh` verifies that a Ptyxis/VTE build implements the Kitty
graphics protocol subset OpenTUI uses, by driving a real terminal headlessly and
asserting the resulting pixels and PTY replies.

It reuses the imgcat harness session layer (private Xvfb + openbox, ptyxis under
`dbus-run-session` with a `systemd-run` shim, FIFO command driver, screenshots,
`scripts/lib/pixels.py` assertions) and adds Kitty-specific fixtures, a wire
adapter, a capability probe, and 29 scenarios.

## Usage

```sh
# Baseline (Kitty-less) build: every Kitty scenario must FAIL.
scripts/kitty-e2e.sh

# Candidate build:
scripts/kitty-e2e.sh --bin /nix/store/<hash>-ptyxis-50.1/bin/ptyxis

# Subset / listing:
scripts/kitty-e2e.sh --scenario capability-probe --scenario basic-render
scripts/kitty-e2e.sh --list
```

Options: `--bin PATH`, `--emitter-dir DIR`, `--out DIR`, `--scenario NAME`
(repeatable), `--timeout SEC`, `--keep`, `--list`.
Default out: `/tmp/opencode/kitty-e2e/<run-id>/` (`summary.json`, `results.tsv`,
per-scenario `verdict.json`, screenshots, emitted wire bytes).

Exit 0 iff every selected scenario passed/skipped, 1 on any FAIL, 2 bad args.

## Wire emitter

Scenarios generate sequences through `scripts/lib/kitty_wire.py`, a thin adapter
over `scripts/lib/kitty_emit.py` (wire-exact emitter with its own selftests).
Set `KITTY_EMITTER_DIR` / `--emitter-dir` to load another module-compatible
emitter. `shared-emitter-render` additionally runs the team's
`worktrees/kitty-protocol/scripts/emit_kitty.py`, verifies its output with
`--verify`, asserts its probe bytes are identical to the adapter's, and renders
that emitter's own byte stream.

Self-tests:

```sh
python3 scripts/lib/test_kitty_emit.py        # 23 tests
python3 scripts/lib/test_kitty_probe.py       # 14 tests (pty-based)
python3 scripts/lib/test_kitty_geometry.py    # 39 tests
python3 scripts/lib/kitty_fixtures.py --selftest
```

## Scenarios

| scenario | proves |
| --- | --- |
| `capability-probe` | 38-byte query + DA1 in one burst; exact `ESC_Gi=31337;OK ESC\` reply, no BEL form, graphics reply **before** DA1, cursor/image unchanged (a=q semantics) |
| `basic-render` | chunked PNG (`m=1`, >3072 B) transmit + `a=p`; 360x240 render, cyan inset; continuation chunks carry only `m`/`q` |
| `chunking-partial` | all-but-last chunk + placement draws nothing; final chunk completes upload and the image appears (C14) |
| `raw-rgb` / `raw-rgba` / `zlib` | f=24 halves, f=32 alpha (alpha=0 transparent), `o=z` payloads |
| `chunking-100k` | ~100 kB payload in ≥20 chunks reassembles to correct pixels |
| `envelope-forms` | payload form `ESC_G<ctl>;<b64>ESC\` for transmit/query vs control-only (no `;`) for placement/delete |
| `geometry-cell-box` | `c` only → aspect height; `c`+`r` → letterboxed/pillarboxed box (90x90 centred in 180x90) |
| `geometry-one-dim` | c=20 on 200x100 → 180x90 with 90x90 halves |
| `geometry-source-rect` | `x,y,w,h` crop selects only the blue right half |
| `geometry-cursor` | `C=1` leaves the cursor; default advances right c and down r |
| `geometry-zorder` | z=2 over z=1; deleting the top placement reveals the lower one |
| `zorder-text` | negative z draws behind glyphs (text legible); z≥0 covers them |
| `geometry-multi-placement` | one image id placed twice at different cells |
| `delete-image-id` | `d=i` removes placements but keeps data (re-place works); `d=I` frees data (re-place no-op) |
| `delete-placement` | `d=i,i=..,p=..` removes only that placement |
| `delete-all` | `d=a` removes all placements; data-retention recorded |
| `retransmit` | retransmitting an id replaces data and drops old placements; new placement shows new pixels |
| `lifecycle-scroll` | image scrolls away with text and returns from scrollback |
| `lifecycle-resize` | shrink/grow alive, placement remains |
| `lifecycle-clear` | ED2+ED3 clears images |
| `lifecycle-altscreen` | alt screen images independent; primary restored on exit |
| `quiet-q2` | after a successful probe, q=2 transmit/place/delete produce no replies |
| `shared-emitter-render` | team emitter bytes: probe identical, `--verify` clean, image renders |
| `memory-images` | 100 × 100 kB chunked transmit/place/delete: alive, RSS bounded, no leak, still responsive |
| `control-stock-vte` | system gnome-terminal: no image and **no probe reply** |
| `iterm2-regression` | the 10-scenario imgcat regression subset stays green |
| `opentui-demo` | optional stretch: real OpenTUI native-image demo selects Kitty (SKIP if unavailable) |

## Notes / assumptions

- Cell size is measured at runtime with a 20x10 truecolor red block (9x18 px in
  the default profile); nothing is hardcoded.
- The pty is put in `-echo` mode in every scenario so Kitty `OK` replies cannot
  leak into the grid. The probe and DSR helpers use `/dev/tty`, restore termios,
  and never read the FIFO.
- Geometry expectations follow `worktrees/kitty-protocol/docs/kitty-graphics-protocol.md`:
  `c`/`r` reserve a cell box and letterbox (no distortion); default cursor moves
  right by `c` and down by `r`; `C=1` leaves it; placement deletion is
  `a=d,d=i,i=<id>,p=<pid>`; `d=i` keeps data and `d=I` frees it; `a=t` drops old
  placements for the same id.
- `control-stock-vte` requires `gnome-terminal` or `kgx`; it skips cleanly
  otherwise.
- Baseline behaviour: on a build without Kitty support every graphics scenario
  fails (no probe reply, zero image pixels), while `envelope-forms`
  (`wire-only`), `control-stock-vte`, `iterm2-regression` and (optionally)
  `opentui-demo` SKIP/FAIL as expected.
- `scripts/opentui-kitty-findings.md` documents the stretch-goal investigation:
  OpenTUI's client path was proven with a simulated Kitty reply; the checkout's
  native library could not be built here (no Zig 0.16).
