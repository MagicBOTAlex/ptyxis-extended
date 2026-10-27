# Protocol references

- [iTerm2 inline images (`OSC 1337 ; File=`)](iterm2-inline-images.md) — wire format,
  sizing, cursor/lifecycle rules, iTerm2-vs-WezTerm divergences, conformance checklist.
- [Kitty graphics protocol (OpenTUI subset)](kitty-graphics-protocol.md) — APC grammar,
  control keys, chunking, capability probe/reply, placement geometry, conformance
  checklist, and what is deliberately out of scope.

Emitters used by the tests live in `../scripts/`: `emit_imgcat.py` (iTerm2) and
`emit_kitty.py` (Kitty).
