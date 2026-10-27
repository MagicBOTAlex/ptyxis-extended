# iTerm2 inline images (`OSC 1337 ; File=`) — wire format and conformance spec

Status: normative reference for the Ptyxis/VTE inline-image work.
Sources, in priority order:

1. iTerm2's own documentation, <https://iterm2.com/documentation-images.html> and
   <https://iterm2.com/documentation-escape-codes.html> (fetched 2026-10-27).
2. iTerm2's reference emitter, <https://iterm2.com/utilities/imgcat>, and its reader,
   `sources/VT100/VT100Terminal.m` (`executeFileCommandWithValue:`) and
   `sources/InlineImages/VT100InlineImageHelper.m` in `gnachman/iTerm2`, master.
3. WezTerm, the implementation Ptyxis is being measured against:
   `wezterm-escape-parser/src/osc.rs` (`ITermFileData`), `term/src/terminalstate/iterm.rs`
   (`set_image`), `term/src/terminalstate/image.rs` (`assign_image_to_cells`),
   `wezterm/src/main.rs` (`ImgCatCommand`, `compute_image_cell_dimensions`).

Where iTerm2 and WezTerm disagree, this document says so explicitly (§7) and picks a
normative behaviour. Ptyxis targets **WezTerm visual behaviour with iTerm2 wire
compatibility**: an emitter built for iTerm2 must render correctly, and the result should
match what WezTerm would draw for the same sequence. `MUST`/`MUST NOT`/`SHOULD` are used
in the RFC 2119 sense; every `MUST` has a checklist item in §8.

---

## 1. Wire format

### 1.1 Single-sequence (legacy) form — the only form required

```
              OSC  "1337"  ";"  "File=" <args>  ":"  <base64>  ST
              └─ 0x1b 0x5d ─┘   └ no spaces ┘   └ payload starts right after the colon
```

Byte for byte:

```
1b 5d 31 33 33 37 3b 46 69 6c 65 3d ...args... 3a ...base64... 1b 5c
ESC ]  1  3  3  7  ;  F  i  l  e  =              :              ESC \
```

