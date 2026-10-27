# Kitty graphics protocol — the OpenTUI subset and the minimum terminal contract

Status: normative reference for adding Kitty graphics to the Ptyxis/VTE patch, sized to
what OpenCode's TUI (OpenTUI) actually emits.

Sources:

1. Kitty's specification, <https://sw.kovidgoyal.net/kitty/graphics-protocol/> (fetched
   2026-10-27; section numbers below refer to it).
2. OpenTUI, commit `7f2d08c`, in `/home/metal/projects/console-extend/opentui`:
   - `packages/native/src/terminal-image.zig` — all encoders (transmit, placement, delete,
     zlib/raw conversion).
   - `packages/native/src/kitty-transport.zig` — transport mode (`raw` default) and reply
     handling for file transport.
   - `packages/native/src/terminal.zig:378,1135-1150` — probe emission and reply parsing
     (this is the capability gate OpenTUI actually uses).
   - `packages/native/src/ansi.zig:352` — the probe constant.
   - `packages/native/src/renderer.zig` — placement ordering, reservations, deletes.
3. Kitty implementation, `kitty/graphics.c` (quiet-mode behaviour).

`MUST`/`MUST NOT`/`SHOULD` are RFC 2119. Every `MUST` has a checklist item in §11.
Anything marked **[not needed]** is deliberately out of scope for OpenTUI.

> **Capability gate in one line.** OpenTUI sends
> `\x1b_Gi=31337,s=1,v=1,a=q,t=d,f=24;AAAA\x1b\\` and enables Kitty only if it gets
> back `\x1b_Gi=31337;OK\x1b\\` (same `i=31337`, message `OK`, **ST** terminator) before
> its DA1 probe is answered. No reply, a BEL-terminated reply, or a reply after DA1 makes
> the first frame fall back to Unicode blocks (a late reply can still enable Kitty
> afterwards). Details in §5.

---

## 1. Envelope

```
With payload:     APC  "G" <control-data> ";" <payload> ST
No payload:       APC  "G" <control-data>            ST
                  1b 5f 47                1b 5c
```

- `ESC _` (`1b 5f`) is APC; the literal `G` selects the graphics protocol.
- `<control-data>` is a comma-separated list of `key=value` pairs, ASCII, no spaces.
  A trailing or leading comma is undefined; emitters MUST NOT produce one.
