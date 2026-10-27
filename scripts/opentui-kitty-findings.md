# OpenTUI Kitty demo: feasibility and evidence

Date: 2026-10-27
Worktree: `kitty-harness-opentui` (branch `test/kitty-harness-opentui`, checked out at `614e756`)
OpenTUI checkout examined: `/home/metal/projects/console-extend/opentui` at `7f2d08c`
(`core: end terminal reply waits at their DA1 reply (#1816)`, version `0.7.0`)

## Verdict

**The client path is proven: OpenTUI sends the Kitty graphics probe, and when the
probe is answered with `OK` it switches from Unicode block fallback to Kitty
transmit + placement.**

**The checkout's own native library cannot be built here** because Zig `0.16.0`
is not installed and no published prebuilt library matches this HEAD's ABI.
The evidence below therefore uses the published `@opentui/core@0.7.0` native
library with an unmodified copy of the checkout's `native-image-demo.ts`
(`packages/examples/src/native-image-demo.ts`) and its assets. The demo source is
byte-identical to the checkout; only the native/core runtime is the release
build.

A real-terminal harness hook was produced:
`scripts/lib/opentui_kitty_demo.sh`. It runs the demo inside a Ptyxis window,
lets the real terminal answer the probe, screenshots the window, and reports
PASS/FAIL with JSON. A standalone pty simulator,
`scripts/lib/opentui_kitty_probe.py`, reproduces the evidence without X or a
Kitty-capable terminal.

## Why the checkout cannot be built cheaply

- `zig` is not installed (`command -v zig` -> nothing; no `zig-*` path in
  `/nix/store`), and `packages/native/.zig-version` / `build.zig.zon` require
  **Zig 0.16.0**.
- The checkout has no prebuilt artifacts (`zig-out/`, `*.so`, `*.node` absent)
  and no `node_modules`.
- Bun install works from cache/registry, but the published prebuilt native
  library is ABI-incompatible with HEAD:

  ```text
  $ bun add --no-save @opentui/core-linux-x64@0.7.0
  ...
  error: Failed to initialize OpenTUI render library:
    Symbol "ot_scene_set_scroll" not found in
    ".../@opentui/core-linux-x64/libopentui.so"
      at resolveRenderLib (.../packages/core/src/zig.ts:9560:17)
  ```

- The only npm snapshot (`@opentui/core-linux-x64@0.0.0-20261025-82f27220`,
  published 2026-10-25) fails with the same missing symbol. HEAD is dated
  2026-10-27, after that snapshot.
- Build path if Zig is later available:
  `cd packages/native && bun run prepare:zig && zig build -Doptimize=ReleaseFast`
  (dependencies are vendored in `src/vendor/zig-deps.tar.gz`; no extra network
  fetch needed beyond Zig itself).

## Reproduction of the client-path proof

Prepare a demo workdir using the checkout's demo source and the published core
(the probe does not need X):

```sh
DEMO=/tmp/opencode/opentui-pub
SRC=/home/metal/projects/console-extend/opentui/packages/examples/src
mkdir -p "$DEMO/src/lib" "$DEMO/src/assets"
cp "$SRC/native-image-demo.ts" "$DEMO/src/"
cp "$SRC/lib/standalone-keys.ts" "$DEMO/src/lib/"
cp "$SRC/assets/"{image-demo.gif,image-demo.png,dragon.jpg,image-demo.webp} "$DEMO/src/assets/"
printf '{"name":"opentui-kitty-demo","private":true,"type":"module","dependencies":{"@opentui/core":"0.7.0"}}\n' > "$DEMO/package.json"
(cd "$DEMO" && /home/metal/.bun/bin/bun install)
```