- `ST` is `ESC \` (`1b 5c`). `BEL` (`07`) is equivalent and MUST be accepted on input.
  iTerm2's docs say "you can use ST in place of ^G anywhere"; iTerm2's own `imgcat`
  emits BEL, WezTerm always emits ST.
- No spaces, tabs or CR/LF are allowed *inside* the sequence. The whitespace in the
  documentation's `ESC ] 1337 ; File =` is explanatory only.
- `<args>` is zero or more `key=value` pairs separated by `;`. The first pair follows
  `File=` directly (the `=` after `File` is not a separator of its own), e.g.
  `File=size=1234;inline=1`.
- The `:` that starts the payload is the **first** `:` in the last `;`-separated
  segment. Because base64 contains no `:` or `;`, this is unambiguous. A trailing `;`
  after the payload is a parse error (WezTerm: "no colon found").
- Empty argument list is legal: `OSC 1337;File=:<base64> ST` (iTerm2 and WezTerm tests
  both cover this). `File=;size=123:<base64>` (empty first pair) MUST also be tolerated.
- `<base64>` is standard base64 (`A–Z a–z 0–9 + /`, `=` padding). Emitters MUST NOT
  insert line breaks. Decoders SHOULD ignore ASCII whitespace (`CR LF TAB SP`) inside the
  payload; iTerm2 does, WezTerm's decoder does not (§7, D12).
- The payload MUST be the last field; nothing may follow it before the terminator.
- An 8-bit `0x9d` OSC introducer and 8-bit `0x9c` ST are accepted by some parsers; a
  receiver MAY accept them but an emitter MUST use the 7-bit forms above.

Minimal example (payload `hello`, i.e. `aGVsbG8=`):

```
\x1b]1337;File=:aGVsbG8=\x1b\\
```

Full example:

```
\x1b]1337;File=size=234;name=c3Bhcmt5LnBuZw==;width=40;preserveAspectRatio=1;inline=1;doNotMoveCursor=1:iVBORw0KGgo...\x1b\\
```

### 1.2 Multipart form (iTerm2 ≥ 3.5, optional)

iTerm2 added a chunked transfer for tmux, and its current `imgcat` uses it **by default**:

```
OSC 1337 ; MultipartFile = <same args as File=> ST
OSC 1337 ; FilePart = <base64 chunk> ST        (one or more, in order)
OSC 1337 ; FileEnd ST
```

Each control sequence is limited to 1,048,576 bytes by iTerm2; its `imgcat` uses 200-byte
chunks for old tmux. WezTerm has no multipart support. A receiver that supports only
`File=` MUST ignore `MultipartFile`/`FilePart`/`FileEnd` as unknown OSC 1337 commands and
MUST NOT render partial data or move the cursor. (Consequence: iTerm2's current `imgcat`
output will not render on such a terminal; emitters targeting this implementation should
use the single-sequence form.)

### 1.3 Size limits

| Limit | iTerm2 | WezTerm | This spec |
|---|---|---|---|
| OSC sequence length | 1,048,576 bytes | unbounded (`Vec<u8>`); max 64 `;` segments | 1 MiB per sequence; longer → drop whole sequence |
| Decoded image | not documented | `w*h*4 > 100,000,000` → reject | 64 MiB decoded, and 25 megapixels (`w*h ≤ 25e6`) |
| Height | 255 cell rows (8-bit line index) | no explicit cap | 255 rows; scale down preserving aspect |
| Zero dimensions | `MAX(1, …)` | reject 0×0 | drop, no cursor move |

Any rejection is silent to the application and leaves the cursor and screen unchanged.

---

## 2. Parameters

All keys are **case-sensitive**. Unknown keys MUST be ignored (iTerm2 and WezTerm both do;
this is how `type=`/`mode=`/`inset*` stay forward-compatible). Duplicate keys: last one
wins (WezTerm's `HashMap` insert; iTerm2's dictionary assignment).

| Key | Value syntax | Default if absent | Meaning |
|---|---|---|---|
| `name` | base64 of UTF-8 filename bytes | "Unnamed file" | Filename for downloads/history. **Never** rendered inline and never used to pick a decoder. Base64 is what makes `;`, `:`, `=` and newlines safe. |
| `size` | decimal integer, bytes | 0 | Size of the *decoded* payload, used only for progress/validation. Advisory: a mismatch MUST NOT prevent rendering. |
| `width` | `auto` \| `N` \| `Npx` \| `N%` | `auto` | Requested display width. `N` = N character cells, `Npx` = N device pixels, `N%` = N percent of terminal width (0–100). |
| `height` | same as `width` | `auto` | Requested display height; `%` is relative to terminal height. |
| `preserveAspectRatio` | `0` \| `1` | `1` | If 0, stretch to the requested width×height. If 1 (or absent), fit inside the requested box without stretching. Only meaningful when both dimensions are given. |
| `inline` | `0` \| `1` | `0` | 1 = display in the terminal. 0/absent = file download, no visual output. |
| `doNotMoveCursor` | `0` \| `1` | `0` | 1 = do not move the cursor after drawing. WezTerm extension, ignored by iTerm2's `File=` reader (§7, D9). |
| `type` | mime type, `.ext`, or language name | auto-detect | iTerm2 only: hint for non-image native rendering (e.g. `text/markdown`). Unknown → ignore. |
| `mode` | `regular` \| `wide` | `regular` | iTerm2 only: text-document layout. Unknown → ignore. |
| `insetTop/Left/Bottom/Right` | decimal points | 0 | iTerm2 only, undocumented in the table but parsed by its reader. Unknown → ignore. |

Value rules:

- Dimension numbers are non-negative decimal integers, no sign, no whitespace, lowercase
  `px`/`%` suffix only. `auto` is lowercase only.
- `%` is clamped to 0–100.
- An unparseable dimension MUST be treated as `auto`, not as a reason to drop the image
  (WezTerm does this; iTerm2 ends up with 0 cells).
- Booleans: **only the exact string `0` means false** in WezTerm; any other value is true.
  iTerm2 uses a general bool parse (`0`/`NO`/`false`). Normative: parse `0` as false, `1`
  as true, and treat any other value as the default for that key. `inline=false` is
  therefore *true* on WezTerm but false on iTerm2 — emitters MUST send `0`/`1` only.
- iTerm2 caps height at 255 cell rows; a taller image is scaled down preserving aspect.

---

## 3. Sizing algorithm

Inputs, in device pixels:

```
cell_w, cell_h   terminal cell size (integer ≥ 1); if either is 0, ignore the image
cols, rows       terminal grid dimensions
vw = cols*cell_w ; vh = rows*cell_h          viewport in pixels
cw, ch           cursor column/row at the time the sequence is processed
native_w, native_h   decoded image dimensions
ar = native_w / native_h
```

### 3.1 Unit conversion

```
resolve(value, cell_px, cell_count) -> pixels | None:
    "auto"                -> None
    "<n>"                 -> n * cell_px          # cells
    "<n>px"               -> n                    # pixels
    "<n>%"                -> round_half_up( clamp(n,0,100) / 100 * cell_count * cell_px )
    anything else         -> None                 # treat as auto
