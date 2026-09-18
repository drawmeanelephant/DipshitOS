# tools/go/tabcodec — an independent Go `.tabs` v2 codec

M53 Card 2 (GitHub issue #1246, umbrella #1244). TABWM persists its tab
session as a `.tabs` file, and the writer/reader for that file lives in
`user/src/tabwm.zig` (Zig). This directory is a second, independent
implementation of the same bytes in Go, so a second language can own TABWM
session state without touching the kernel, TABWM, or the Zig side.

Scope: host-only. No VM, no kernel, no new syscall, no gate spec, no change
to `user/src/tabwm.zig`.

## Format (frozen in `user/src/tabwm.zig`)

| Part | Width | Layout |
|---|---|---|
| header | 6 B | `version(2) \| active+1 (0 = none) \| count \| seq_lo \| seq_hi \| prefs` |
| record | 69 B | `title(32, NUL-padded) \| flags(1) \| group(12, NUL-padded) \| bin(24, NUL-padded)` |

- At most 16 tabs → a maximal file is `6 + 16*69 = 1110` bytes.
- `flags`: `0x01` pinned, `0x02` frozen, `0x04` dock-at-launch.
- Fields wider than their slot are truncated and the slot zero-filled.
- `Decode` is **total**: short header, wrong version byte, `count > 16`, a
  truncated record body, or an out-of-range active index is rejected with an
  error (all wrapping `ErrCorrupt`). Trailing bytes after the last record are
  ignored — the Zig parser only enforces the minimum length.

## Run the tests

```bash
cd tools/go/tabcodec
go test ./... -v     # stock toolchain (go 1.27.1); no GOOS=virelai fork needed
gofmt -l . && go vet ./...
```

## Golden vectors: how parity is established

`testdata/golden-a.tabs` and `goldenAHex` in `tabcodec_test.go` are **derived
by hand from the frozen layout** above, for the exact state the Zig test
`TWM/ST1` builds (tabs `Calc` + `Files`, tab 0 pinned with bin `GOCALC.ELF`,
tab 1 frozen with group `tools`, active 0, seq 7 → 144 bytes).

The Zig serializer is not callable from a host Go test (it lives in the
guest module graph), so parity here is **by derivation plus review**: the
vector was produced independently of this package's encoder and checked
field-by-field against `serialize_tabs_v2` / `parse_tabs_v2`, and the
rejection cases mirror the Zig tests `TWM/ST3` (v1 refused by the v2 parser)
and `TWM/ST4` (truncated / count-over-max / active-out-of-range / wrong
version all rejected). If the Zig side ever changes the format, this table
and those vectors are what must be re-derived.

## Limitations

- v2 only. The Zig side keeps a v1 reader for old installs; this package
  classifies a v1 buffer as a version mismatch, which is what the v2 codec is
  for.
- `Prefs` is carried through the header but the Zig writer always emits `0`
  (reserved for rail density / Go-enable bits).
