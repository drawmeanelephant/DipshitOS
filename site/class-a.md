---
title: Deterministic checks
parent: evidence
status: published
tags: [evidence, class-a, ci]
---

# Deterministic checks (class A)

Class A is the portable, deterministic set: no Apple silicon, no VM, no
timing dependence. It is exactly what GitHub CI proves on every push and pull
request.

## What it runs

```bash
zig fmt --check boot/src/*.zig kernel/src/*.zig build.zig
bash tools/verify-unit-tests.sh
zig build test-console
zig build
zig build image
zig build inspect
swift build --package-path host/vm-runner
zig build context
bash tools/status/verify-issue-coordination.sh
bash tools/status/test-coordination.sh
bash tools/lint-workflows.sh
bash tools/verify-mmu-debt.sh
python3 tools/decode-screen-glyphs.py --self-test
```

The `just verify-portable` alias runs the same set locally.

## What each check pins

- **`zig fmt --check`** — formatting is part of the contract, not a suggestion.
- **`verify-unit-tests.sh`** — the Zig unit suite (hundreds of host tests) for
  the pure logic: allocators, ARP/IPv4/UDP/TCP/DHCP checksums and state
  machines, the text renderer against a mock canvas, the window compositor,
  the syscall dispatch, and more.
- **`zig build test-console`** — a **byte-identical** mock transcript fixture:
  the monitor must produce exactly the expected output, so a stray character
  in the banner or prompt fails deterministically.
- **build / image / inspect** — the EFI binary, the GPT+FAT32 image, and the
  inspection stages.
- **`verify-issue-coordination.sh`** — claims are GitHub issues labeled
  `claim`; the gate reads the open ones via `gh` and fails when two of them
  from different branches declare overlapping file touches.
- **`lint-workflows.sh`** — actionlint (pinned) over `.github/workflows/`:
  trigger/expression typos fail in CI instead of only surfacing when a
  workflow runs for real. Runner-label allowance in `.github/actionlint.yaml`.
  Self-bootstraps into `.build/` when actionlint isn't on PATH.
- **`verify-mmu-debt.sh`** — the ADR 0006 MMU contract (T0SZ=16 + TLBI
  comments) stays enforced.
- **glyph self-test** — the mirror-tripwire decoder renders the clock window
  forward, mirrors each glyph in-cell, and asserts the tripwire fires — all
  offline.

<Aside kind="info">

**VERIFIED.** Class A runs on the repository's CI on every push. It is the
fast, deterministic floor; it is *not* hardware evidence.

</Aside>