- Commands that carry image data (transmit, query, frame) put `;` between the control
  data and the base64 payload. Commands with no payload (placement, delete, animation
  control) **omit the `;` entirely** — kitty's own examples and every OpenTUI placement
  and delete are `ESC_G<control>ESC\`. A receiver MUST accept both forms: split at the
  first `;` if present, otherwise treat the whole body as control data.
- `<payload>` is standard base64 (RFC 4648, `A–Z a–z 0–9 + /`, `=` padding). No line
  breaks, no whitespace.
- Terminator is ST (`ESC \`, `1b 5c`). OpenTUI only parses ST-terminated replies; BEL is
  **not** accepted for Kitty graphics by OpenTUI and MUST NOT be emitted. (Kitty itself
  treats APC as ST-terminated; a receiver MAY also accept BEL, but do not rely on it.)
- One APC carries one command. A chunked transmission is a sequence of APCs (§4).
- Unknown control keys MUST be ignored; unknown actions SHOULD be answered with
  `EINVAL` (or silence if `q` suppresses it).

Minimal valid command (payload-less form):

```
\x1b_Ga=d\x1b\\            # delete all visible placements
```

---

## 2. Control keys

All integers are 32-bit. Defaults are what a receiver must assume when the key is absent.

| Key | Values | Default | Meaning |
|---|---|---|---|
| `a` | `t`, `T`, `q`, `p`, `d`, `f`, `a`, `c` | `t` | Action (see §3). |
| `q` | `0`, `1`, `2` | `0` | Reply suppression: `0` reply to all, `1` suppress `OK` (errors still sent), `2` suppress everything. |
| `f` | `24`, `32`, `100` | `32` | Pixel format: RGB, RGBA, PNG. |
| `t` | `d`, `f`, `t`, `s` | `d` | Transmission medium: direct, file, temp file, shared memory. |
| `s` | positive int | `0` | Image width in pixels (required for `f=24`/`f=32`; ignored for PNG). |
| `v` | positive int | `0` | Image height in pixels (same). |
| `S` | positive int | `0` | Byte count to read from a file/shm medium. |
| `O` | positive int | `0` | Byte offset for file/shm. |
| `i` | `1..4294967295` | `0` | Image id. `0` means "no id" and MUST NOT be used for storage that is later addressed. |
| `I` | `0..4294967295` | `0` | Image *number* (non-unique; reply returns the allocated id). **[not needed]** |
| `p` | `1..4294967295` | `0` | Placement id, scoped to the image id. `p=0` means anonymous. |
| `o` | `z` | absent | Compression: zlib (RFC 1950) applied before base64. |
| `m` | `0`, `1` | `0` | More chunks follow (`1`) / last chunk (`0`). |
| `x`, `y` | non-negative int | `0` | Source rectangle top-left in image pixels. |
| `w`, `h` | positive int | `0` | Source rectangle width/height in pixels; `0` = rest of image. |
| `X`, `Y` | non-negative int | `0` | Pixel offset inside the first cell. Must be smaller than a cell. **[not needed]** |
| `c` | positive int | `0` | Display rectangle width in cells. |
| `r` | positive int | `0` | Display rectangle height in cells. |
| `C` | `0`, `1` | `0` | Cursor policy: `0` move after the image, `1` do not move. |
| `z` | signed 32-bit | `0` | Stacking order; negative is below text. |
| `d` | `a A c C n N i I p P q Q r R x X y Y z Z` | `a` | Delete selector (§6). |
| `U` | `0`, `1` | `0` | Unicode-placeholder virtual placement. **[not needed]** |
| `P`, `Q`, `H`, `V` | ints | `0` | Relative placements. **[not needed]** |
| `N` | bitmask | `0` | Usage hints. **[not needed]** |

OpenTUI emits only: `a`, `f`, `s`, `v`, `i`, `o`, `m`, `q`, `p`, `c`, `r`, `x`, `y`, `w`,
`h`, `C`, `z`, `d`. A conforming terminal still SHOULD parse-and-ignore everything else.

---

## 3. Actions

| `a` | Name | Semantics |
|---|---|---|
| `t` | transmit | Store the decoded image under `i`. Does not display. Default when `a` is absent. |
| `T` | transmit + display | Transmit, then place at the cursor as if `a=p` followed in the same command. **[not needed: OpenTUI uses `t` then `p`]** |
| `q` | query | Try to load/validate the payload and reply `OK`/error, but **store nothing and replace nothing**. This is the capability probe (§5). |
| `p` | put/placement | Display a previously transmitted image `i` at the cursor, optionally with placement id `p` and geometry keys. |
| `d` | delete | Delete placements/images per `d` selector (§6). |
| `f` | frame | Transmit animation frame data. **[not needed]** |
| `a`,`c` | animation control/compose | **[not needed]** |

Retransmitting `t` for an existing `i` replaces the data and deletes all existing
placements of that id (they are not displayed again until a new `p`).

---

## 4. Chunking

The payload is base64 first, then split:

- Each chunk's **base64 text** is at most **4096 bytes**.
- Every chunk except the last has a length that is a multiple of 4.
- `m=1` on all chunks but the last; the last has `m=0` (which is also the default).
- Only the **first** chunk carries the full control set (`a=t,f=...,s=...,v=...,i=...`).
  Continuation chunks MUST carry only `m` and optionally `q`.
- The client must finish all chunks of one image before sending any other graphics
  command.
- The receiver buffers by image id (and by the absence of an id), validates the complete
  payload, and only then decodes/stores. **Nothing is displayed until the last chunk.**
- The display position is the cursor position **when the final chunk arrives**.
- Any delete command received mid-upload aborts that partial upload.
- A terminal SHOULD cap the reassembly buffer (OpenTUI caps prepared data at 64 MiB;
  this implementation should cap at, say, 32–64 MiB and 25 MP decoded).

OpenTUI's chunking (must be accepted byte-for-byte):

- Raw chunk size is **3072 bytes of image data** (PNG, RGB, RGBA, or zlib-compressed),
  which encodes to exactly 4096 base64 characters.
- First chunk example (RGB):
  `\x1b_Ga=t,f=24,s=W,v=H,i=ID,m=1,q=2;<b64>\x1b\\`
- Continuation: `\x1b_Gm=1,q=2;<b64>\x1b\\`, last: `\x1b_Gm=0,q=2;<b64>\x1b\\`.
- The image id is **not** repeated on continuations; the receiver must remember the id of
  the in-progress upload. There is at most one in-flight upload per connection at a time
  in OpenTUI's output order.
- The `q=2` on every chunk means the terminal sends no replies at all.

---

## 5. Capability probe and reply (the gate OpenTUI checks)

OpenTUI emits this exact probe during startup, immediately followed by a DA1 request:

```
\x1b_Gi=31337,s=1,v=1,a=q,t=d,f=24;AAAA\x1b\\
\x1b[c
```

`AAAA` base64-decodes to `00 00 00`: a valid 1×1 RGB black pixel. `a=q` means "validate
but do not store"; the payload is therefore a legitimate image, not a dummy error case.

**A supporting terminal MUST reply, before answering the DA1 that follows:**

```
\x1b_Gi=31337;OK\x1b\\
```

- The id is echoed exactly (`i=31337`).
- The suffix is the literal ASCII `OK`.
- The terminator is **ST** (`1b 5c`), not BEL. OpenTUI's parser looks for `\x1b_G` …
  `\x1b\\`; a BEL-terminated reply is discarded (its test suite lists
  `\x1b_Gi=31337;OK\x07` as an invalid capability response).
- The reply is an APC, not an OSC/DCS/CSI.
- Reply to the query **immediately, in order**, before processing anything else. If the
  DA1 arrives before the graphics reply, OpenTUI finalises capabilities without Kitty and
  falls back to Unicode blocks for that frame. (A later reply can still enable Kitty, but
  the first paint is lost.)
- `q=2` on the probe would suppress the reply and defeat detection; the probe has no `q`.

What OpenTUI actually parses (`terminal.zig:1135-1150`): it scans for `\x1b_G`, takes the
bytes up to the first `\x1b\\`, splits the control data on `,`, and sets
`caps.kitty_graphics = true` when it sees a field exactly equal to `i=31337`. It does not
inspect the `;OK` suffix in this path. Emitting `i=31337;OK` is therefore both necessary
(the reply must contain the id) and sufficient; an error with the same id would also
enable the capability, so **always send OK for the probe**. (`kitty-transport.zig`'s file
transport does require `;OK` strictly, but that path is not used in raw mode.)

Additional detection paths, for completeness:

- XTVERSION names `kitty` and `ghostty` set `caps.kitty_graphics = true` without the probe.
  Ptyxis MUST NOT impersonate those names; rely on the probe reply.
- Inside tmux OpenTUI does not send the probe at all (`terminal.zig:375-378`) and falls
  back. Ptyxis is not a multiplexer, so this does not apply.
- The probe is sent only when graphics are enabled and not skipped by options.

**Error replies** (for other commands, when not suppressed):

```
\x1b_Gi=<id>;EINVAL:<message>\x1b\\
\x1b_Gi=<id>;ENOENT:<message>\x1b\\      # a=p for an unknown image id
\x1b_Gi=<id>,p=<pid>;OK\x1b\\            # placement acknowledgement
\x1b_Gi=<id>,p=<pid>;EINVAL:<message>\x1b\\
```

Messages are printable ASCII. OpenTUI ignores all of these because its commands use
`q=2`; they are still required by the protocol and useful to humans.

---

## 6. Transmission formats

| `f` | Payload | Size keys | Notes |
|---|---|---|---|
| `24` | 3 bytes/pixel, sRGB, row-major, top-to-bottom | `s`,`v` required | Alpha implicitly 255. |
| `32` | 4 bytes/pixel, RGBA, straight (non-premultiplied) alpha | `s`,`v` required | `f=32` is the protocol default if `f` is absent. |
| `100` | PNG file bytes | `s`,`v` ignored (read from PNG) | OpenTUI's preferred path when it has PNG bytes. |

- `o=z` means the payload (before base64) is zlib-compressed, regardless of `f`. The
  decompressed byte count must match `s*v*3` / `s*v*4` for raw formats. PNG + `o=z`
  additionally requires `S` = the size of the PNG data per the spec; OpenTUI never sends
  PNG+zlib.
- `t=d` (direct) is the only medium OpenTUI uses. `t=f/t/s` (file/temp/shm) are
  **[not needed]** and, if implemented later, are a security-sensitive surface (regular
  files only, no `/proc`, no `/dev`, delete temp files).
- Byte order is RGB(A), not BGR; no row padding.
- A raw payload whose length ≠ `s*v*3|4` is invalid → error/drop; never read out of bounds.

OpenTUI's exact transmit control strings:

```
PNG:   a=t,f=100,i=ID,m=M,q=2
RGB:   a=t,f=24,s=W,v=H,i=ID,m=M,q=2
RGBA:  a=t,f=32,s=W,v=H,i=ID,m=M,q=2
zlib:  a=t,f=24|32,s=W,v=H,i=ID,o=z,m=M,q=2
```

(`m` is 1 while more chunks follow, else 0. `q=2` always; no replies.)

---

## 7. Placement geometry

A placement is created by `a=p` (or `a=T`) and is anchored at the **cursor cell** at the
time the command is processed, upper-left corner of that cell.

| Key | Effect |
|---|---|
| `i` | Image to display. Unknown id → `ENOENT`. |
| `p` | Placement id (unique within the image). Re-using the same `(i,p)` replaces the placement without flicker. |
| `x`,`y`,`w`,`h` | Source rectangle in image pixels. The displayed region is the intersection of this rectangle with the image. `0`/absent = full width/height. |
| `X`,`Y` | Pixel offset inside the first cell. **[not needed]** |
| `c`,`r` | Display rectangle in cells. The image is scaled to fit. If only one is given, the other follows the source aspect ratio. If both are given, the image is letterboxed/pillarboxed (no distortion). |
| `C=1` | Do not move the cursor. `C=0`/absent: move the cursor right by `c` cells and down by `r` rows after placing. |
| `z` | Stacking order; see below. |

Rules:

- `c`/`r` are a **cell footprint**, not a pixel size. The bitmap is scaled to that box;
  with both keys the aspect ratio is preserved and the remainder is blank (letterbox).
  OpenTUI always sends both, plus source `w/h`, so the terminal must crop then scale.
- An image wider than the screen is truncated at the right edge; it must not wrap.
- `z < 0` draws below text (glyphs remain readable); `z >= 0` draws above text.
  `z < INT32_MIN/2` (−1,073,741,824) draws below cell backgrounds. OpenTUI uses
  `z = INT32_MIN/2 + placement_id`, i.e. a negative value in
  `[-1073741824, -1006632961]` (placement ids are 26-bit), chosen to sit **above cell
  backgrounds and below glyphs**. Parse `z` as signed 32-bit: clamping it to non-negative
  would put every OpenTUI image above the text.
- Same `z` + overlap: lower image id is lower. Same `z` and same id: undefined.
- If `X`/`Y` would push the image outside the first cell the result is undefined; OpenTUI
  does not use them.
- Placements are independent; the same image can be placed many times with different
  crops, sizes, and z.

OpenTUI's placement bytes:

```
CSI <y+1> ; <x+1> H                          # absolute cursor address (1-based)
\x1b_Ga=p,i=ID,p=PID,c=COLS,r=ROWS,x=SX,y=SY,w=SW,h=SH,C=1,z=Z,q=2\x1b\\
```

Every placement is preceded by its own `CSI H`, so the terminal's cursor is moved by
OpenTUI, and `C=1` prevents the protocol from moving it further. A frame with partial
reservations emits several such placements (one per contiguous run of reserved cells)
with distinct placement ids and source spans.

OpenTUI emits all image APCs **before** the frame's cell text, then repaints the reserved
cells as spaces. Combined with `z < 0`, the visible result is text drawn over the image.
For snapshot-style rendering it instead wraps the put in `ESC[s` … `ESC[u`: save cursor,
move up/CR/right, emit the cursor-form `a=p` (no `x/y/w/h`), restore. A terminal that
mishandles `C=1` or `DECSC/DECRC` corrupts that path.

---

## 8. Cursor, scrolling, erase, lifecycle

Cursor:

- Without `C=1`: after the placement the cursor moves right by `c` cells and down by `r`
  rows. If that leaves the screen or the scroll region, the exact final position is
  implementation-defined.
- With `C=1`: the cursor does not move at all.
- OpenTUI uses `C=1` exclusively and positions with `CSI H` before every placement.

Scrolling:

- Placements MUST scroll with the text they are anchored to (index/LF/scroll-region/scroll
  wheel/history), including into scrollback. No re-anchoring, no scaling.
- When page margins are set, only placements fully inside the region scroll; partial ones
  are clipped at the margin.
- Scrolling back into history shows the images again.

Erase/reset:

- `ED 2` (clear screen) MUST clear all visible images.
- Terminal reset MUST clear all images.
- Entering the alternate screen (`CSI ?1049h`) clears images on the alternate screen;
  the primary screen's images are untouched and reappear on return.
- Other erase commands (`EL`, `ED 0/1`, etc.) have **no effect** on images; only `a=d`
  deletes them. (This differs from iTerm2, where images are cell attributes. Kitty
  placements are a separate plane.)
- Deleting an image (uppercase `d`) frees its data when no placements/scrollback
  references remain.

Deletion selectors (`a=d`):

| `d` | Deletes |
|---|---|
| absent or `a`/`A` | all placements visible on screen |
| `i` / `I` | all placements of image `i`; with `p`, only that placement. Lowercase keeps image data; uppercase frees it. |
| `p` / `P` | placements intersecting cell (`x`,`y`) |
| `c` / `C` | placements intersecting the cursor cell |
| `x`/`y`/`z` (+caps) | placements intersecting a column/row/z-index |
| `r`/`R` | image ids in the range `x..y` |

OpenTUI's deletes:

```
a=d,d=i,i=ID[,p=PID],q=2      # drop placement(s), keep pixels for re-placement
a=d,d=I,i=ID[,p=PID],q=2      # drop placement(s) and free the image data
```

(`writeKittyDelete` maps `free_image=true` to uppercase `I`, false to lowercase `i`.)

---

## 9. Limits and error handling

- Image ids: `1..4294967294` in practice (OpenTUI uses a 32-bit salt derived from the
  clock and pointer plus a per-placement offset); `i=0` is legal only as "no id" and cannot
  be re-addressed. Placement ids: `1..4294967295`; `p=0` is anonymous. OpenTUI's
  partial-frame run placements use ids from `2^31`, so `p` must be parsed as unsigned
  32-bit, not clamped to 26 bits.
- Invalid control data, bad base64, bad payload length, unsupported `f`, unknown action →
  `EINVAL` (or silence with `q`). Unknown image id on `a=p`/delete → `ENOENT`. Quota
  exhaustion → `ENOSPC`. Never print the payload or an error into the grid.
- Decode caps: reject before allocation when `s*v*4` exceeds the budget (use 25 MP /
  100 MB as WezTerm does), reject 0×0, cap reassembly at 64 MiB.
- Oversized single chunk (>4096 base64 bytes) → error, drop the upload.
- Reply size is small; no reply may exceed a few hundred bytes.
- Partial uploads are dropped on connection close, `RIS`, or any delete command.

---

## 10. What is deliberately not needed for OpenTUI

| Feature | Why not |
|---|---|
| `t=f` / `t=t` / `t=s` file, temp-file, shared-memory transport | OpenTUI's default and used mode is `.raw` (direct `t=d`); file transport is opt-in and already has its own probe handshake. |
| Animation (`a=f`, `a=a`, `a=c`) | OpenTUI transmits still frames; GIFs are decoded client-side. |
| Unicode placeholders (`U=1`, U+10EEEE) | OpenTUI places with `c/r` and absolute cursor addressing. |
| Relative placements (`P`,`Q`,`H`,`V`) | Not emitted; would add a placement graph. |
| tmux DCS passthrough (`ESC Ptmux;` + doubled ESCs) | OpenTUI skips graphics inside tmux entirely. |
| Sixel | Separate protocol; OpenTUI uses Kitty when the probe succeeds, Sixel only if DA1 advertises it. |
| `I=` image numbers, `N=` hints, `S/O` file offsets | Not emitted. |
| Querying available transmission mediums | OpenTUI probes with `t=d` directly. |
| Multiple simultaneous chunked uploads | OpenTUI serialises its output; one in-flight upload is enough. |

---

## 11. Conformance checklist

**Envelope and parsing**

1. **C1** [MUST] Parse `ESC _ G <control> [ ; <base64> ] ESC \`: accept both the payload form (transmit/query) and the payload-less form (placement/delete) with no `;`.
2. **C2** [MUST] Reject/ignore BEL-terminated APC graphics (OpenTUI emits and accepts only ST) while never leaking payload bytes to the screen.
3. **C3** [MUST] Control data is comma-separated `key=value`, parsed at the first `=`, keys case-sensitive; unknown keys ignored; no spaces inserted.
4. **C4** [MUST] Parse `z` as signed 32-bit and accept negative values down to `INT32_MIN`.
5. **C5** [MUST] `q=0` replies to all, `q=1` suppresses `OK` only, `q=2` suppresses everything; silence must not affect processing.

**Probe / capability**

6. **C6** [MUST] Respond to `\x1b_Gi=31337,s=1,v=1,a=q,t=d,f=24;AAAA\x1b\\` with `\x1b_Gi=31337;OK\x1b\\`, immediately and before the following DA1 reply.
7. **C7** [MUST] `a=q` validates and replies but stores nothing, replaces nothing, moves no cursor and draws nothing.
8. **C8** [MUST] The reply echoes `i` exactly, uses `;OK`, printable ASCII, ST terminator, and is an APC (`ESC_G`), not OSC/DCS.
9. **C9** [MUST] Errors use `;EINVAL:` / `;ENOENT:` with a printable message and the same id (plus `,p=<pid>` when the command had one).
10. **C10** [SHOULD] A late reply after DA1 still updates capability state and repaints, rather than wedging the session.

**Transmission and chunking**

11. **C11** [MUST] Accept `f=24` (RGB), `f=32` (RGBA) and `f=100` (PNG); require `s`,`v` for raw; ignore them for PNG.
12. **C12** [MUST] Accept base64 chunks up to 4096 characters; non-final chunks are multiples of 4; `m=1` continues, `m=0`/absent ends.
13. **C13** [MUST] Continuation chunks carry only `m` (and optionally `q`); the receiver remembers the image id from the first chunk.
14. **C14** [MUST] Buffer the entire payload and display/store nothing until the last chunk; use the cursor position at the final chunk for placement.
15. **C15** [MUST] Reassemble to the exact original bytes; PNG decodes, raw length equals `s*v*3|4`; reject mismatch without OOB reads.
16. **C16** [MUST] `o=z` inflates before decoding; a failed inflate drops the image with an error (or silence under `q`).
17. **C17** [MUST] Any delete command aborts an in-progress upload for that id.
18. **C18** [MUST] OpenTUI's exact strings parse: transmit chunks (`…m=1,q=2;<b64>`), payload-less placements (`…C=1,z=…,q=2`) and deletes (`a=d,d=…,q=2`, no `;`).

**Placement**

19. **C19** [MUST] `a=p` displays the stored image at the cursor cell's upper-left corner; unknown `i` → `ENOENT`.
20. **C20** [MUST] `x,y,w,h` select a source rectangle in pixels, intersected with the image; absent/0 means full extent.
21. **C21** [MUST] `c,r` define a cell footprint; scale to fit, preserve aspect, letterbox/pillarbox when both are given; derive the missing one from the source aspect when only one is given.
22. **C22** [MUST] Re-using `(i,p)` replaces the existing placement without flicker and without duplicating it.
23. **C23** [MUST] `C=1` leaves the cursor unchanged; without it the cursor advances `c` columns and `r` rows (or an implementation-defined position if that leaves the screen).
24. **C24** [MUST] Negative `z` draws below glyphs, `z >= 0` above; same-`z` tie-break by image id; signed range preserved.
25. **C25** [MUST] Placements clip at the right/bottom grid edge without wrapping or scrolling horizontally.
26. **C26** [MUST] Multiple placements of one image and several images on screen are independent; partial-frame run placements (multiple `p` with source spans) do not corrupt each other.

**Lifecycle**

27. **C27** [MUST] Placements scroll with their rows, including into and out of scrollback; page-margin scrolling clips partial placements.
28. **C28** [MUST] `ED 2`, terminal reset, and entering the alternate screen clear the appropriate images; `EL`/`ED 0/1` do not.
29. **C29** [MUST] `a=d` implements at least `i`, `I`, `p`, `P`, `a`, `A` with the lowercase/uppercase data-retention distinction.
30. **C30** [MUST] Deleting an image frees memory once no placement or scrollback row references it; scrollback eviction releases image references.
31. **C31** [SHOULD] Payload/pixel caps enforced before decode/allocation; oversized input cannot hang or OOM the terminal.
32. **C32** [MUST] Malformed commands from untrusted output cannot crash, write files, or print payload bytes.

Cross-check: C1–C10 cover the envelope and probe; C11–C18 the transport; C19–C26 placement; C27–C32 lifecycle.

---

## 12. Implementation notes for the VTE patch

1. **APC parsing.** VTE's parser already has an APC state; dispatch on `G` and buffer the
   control string + payload. Do not reuse the OSC 1337 code path. `ESC \` ends APC; BEL
   does not (OpenTUI never sends BEL commands anyway).
2. **Reply path.** Replies must be written to the pty from the terminal side, immediately,
   in order, before the DA1 answer. Use the same write queue as other terminal replies and
   drain it synchronously; a deferred reply loses the first OpenTUI frame.
3. **Chunk state.** One reassembly buffer keyed by image id (plus one for id-less
   uploads), storing format, `s`,`v`, `o=z`, and accumulated bytes. Continuations carry no
   id — keep the "current upload" pointer. Reset on delete/reset/EOF.
4. **Image store.** Keep a map `id → decoded texture + intrinsic size`; placements are a
   separate list `(image_id, placement_id, anchor_row, anchor_col, src rect, cell box, z,
   cursor_policy)`. This differs from the iTerm2 patch's placement-in-cell model: Kitty
   placements are a separate plane and survive text writes.
5. **Coordinates.** Placement anchor is a grid row/column (stable/absolute row, as with the
   iTerm2 patch). `z` is signed; store it as `int32_t`, not unsigned.
6. **Cursor.** Apply the `C` policy exactly; do not move the cursor for `a=t`/`a=q`/`a=d`.
   OpenTUI uses `C=1` and does its own `CSI H`, so a wrong move corrupts the frame.
7. **Scaling.** Do not tie the texture to the cell grid. Compute the pixel box from `c`,`r`
   and the cell metrics at draw time; keep the source rect as pixel coordinates.
8. **Cleanup.** Clear placements on `ED 2`, RIS, alt-screen switch; drop on scrollback
   eviction; free textures when the last reference goes. Cap textures (LRU) so a hostile
   stream cannot exhaust memory.
9. **Text interaction.** Kitty `z<0` is below glyphs, so text drawn over an image remains
   readable; unlike iTerm2, writing text does not delete the image. `EL`/`ED 0/1` leave
   placements alone.
10. **Do not fake XTVERSION.** The probe is the only signal OpenTUI needs; claiming to be
    `kitty`/`ghostty` to short-circuit detection is fragile and semantically wrong.
11. **Frame order.** OpenTUI writes image deletes/transmits/placements before the frame's
    text, then paints reserved cells as spaces. Negative `z` must therefore keep glyphs
    above the image; treating a space write as "delete the placement" would blank the
    image. The one exception is `ED 2`/reset/alt-screen, which clear images by design.
12. **Reply timing.** The probe is sent inside a DECSC/DECRC batch followed by `DA1`.
    Answer it from the input-processing path before the DA1 is generated; queueing the
    reply behind a render or a timer makes OpenTUI miss it for the first frame.

---

## 13. Emitter and test vectors

`scripts/emit_kitty.py` reproduces OpenTUI's byte stream and can generate payloads with
no fixture files:

```sh
python3 scripts/emit_kitty.py --probe-only --dry-run          # exact probe bytes
python3 scripts/emit_kitty.py --png 80x40 --cols 10 --rows 5  # full flow
python3 scripts/emit_kitty.py --raw-rgb 4x4 --zlib --verify
python3 scripts/emit_kitty.py --png 8x8 --cols 4 --rows 2 --delete I --dry-run
```

It never prompts. Exit codes: `0` success, `1` I/O/encode, `2` usage, `3` reply
timeout/mismatch. `--dry-run` prints each APC as a Python `repr`, the parsed control dict,
chunk count and lengths, the reassembled SHA-256, and base64 round-trip status. `--verify`
reassembles its own chunks and compares them byte-for-byte with the source image (and
inflates `o=z` before comparing).

Parity notes:

- Chunking defaults to OpenTUI's **3072 raw bytes → ≤4096 base64 chars**. `--b64-chunking`
  splits the base64 text every 3072 chars instead (accepted by kitty, but not what
  OpenTUI emits).
- `--delete i|I` emits `d=i`/`d=I` by image id. `--delete p` emits
  `a=d,d=i,i=ID,p=PID` (remove one placement), because `d=p` in the spec means
  "delete placements intersecting a cell", not "delete placement id".
- `--at-cursor` omits the `CSI H` and emits the cursor-form placement, matching
  OpenTUI's snapshot path; the default addresses `1;1` first for reproducible tests.
- `--expect-reply` requires an ST-terminated reply whose message is exactly `OK`; a
  BEL-terminated reply is ignored (OpenTUI rejects it too).

Canonical vectors:

| Case | Bytes |
|---|---|
| probe | `\x1b_Gi=31337,s=1,v=1,a=q,t=d,f=24;AAAA\x1b\\` |
| probe reply | `\x1b_Gi=31337;OK\x1b\\` |
| placement reply | `\x1b_Gi=42,p=7;OK\x1b\\` |
| delete all | `\x1b_Ga=d,d=a,q=2\x1b\\` |
| delete image data | `\x1b_Ga=d,d=I,i=42,q=2\x1b\\` |
| placement at cursor | `\x1b_Ga=p,i=42,p=7,c=10,r=5,C=1,z=-1073741817,q=2\x1b\\` |
| first PNG chunk | `\x1b_Ga=t,f=100,i=42,m=1,q=2;<4096 base64 chars>\x1b\\` |
| last PNG chunk | `\x1b_Gm=0,q=2;<base64>\x1b\\` |

The harness should assert `\x1b_Gi=31337;OK\x1b\\` arrives before the DA1 reply and
that OpenTUI's first frame chooses Kitty rather than blocks.