```

`round_half_up` = `floor(x + 0.5)`. Use the same rule for every derived dimension so
results are deterministic across implementations. (iTerm2 keeps fractional points and
rounds the *cell count* up; WezTerm truncates. A ±1 px difference is acceptable; the
aspect-ratio error must stay below one cell — see C21.)

### 3.2 Normative algorithm

```
w = resolve(width,  cell_w, cols)
h = resolve(height, cell_h, rows)

# A "box" is the cell region reserved on the grid; "draw" is the bitmap's
# painted pixel size inside it; (off_x, off_y) centres the bitmap in the box.

if w is None and h is None:
    # native size, clamped to the viewport preserving aspect (WezTerm)
    bw, bh = native_w, native_h
    if bw > vw or bh > vh:
        s = min(vw / bw, vh / bh)
        bw, bh = max(1, floor(bw*s)), max(1, floor(bh*s))
    box_w, box_h = bw, bh
    draw_w, draw_h = bw, bh
    off_x = off_y = 0

elif w is None:                       # height given, width auto
    h = max(1, round_half_up(h))
    w = max(1, round_half_up(h * ar))
    box_w, box_h = draw_w, draw_h = w, h
    off_x = off_y = 0

elif h is None:                       # width given, height auto
    w = max(1, round_half_up(w))
    h = max(1, round_half_up(w / ar))
    box_w, box_h = draw_w, draw_h = w, h
    off_x = off_y = 0

elif preserve_aspect_ratio:           # both given, preserve = 1
    # reserve the requested box, letterbox the bitmap inside it (iTerm2)
    box_w, box_h = w, h
    s = min(w / native_w, h / native_h)
    draw_w = max(1, round_half_up(native_w * s))
    draw_h = max(1, round_half_up(native_h * s))
    off_x = (box_w - draw_w) // 2
    off_y = (box_h - draw_h) // 2

else:                                 # both given, preserve = 0
    box_w, box_h = draw_w, draw_h = w, h
    off_x = off_y = 0

# Width safety clamp: never paint outside the grid. Keep aspect.
if box_w > vw:
    s = vw / box_w
    box_w, draw_w = vw, max(1, floor(draw_w * s))
    box_h, draw_h = max(1, floor(box_h * s)), max(1, floor(draw_h * s))

# iTerm2 structural cap: at most 255 rows of image cells.
if box_h > 255 * cell_h:
    s = (255 * cell_h) / box_h
    box_w, draw_w = max(1, floor(box_w * s)), max(1, floor(draw_w * s))
    box_h, draw_h = 255 * cell_h, max(1, floor(draw_h * s))
