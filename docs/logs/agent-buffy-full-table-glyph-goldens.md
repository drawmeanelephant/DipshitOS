# Log — full-table glyph goldens (issue 125 hardening)

**Branch:** `agent/buffy/full-table-glyph-goldens`
**Claim:** 9263

- **2026-08-15** — *buffy*: extended the class-A glyph proof from the
  hand-written `'C'` spot checks (claim 8742) to the full 95-glyph table.
  First attempt compared rendered pixels against `font.row_pixel` — a
  mutation test (reverse the helper) showed the round-trip stayed green
  because renderer and expectation flipped together (the self-consistency
  trap issue 125 documented). Rewrote both full-table goldens to read the
  raw table bits inline (`(row >> x) & 1`), independent of the helper, and
  added a pinned FNV-1a 64 table fingerprint + an asymmetry census (90/95
  asymmetric; symmetric set is ` !*_|`).
- Mutation proof: reversing `row_pixel` now FAILS both full-table
  round-trips and both `'C'` goldens; the fingerprint stays green (pins
  data, not helper). Class A green: fmt, 40-module aggregate (405 console
  tests), byte-identical transcript, build.