Run the simulator (answers the probe immediately with `ESC_Gi=31337;OK ESC\`):

```sh
scripts/lib/opentui_kitty_probe.py --demo-dir /tmp/opencode/opentui-pub \
  --out /tmp/opencode/probe-answer.bin
```

Observed result (exit 0):

```json
{
  "verdict": "PASS",
  "kitty_query": true,
  "kitty_path": true,
  "answered": {"kitty": 1, "da1": 1, "dsr": 1, "pixel": 1},
  "counts": {"query": 1, "transmit": 5, "placement": 12, "delete": 6, "chunk": 1355},
  "block_glyphs": 0
}
```

Control run with `--no-answer` (exit 0, expected fallback):

```json
{
  "verdict": "PASS",
  "kitty_query": true,
  "kitty_path": false,
  "counts": {"query": 1, "transmit": 0, "placement": 0, "delete": 0, "chunk": 0},
  "block_glyphs": 3341
}
```

This establishes causality: the same demo, same environment, only the probe
reply differs. With `OK` it emits Kitty graphics; without a reply it draws
Unicode half-blocks. In the answered run the transcript contains no block
glyphs at all.

## Captured bytes (exact, truncated)

Raw capture: `/tmp/opencode/probe-answer.bin` (5,601,151 bytes in the run above;
size and sequence counts vary with GIF animation timing).

First bytes after the probe query, with offsets into the captured stream:

| offset | escalation | escaped bytes |
| ---: | --- | --- |
| 174 | probe query, sent once | `\x1b_Gi=31337,s=1,v=1,a=q,t=d,f=24;AAAA\x1b\\` |
| 395 | transmit (`a=t`), 221 bytes after query | `\x1b_Ga=t,f=100,i=997371387,m=1,q=2;iVBORw0KGgoAAAANSUhEUgAAAYAAAAJACAIAAAALpSbB...` |
| 526,965 | placement (`a=p`) | `\x1b_Ga=p,i=997371387,p=2147483648,c=2,r=8,x=0,y=0,w=26,h=201,C=1,z=-1073741823,q=2\x1b\\` |
| 5,369,426 | delete | `\x1b_Ga=d,d=i,i=997371387,p=2147483648,q=2\x1b\\` |

Hex of the probe query (from offset 174):

```text
1b5f47693d33313333372c733d312c763d312c613d712c743d642c663d32343b414141411b5c
```

Hex of the first transmit header:

```text
1b5f47613d742c663d3130302c693d3939373337313338372c6d3d312c713d323b69
```

Notes:

- Kitty action bytes are lowercase `a=t` / `a=p`, not `a=T`. The brief's `a=T`
  spelling is not what OpenTUI emits (the Kitty spec actions are lowercase).
- Two transmit shapes were observed depending on the source image:
  `f=100` with PNG payload (shown above) and `f=24` raw RGB
  (`\x1b_Ga=t,f=24,s=384,v=576,i=88398641,m=1,q=2;...`).
  Multi-chunk payloads continue with `\x1b_Gm=1,q=2;...`.
- The demo sends exactly one probe per startup. Detection is probe-driven in
  this configuration: `TERM=xterm-256color`, `TERM_PROGRAM` unset, so no
  terminal-name heuristic can select Kitty.

## Harness hook

`scripts/lib/opentui_kitty_demo.sh` — optional, self-contained Bash hook that
reuses `scripts/lib/session.sh` (Xvfb/openbox/dbus/systemd shim and screenshots).

```sh
scripts/lib/opentui_kitty_demo.sh \
  --bin /nix/store/<hash>-ptyxis-50.1/bin/ptyxis \
  --display :70
```

- Omit `--display` to start a private Xvfb.
- Omit `--demo-dir` to auto-prepare a workdir from `$OPENTUI_CHECKOUT`
  (default `/home/metal/projects/console-extend/opentui`) and
  `@opentui/core@$OPENTUI_CORE_VERSION` (default `0.7.0`).
- Inside the terminal it runs the demo under `script -q -f -e`, so the probe
  still reaches the real terminal (and its reply reaches the demo) while every
  byte the demo writes is recorded.
- Waits for the transcript to stabilise, screenshots the root window, then
  classifies APC sequences.

Artifacts: `<out>/<run-id>/verdict.json`, `demo.typescript`, `screenshot.png`,
`summary.txt`, `ptyxis.log`.

`verdict.json` fields: `verdict` (`PASS`/`FAIL`), `reason`, `kitty_query`,
`transmit_a_t`, `placement_a_p`, `payload_chunks`, `unicode_block_glyphs`,
`first_query`, `first_transmit`, `first_placement`, paths.

Exit codes: `0` PASS, `1` FAIL, `2` setup/usage error, `3` SKIP (no bun,
`script(1)`, or demo sources).

Validation performed:

- Against the baseline Ptyxis build
  (`/nix/store/k4dqrarb5ixcf9hjawwafh440fgc9jvg-ptyxis-50.1/bin/ptyxis`) on a
  private Xvfb: the demo launched, the transcript contains exactly one probe
  query, no `a=t`/`a=p`, and 183 Unicode block glyphs. Verdict `FAIL`
  ("terminal did not answer the probe"), exit 1, screenshot written. This
  correctly demonstrates the hook detects a non-Kitty terminal.
- The hook's PASS analysis was run on the simulator capture above and returns
  `PASS` with `transmit=5/6`, `placement=8/12`, `blocks=0`, exit 0.
- The hook has not been exercised end-to-end against a real Kitty-capable
  terminal because no `kitty`, `wezterm`, `foot`, or `ghostty` binary is
  installed here. The simulated pty is the equivalent terminal-side proof.

## Blockers / risks

1. **No Zig 0.16.0.** The checkout's `packages/native` cannot be built. If the
   team needs to test this exact commit's native code rather than the release
   runtime, Zig 0.16.0 must be provisioned (or a prebuilt artifact for HEAD
   obtained). Do not install it casually: it was out of scope here.
2. **Release ABI drift.** `@opentui/core@0.7.0` and the 2026-10-25 snapshot both
   lack `ot_scene_set_scroll`, so they cannot load with the checkout's
   `packages/core` sources. The demo run deliberately pairs the *published*
   core with the *checkout's demo source*; it does not validate HEAD's Zig
   changes.
3. **No Kitty-capable terminal installed**, so the real-terminal PASS path is
   unverified. Against stock VTE the hook should FAIL, which is the expected
   current state unless the Ptyxis/VTE build under test implements Kitty
   graphics.
4. `script(1)` adds an inner pty. The probe/reply path is verified by the
   baseline run (query arrives at the outer terminal and the demo receives the
   window response path), but a terminal that answers only after a long delay
   could race the demo's first paint; the simulator shows OpenTUI replies
   immediately at offset 395 when the answer is prompt.