```

Let:

```
img_cols = ceil(box_w / cell_w)
img_rows = ceil(box_h / cell_h)
```

be the cell footprint (what the cursor advances over). The bitmap is painted at
`draw_w × draw_h` at `(cw*cell_w + off_x, ch*cell_h + off_y)`.

Notes and decisions:

- **Both dimensions given + `preserveAspectRatio=1`**: iTerm2 reserves the requested
  `w×h` cell box and letterboxes (or pillarboxes) the bitmap inside it, centred; the
  cursor advances over the full box. WezTerm instead *discards* the requested height and
  recomputes `h = w / ar`, so its footprint is the bitmap's. This spec follows iTerm2
  (§7, D4). The bitmap size is the same whenever the box is wider than the image aspect;
  only the reserved rows and centring differ.
- **Only one dimension given**: the other is derived from the aspect ratio. The
  `preserveAspectRatio` flag is irrelevant here because there is nothing to stretch.
- **Native auto sizing** is clamped to the *viewport*, so an unqualified `imgcat file.png`
  always fits on screen without scrolling away (WezTerm). iTerm2 instead clamps to the
  remaining width and the 255-row cap, so it can produce an image taller than the screen.
- **Explicit dimensions are not clamped to the viewport height.** A tall explicit image
  scrolls the screen (up to the 255-row cap); it must not be squeezed to `vh`.
- **Do not use the remaining width** (`(cols-cw)*cell_w`) as the scale target. An image
  wider than the space to the right of the cursor is normal; it is clipped at the right
  grid edge (§5.3). iTerm2's `maxWidth = grid.width - cursorX` clamp is a quirk; do not
  copy it.
- The box dimensions may be non-integral multiples of a cell; the occupied grid area is
  `ceil(box_w/cell_w) × ceil(box_h/cell_h)` cells.
- If any requested dimension resolves to 0 px (`width=0`, `width=0px`, `width=0%`), the
  image has zero area: drop it and do not move the cursor. Do not silently substitute
  `auto` or 1 px (WezTerm rejects it at `assign_image_to_cells`; iTerm2 clamps to 1 cell —
  see §7, D14).

### 3.3 Worked examples

Cell 8×16 px, grid 80×24 (viewport 640×384):

| Sequence | Result |
|---|---|
| 800×600 PNG, no width/height | `s = min(640/800, 384/600) = 0.64` → 512×384 px → 64×24 cells |
| 800×600 PNG, `width=40` | 320 px wide, `h = 320/(800/600) = 240` px → 40×15 cells |
| 800×600 PNG, `width=50%` | 0.5·640 = 320 px → 40×15 cells |
| 800×600 PNG, `height=10px` | `w = 10·(4/3) = 13.3 → 13` px → 2×1 cells |
| 800×600 PNG, `width=200px;height=200px` (preserve=1) | box 200×200 px → footprint 25×13 cells; bitmap scaled to 200×150 and centred vertically (10 bitmap rows, ≈3 blank rows total) |
| same, `preserveAspectRatio=0` | bitmap stretched to 200×200 px → 25×13 cells (distorted) |
| 800×600 PNG, `width=200px;height=100px` (preserve=1) | box 200×100 → 25×7 cells; bitmap 133×100 pillarboxed horizontally (~8 blank columns) |
| 800×600 PNG, `width=200%` | 1280 px → clamped to 640×480 px → 80×30 cells (scrolls) |

---

## 4. Cursor and layout semantics

Let `start = (cw, ch)` be the cursor when the sequence is processed,
`img_cols = ceil(box_w/cell_w)`, `img_rows = ceil(box_h/cell_h)`, and
`k = img_cols×img_rows` the cells reserved on the grid.

Default (`doNotMoveCursor` absent or 0):

1. The image is written into the grid starting at `start`, row-major, overwriting the
   cells it covers. Cells outside the grid (right edge, below the last row) are clipped.
2. If `ch + img_rows > rows`, the screen scrolls up by
   `ch + img_rows - rows` lines as the image is placed; the image's anchor moves up with
   the text, so the bottom row of the image ends on the last screen row. Content scrolled
   off the top (including earlier images) goes to scrollback.
3. The cursor ends at the **bottom-right** of the image, on the image's last row:
   `row = ch + img_rows - 1`, `col = min(cw + img_cols, cols - 1)` (clamped at the right
   margin, as WezTerm's `set_cursor_pos` does). It does **not** move to column 0 of the
   following line.
4. Consequently, output that follows the escape sequence continues on the same line as
   the bottom of the image (and at the right margin it overwrites the image's
   bottom-right cell). Emitters that want subsequent text below the image MUST send a
   newline after the terminating ST/BEL. iTerm2's `imgcat` and `wezterm imgcat` both do
   this (`printf '\n'`, `println!`).
5. If `cw + img_cols ≥ cols`, the cursor is clamped to the last column, i.e. on top of the
   image's bottom-right cell; the terminal's normal pending-wrap rule applies to the next
   printed character. Two images emitted back-to-back therefore sit side by side until the
   cursor reaches the margin; the next one starts *on* the last column and overwrites that
   cell instead of wrapping.

`doNotMoveCursor=1`:

1. The image is still painted starting at `start`; rows that would extend below the
   screen are clipped rather than scrolled (step 3).
2. The cursor position is unchanged (same column, same row). Subsequent text overwrites
   the image where it lands. Shell prompts will overwrite the image; this is intended.
3. WezTerm additionally clamps the painted height to `rows - ch` in this mode so the image
   never scrolls; iTerm2's Kitty equivalent does the same. Normative: with
   `doNotMoveCursor=1`, do not scroll; clip at the bottom edge (§7, D10).

Text over images: an image is a property of the cells it occupies, not an independent
overlay. Printing a character into a covered cell replaces that cell (destroying that
portion of the image); erasing cells removes the corresponding portions. Two images that
overlap: the later one wins in the overlap. Cells keep their image reference when
scrolled, so the picture scrolls with the text and back.

---

## 5. Lifecycle and edge cases

### 5.1 Multiple images

- Each `File=` sequence is independent and anchored at the cursor position current at
  that moment. Because the cursor ends at the image's bottom-right, images emitted
  back-to-back on one line sit side by side with no gap.
- Overlapping images are allowed; z-order is "later on top" within the same cell. The
  renderer MUST NOT assume placements are disjoint.
- Many small images in one line must not leak: each is a separate texture/placement.

### 5.2 Scrolling and history

- Image cell data is stored on grid rows (absolute/stable row numbers), never in
  viewport-relative coordinates. Scrolling (including `scroll_delta`/`insert_delta`
  changes) must move images with their rows.
- Partial visibility clips at the top/bottom viewport edge; do not scale.
- When a scrollback row is evicted by the scrollback limit, its image references are
  released; memory must not grow with history.
- Scrolling back to view history must show images that were scrolled off.

### 5.3 Horizontal overflow

- An image starting at column `cw` wider than `cols - cw` is clipped at the right grid
  edge. It is not wrapped and not scaled down unless §3.2's width clamp applies
  (`w > vw`).
- Cells to the right of the grid edge may be retained in the model (WezTerm does this; they
  become visible if the window is widened) but MUST NOT be painted outside the grid.
- The cursor advance uses the full `img_cols` before clamping to the right margin (§4).

### 5.4 Alternate screen

- Normal and alternate screens hold independent image sets. Entering/leaving the
  alternate screen must not move or delete the other screen's images.
- Leaving the alternate screen discards its images (the alt screen is cleared).
- `CSI ? 1049 h/l` (save/restore cursor + alt screen) follows the same rule.

### 5.5 Reset, clear, erase

| Operation | Effect on images |
|---|---|
| `ED 0/1` (erase in display) | Erase image data in the erased cells; a fully erased image is freed. |
| `EL 0/1/2` (erase in line) | Same, per line. |
| `ED 2` (erase display) | Clear all visible image cells; image data may be freed. |
| `ED 3` (erase scrollback) | Free all images in scrollback. |
| `RIS` / terminal reset | Free every image on both screens. |
| `DECSTR` (soft reset) | WezTerm clears only Kitty placements; iTerm images survive. Normative: leave cells (and images) alone. |
| Reflow/resize that discards rows | Free images on discarded rows. |

The current VTE patch clears both screens' image vectors on `reset` only; it does not
handle erases or scrollback eviction (see §9).

### 5.6 Resize and reflow

- Resizing changes `cell_w/cell_h` (font/zoom) or `cols/rows` (window).
- An image anchored at absolute row R, column C stays anchored there on resize; it is
  **not** re-scaled and not re-flowed with text. On width change, text reflow may move the
  anchor's content; the image stays at its numeric cell anchor (iTerm2 behaviour) and is
  clipped if `C ≥ cols`.
- On font/zoom change, re-render the texture at the same pixel dimensions (the image does
  not grow with the font); recompute `img_cols/img_rows` for clipping if needed. WezTerm
  instead stores fractional texture coordinates per cell, so its images *do* stretch with
  the cell size — an artefact of that design, not a protocol requirement (§7, D21).
- Images in rows that reflow away must be dropped, not orphaned.

### 5.7 Payload and decode errors

- Invalid/truncated base64, invalid image data, unsupported format: drop silently. No
  replacement glyph, no error text, no cursor movement, no scroll.
- Zero-area image (`0×0` after decode, or the sequence resolves to 0 px): ignore. Do not
  advance the cursor.
- Oversized payload (per §1.3) or `w*h > 25e6`: drop before allocating/decoding where
  possible; never block the UI thread decoding a 500 MB PNG.
- `inline=1` with a non-image payload (text, PDF, SVG): ignore for rendering. If the
  implementation later supports iTerm2's `type=`/`mode=`, native text rendering is
  allowed; otherwise ignore.
- `inline=0` (or absent): it is a download. A terminal without a download UI MUST ignore
  it: no render, no cursor move, no file written (writing attacker-controlled paths is a
  security bug). `name` is only used to label a user-visible download.
- An image that decodes but has enormous dimensions is rejected by the pixel cap before
  texture creation.
- Unknown/unsupported image formats: ignore. Minimum required: PNG and JPEG; GIF (first
  frame) and WebP SHOULD be supported.

### 5.8 Parsing edge cases

- A sequence with no terminator (EOF inside OSC) is discarded; nothing renders.
- `CAN`/`SUB` inside OSC aborts the sequence (parser level).
- Arguments after the payload colon are part of the base64 and will normally fail to
  decode → drop.
- Non-UTF-8 bytes in keys/values: ignore the whole sequence or the offending pair; never
  crash. (`name` is base64, so this only happens with malformed input.)
- Bare tokens (an argument with no `=`) are ignored, along with the rest of the arguments;
  WezTerm instead drops the whole image — ignoring is preferred for compatibility.
- The OSC dispatcher must not collide with other OSC 1337 commands (`SetMark`,
  `CurrentDir`, `SetColors`, `CursorShape`, …): only the `File`/`MultipartFile`/`FilePart`/
  `FileEnd` keywords are image transfer.

---

## 6. Security

- Treat the payload as untrusted: cap length and pixels before decode; decode off the
  main loop or with a time budget if possible.
- Never write to disk for `inline=1`; never write at all for `inline=0` without a user
  gesture/configured download directory.
- `name` is display metadata only. Do not use it as a path component without
  sanitisation (`../`, `/`, NUL, absolute paths).
- Do not follow URLs, do not decode PDF/SVG with a general-purpose renderer.

---

## 7. Divergences: iTerm2 vs WezTerm

| # | Topic | iTerm2 | WezTerm | Normative for Ptyxis |
|---|---|---|---|---|
| D1 | `name` on the wire | base64 UTF-8; default "Unnamed file" | base64 when present, but `wezterm imgcat` always sends `name=None` | base64, optional |
| D2 | `size` | advisory, default 0 | always emitted as `data.len()`, never validated | advisory |
| D3 | native auto clamp | width to `grid.width - cursorX`, height to 255 rows; may exceed viewport height | both dimensions to viewport pixels, preserving aspect | WezTerm (viewport) |
| D4 | both dims + preserve=1 | reserves the requested W×H cell box, letterboxes the bitmap inside it; footprint = box | ignores requested height, computes `h=w/ar`; footprint = bitmap | iTerm2 (reserve box, letterbox) |
| D5 | `%` conversion | `ceil(cols*pct/100)` cells, fractional points kept | `pct/100*cols*cell_px` truncated to px | round-half-up to px |
| D6 | derived dimension rounding | fractional points; cells rounded up | integer px, truncated | round-half-up |
| D7 | explicit width clamp | clamped to grid width | no clamp | clamp to viewport |
| D8 | height cap | 255 cell rows | none (only 25 MP) | 255 |
| D9 | `doNotMoveCursor` | **not read** by the `File=` parser (the `C=1` equivalent exists only in its Kitty protocol) | supported, emitted by `--no-move-cursor` | support (WezTerm compat) |
| D10 | `doNotMoveCursor` + tall image | n/a (ignored) | clips painted height to remaining rows, no scroll | clip, no scroll |
| D11 | terminator emitted | BEL (imgcat) | ST | ST preferred; BEL accepted |
| D12 | base64 whitespace | strips CR/LF before decoding (`NSData+iTerm.m`) | rejected (strict STANDARD) | SHOULD tolerate CR/LF/space |
| D13 | multipart | `MultipartFile`/`FilePart`/`FileEnd`, default in current imgcat | unsupported | ignore safely |
| D14 | invalid dimension | 0 cells (`intValue`) | `auto` | `auto`; explicit `0` drops the image |
| D15 | truthiness | `0/NO/false` false | only `"0"` false | `0`/`1` only on emit |
| D16 | cursor end | bottom-right of image (`cursorX += width`, last row) | bottom-right, x clamped to `cols-1` | bottom-right, clamped |
| D17 | trailing newline | `imgcat` prints `\n` after BEL | `println!` after ST | emitter SHOULD append `\n` |
| D18 | `type=`/`mode=`/`inset*` | parsed, native text rendering | ignored | ignore |
| D19 | `inline` default | 0 (download) | 0 (download) | 0 |
| D20 | `preserveAspectRatio` default | 1 | 1 | 1 |
| D21 | font/zoom change | image keeps its pixel size | image stretches with the cell (fractional texture coords) | keep pixel size |

---

## 8. Conformance checklist

Each item is a testable assertion. `[MUST]` items are release-blocking for "renders
iTerm2/WezTerm images correctly".

**Wire format**

1. **C1** [MUST] Emitted bytes match `1b 5d "1337;File=" … 3a <base64> 1b 5c`; no spaces,
   CR, LF or extra `;` inside the sequence; payload last.
2. **C2** [MUST] `BEL` (`07`), `ST` (`1b 5c`) and 8-bit `9c` terminate the sequence
   identically; a missing terminator renders nothing.
3. **C3** [MUST] `File=:<b64>` (no args) and `File=;size=N:<b64>` (empty first pair) both
   render.
4. **C4** [MUST] Arguments are `;`-separated `key=value`, parsed at the first `=`;
   duplicate keys take the last value; unknown keys and bare tokens are ignored (iTerm2;
   WezTerm drops the whole sequence on a bare non-final token — do not copy that).
5. **C5** [MUST] Keys are case-sensitive: `preserveAspectRatio`, `doNotMoveCursor`,
   `inline`; `PreserveAspectRatio=0` has no effect.
6. **C6** [MUST] `name` is base64-decoded for display only and never affects rendering;
   a missing/invalid `name` is harmless.
7. **C7** [MUST] `size` is advisory: a wrong value does not change rendering.
8. **C8** [SHOULD] Decoder tolerates whitespace/newlines in the base64 payload and
   tolerates missing padding. (WezTerm does not; iTerm2 does.)
9. **C9** [MUST] Invalid base64 / non-image payload / truncated data is dropped silently
   with no cursor movement and no error text.

**Parameters and sizing**

10. **C10** [MUST] Bare `N` = N cells, `Npx` = N pixels, `N%` = N% of the viewport
    dimension (0–100 clamp), `auto`/absent = automatic; unparseable value = automatic.
    A resolved size of 0 px is dropped without drawing or moving the cursor.
11. **C11** [MUST] No width and no height → native pixel size, scaled down preserving
    aspect if it exceeds the viewport.
12. **C12** [MUST] Only width given → height derived from aspect; only height given →
    width derived from aspect.
13. **C13** [MUST] Both given with `preserveAspectRatio=1` (default) → the requested box is
    reserved and the bitmap is fitted inside it, centred, aspect preserved, not stretched;
    both given with `0` → the bitmap stretches to exactly the box.
14. **C14** [MUST] `preserveAspectRatio` alone (no width/height) has no visible effect.
15. **C15** [MUST] Image occupying more than 255 rows is scaled down preserving aspect
    (iTerm2 cap); explicit tall images scroll rather than being squeezed to the viewport.
16. **C16** [MUST] Occupied cells are `ceil(box_w/cell_w) × ceil(box_h/cell_h)`; the bitmap
    is painted at `draw_w×draw_h` centred in the box and anchored at the starting cell
    origin (for the single-dimension and native cases, box = bitmap and offsets are 0).
17. **C17** [MUST] `inline` absent or `0` → nothing is drawn and the cursor does not move;
    `inline=1` → draw. `inline=0` never writes a file in a terminal without a download UI.

**Cursor and layout**

18. **C18** [MUST] Default cursor end is `row = start_row + img_rows - 1`,
    `col = min(start_col + img_cols, cols - 1)` — bottom-right of the image, not column 0
    of the next line.
19. **C19** [MUST] An image whose bottom exceeds the screen scrolls the screen by the
    overflow; the image scrolls with the text and its bottom row ends on the last row.
20. **C20** [MUST] `doNotMoveCursor=1` leaves the cursor exactly where it was and does not
    scroll; the image is clipped at the bottom edge.
21. **C21** [MUST] Aspect ratio error after sizing is < 1 cell in each dimension
    (guards rounding differences between iTerm2/WezTerm); every drawn dimension is ≥ 1 px.
22. **C22** [MUST] Printing over an image cell replaces that cell; erasing cells removes
    the covered image portions; the rest of the image survives.
23. **C23** [MUST] Two images emitted back-to-back on one line do not corrupt each other;
    later images paint over earlier ones in cells they share (and a third image emitted at
    the right margin starts on the last column, overwriting that cell by design).
24. **C24** [MUST] Images clipped at the right grid edge do not paint outside the grid and
    do not wrap.

**Lifecycle**

25. **C25** [MUST] Scrolling (including scrollback) moves images with their rows;
    scrolling back shows them again; images scrolled off the top are clipped, not scaled.
26. **C26** [MUST] Scrollback eviction frees image memory; repeated images do not grow
    memory without bound.
27. **C27** [MUST] `ED`/`EL`/`ED 2`/`ED 3`/`RIS` remove the corresponding image data;
    `RIS` frees all images on both screens.
28. **C28** [MUST] Normal and alternate screens keep independent images; leaving the alt
    screen discards only alt-screen images.
29. **C29** [MUST] Resize/zoom does not scale images; anchors stay at their absolute grid
    rows/columns and are clipped when off-grid; discarded rows free their images.
30. **C30** [MUST] Payload/pixel limits are enforced before decode/allocation; an
    oversized sequence is dropped without side effects.
31. **C31** [SHOULD] Zero-area images, unsupported formats and `inline=1` text documents
    are ignored without side effects.
32. **C32** [SHOULD] GIF renders at least its first frame; animated GIFs may animate.
33. **C33** [MUST] Terminal cell size 0/unknown → ignore the image (no divide-by-zero).
34. **C34** [SHOULD] `MultipartFile`/`FilePart`/`FileEnd` are ignored safely (no partial
    render, no cursor move) when unsupported.
35. **C35** [MUST] A malformed/untrusted sequence cannot cause a crash, hang, arbitrary
    file write, or unbounded allocation.

Cross-check: C1–C17 cover every parameter in §2; C18–C35 cover the lifecycle matrix in §5.

---

## 9. Gap list for the current minimal VTE patch

The patch at `nix/vte.patch` on `main` (commit `9a24934`) implements the envelope, base64
decode, `GdkTexture` creation, native-size viewport clamping, `inline`, and
`doNotMoveCursor`, and stores placements in a per-screen vector. Relative to this spec it
is missing or unverified:

1. `width`/`height` are ignored entirely (not even parsed) — no cells/px/% handling, no
   derived dimension, no `preserveAspectRatio` letterbox/stretch (C10–C14).
2. No 255-row cap; explicit tall images rely on cursor scrolling without clamping (C15).
3. No right-edge/width clamp for oversized images; `draw_image` is called with the raw
   anchor and may paint outside the grid (C24).
4. Placements are an overlay vector, not cell attributes: text printed over an image does
   not replace it, and `ED`/`EL` do not remove image portions (C22, C27).
5. No cleanup on scrollback eviction; `m_screen->images` grows until reset (C25, C26).
6. `reset` clears both screens, but alt-screen enter/leave semantics and `ED 3` are not
   implemented (C27, C28).
7. Anchor row is stored from `m_screen->cursor.row` (grid-absolute, consistent with
   `row_to_pixel`) — verify after `insert_delta` changes and when drawing while scrolled
   back; no re-anchoring on resize (C25, C29).
8. No payload size limit, no pixel cap, no decode timeout: a huge base64/PNG is decoded
   synchronously (C30, C35).
9. `inline` only accepts the exact string `"1"`; `inline=true` is treated as a download
   (WezTerm: true) (C17, §7 D15).
10. No pruning of images whose rows were discarded; no texture reuse/cache for repeated
    payloads.
11. No clipping of the painted rect when the image is partially scrolled off the top;
    `draw_image` receives the unclipped height/y.
12. GIF animation is not implemented (first frame is acceptable per C32, but a static
    texture of an animated GIF depends on the loader).
13. `name`/`size`/`type`/`mode` are ignored (acceptable for rendering; `size` must stay
    advisory).
14. Cursor ends bottom-right via `move_cursor_forward`, which clamps at the last column;
    this matches the spec's clamp but not iTerm2's pending-wrap behaviour (C18).

---

## 10. Emitter and test vectors

`scripts/emit_imgcat.py` implements this spec's wire format and can generate payloads
without image files:

```sh
python3 scripts/emit_imgcat.py --png 80x40 --width 10 --inline 1 > /tmp/img.osc
python3 scripts/emit_imgcat.py --png 80x40 --width 10 --inline 1 --dry-run
python3 scripts/emit_imgcat.py --png 80x40 --width 50% --name "héllo.png" --terminator bel | xxd | head
python3 scripts/emit_imgcat.py --matrix --matrix-emit > /tmp/matrix.bin   # 15 cases, one per line
```

It never prompts; exit codes are 0 success, 1 I/O/decode error, 2 usage/validation error.
`--dry-run` prints the exact bytes as a Python `repr` plus the decoded metadata and a
base64 round-trip check, which is what the test harness should assert against.

Two harness cautions:

- The protocol default for `inline` is **0 (download)**. The emitter omits every parameter
  unless asked, so `emit_imgcat.py pic.png` emits a sequence that a correct terminal will
  *not* render. Always pass `--inline 1` for visual tests.
- `--matrix` writes each case terminated by a newline *after* the ST/BEL, one case per line,
  so the harness must strip the trailing `\n` before feeding a case to the terminal. Case 1
  is intentionally parameter-less (a download); use case 2 or later for rendering tests.

Canonical vectors (base64 of `hello` is `aGVsbG8=`):

| Case | Bytes |
|---|---|
| minimal, ST | `\x1b]1337;File=:aGVsbG8=\x1b\\` |
| minimal, BEL | `\x1b]1337;File=:aGVsbG8=\x07` |
| inline, width 10 cells | `\x1b]1337;File=width=10;inline=1:aGVsbG8=\x1b\\` |
| full | `\x1b]1337;File=size=5;name=aGVsbG8ucG5n;width=10px;height=auto;preserveAspectRatio=0;inline=1;doNotMoveCursor=1:aGVsbG8=\x1b\\` |

Expected renderer behaviour for the first three, on an 80×24 grid with 8×16 cells, with
the cursor at (0,0): minimal → `hello` is not an image, so nothing renders and the cursor
stays at (0,0). The test harness should use a real 64×32 PNG for visual assertions and
these vectors for parser assertions (with a valid 1×1 PNG substituted for `aGVsbG8=`).
