# ADR 0031: The guest writes the report (GOSELF self-test)

- Status: ACCEPTED
- Date: 2026-09-17
- Issue: #1381 (this document) · milestone #1380 (M61) · cards M61a–M61f
  (#1381–#1386)
- Related: ADR 0007 (syscall ABI — unchanged by this arc), ADR 0010
  (userland file ABI; `/host/...` routing), ADR 0026 (GOOS=virelai),
  ADR 0030 (Go is EL0), M34 HF1–HF7 (the host file channel),
  M40 GF6 (`tools/gate/SPEC.md`; new gates are specs), `docs/testing.md`
  (amended by this card)

> **A split, not a slogan: the host boots the VM, the guest proves its own
> behavior.** This ADR is docs-only and carries the M61 card split
> (M61b–M61f). It adds no syscall, no Zig app, no kernel change; the boot
> default does not move.

## Context

The class-B fleet is the project's VZ evidence: ~200 specs that boot a real
VM, script the guest (monitor commands on serial, keystrokes through the
host HID seam), and assert on `vm-serial.log`. That is the right shape for
what the host actually owns — VZ boots, guest death, host-injected input,
framebuffer capture, hypervisor save/restore.

It is the wrong shape for "did this program actually compute". Serial is a
heartbeat: line-oriented, interleaved with prompts and echoes, and
satisfied by any program that prints the expected string. Byte-level claims
about files, windows and clocks therefore end up as Python pasted into a
spec, grepping a transcript; on success, the run's only durable evidence is
that transcript. Fixtures like `KEYTEST` / `SEXITEST` / `PROBE.ELF` exist
to help the host drive a black box — nothing requires the guest to stay
one.

M34 already removed the reason for that. The host file channel *is* the
filesystem now: `/host/...` is a directory on macOS (`--cvc-file <dir>`,
served by the runner with Swift `FileManager`), and HF6
(`gate_seed_share` in `tools/lib/gate-run.sh`) copies the compiled bundle
into the per-run share, so apps are no longer packed into `disk.img` at
all. The guest has a real file ABI on top of it (ADR 0010: open, read,
write, truncate, delete, dir-list, mkdir; the Go SDK surface is
`vi.FileOpen` with `vi.ModeRead|ModeWrite|ModeCreate|ModeAppend|ModeDir`).

So the missing piece is a convention, not a capability: a place for the
guest to write, a report shape the host can read back with `cat`, and a
rule about which side owns which claim.

## Decision

**D1. The guest owns pass/fail for in-OS cases. The host owns the
hypervisor.**

| Claim | Owner | Evidence |
|---|---|---|
| Boot completes; banner; kernel takeover | Host | class-B spec, `vm-serial.log` |
| VZ death / exception park | Host | serial + runner exit |
| Host-injected HID, scripted keystrokes, input chords | Host | serial |
| Framebuffer pixels, PNG goldens, r3d layout | Host | `vgate_assert snapshot` |
| Hypervisor save/restore | Host | runner + serial |
| TLS/SSH/DNS/TCP responders | Host | a process outside the VM |
| Syscall ABI, file bytes, window open/present, clock monotonicity, "the app computed" | **Guest** (`GOSELF.ELF`) | `/host/SELFTEST/REPORT.txt` + `OUT/` receipts, read on the host |
| Pass/fail of the run | Host reads those files, plus one serial summary line | |

**D2. Intake and output are ordinary share files under
`/host/SELFTEST/`. Nothing for this arc is packed into `disk.img`.**

```
/host/SELFTEST/IN/         host-seeded fixtures (intake) — the spec writes these pre-boot
/host/SELFTEST/OUT/        guest-written artifacts (the proof) — one small receipt per case
/host/SELFTEST/REPORT.txt  the guest's report: every case, in order, pass/fail
```

- The host owns `IN/` (the guest never writes there) and the guest owns
  `OUT/` and `REPORT.txt` (the host only reads them). Existing directories
  are ordinary: `EEXIST` on mkdir is success, and neither side fails a run
  for a pre-existing directory.
- The class-B spec creates `SELFTEST/`, `SELFTEST/IN/` and
  `SELFTEST/OUT/` in the share before boot; the app still ensures
  `SELFTEST/OUT/` exists (`ModeDir`, `EEXIST` tolerated) before its first
  write, so it is not order-dependent on the spec.
- An intake fixture must be **read from the share**, never carried as an
  embedded copy in the binary. That is what makes the M61c negative test
  meaningful: mutate the seeded file on the host, and the `intake` case
  must FAIL.
- Fixtures are files you can `ls` on macOS. If it is not visible in the
  per-run share, it is not a fixture for this arc.

**D3. One Go EL0 app — `GOSELF.ELF` over `user/go/tabapp`.** Built by
`tools/go/build-goself.sh` (the `build-goedit.sh` / `build-gocalc.sh`
shape) into `.build/go/GOSELF.ELF`, seeded into the share by the spec.
No new syscall, no new Zig app, no guest pytest, no libc, no POSIX. The
kernel is untouched and the boot default is unchanged: the thin spec seats
Zig `tabwm` explicitly (`tabwm` / `tabwm start`, the `go-edit` shape), so
the gate never depends on the persisted M59 default. Case logic that can
run off-guest is host-testable under the existing `go test ./...`
(module `user/go/go.mod`).

**D4. One thin class-B spec boots the app and byte-compares share files.
Do not add a `live-foo.spec` for a case that belongs in GOSELF.**
`tools/gate/specs/go-selftest.spec`: `vgate_share seed`, scripts that seat
TABWM, `exec GOSELF.ELF`, the run ends on the report summary marker, then
asserts the serial summary and reads `REPORT.txt` / `OUT/` from
`$VG_SHARE` on the host. Serial is the heartbeat, not the proof.

**D5. This milestone does not delete the existing fleet.** Retiring a
`live-*` spec is a later card, and only when the GOSELF case is strictly
stronger than the spec it would replace — never the same claim asserted in
two places.

**D6. TLS/SSH/net responders stay host-side.** They need a process outside
the VM; do not cram them into GOSELF in this milestone.

## The report contract

Two channels, one number, files first.

**1. Files.** `REPORT.txt` is UTF-8 with LF line endings, written and
closed before any summary is printed:

- one line per executed case, in the app's fixed discovery order:
  `case <id> pass`, or `case <id> fail <one-line detail>`;
- a final line `summary cases=<n> failed=<k>`;
- `<id>` matches `[a-z0-9-]+` and is unique in the file;
- the file is **deterministic**: no timestamps, pointers, addresses, or
  run-varying text. The same build over the same case list renders
  byte-identical bytes — that is what makes a `share-equals` fixture legal
  (M61f) and what keeps `REPORT.txt` diffable across boots.

**2. Serial, after the writes.** Exactly one summary line, the last line
the app prints:

```
selftest: FAIL n=<N>      # N == the report's failed count; N=0 on success
selftest OK               # printed only when N == 0
```

- Additional `selftest: case <id> pass|fail` lines before the summary are
  welcome as a heartbeat/for humans; they are never the proof.
- Every marker is printed only **after** its syscall returned (the
  GOEDIT/GOCALC discipline). A summary printed before `REPORT.txt` exists
  is a contract violation, and the app writes, closes, then prints.
- The spec stops the run on the summary marker itself
  (`--script-expect 'selftest: FAIL n='` matches any `N`) and then
  asserts `n=0`. A run in which the summary never appears is a **failed**
  run, not a flaky one — the timeout/no-match decides it.

**3. Per-case receipts.** A case may write
`/host/SELFTEST/OUT/<id>.<ext>`; receipts are small and deterministic, and
carry what the host checks as bytes — e.g. the window case writes
`OUT/window.txt` with `win=<id> w=<W> h=<H> present=ok`. For anything the
host can verify as bytes, the receipt (or the report) is the evidence; the
guest's own `case <id> pass` line alone is not.

**4. Evidence outlives the run.** The share is a per-run `mktemp -d` and
`gate_end` deletes it. The spec copies `REPORT.txt` and every receipt it
relied on into `artifacts/` before `gate_end` (canonical names:
`artifacts/go-selftest-report.txt`, `artifacts/go-selftest-out/…`), and
M61f's share asserts copy the file they compared, like `capture-equals`
does.

## Card split (M61, umbrella #1380)

| Card | Deliverable | Depends |
|---|---|---|
| **M61a #1381** | This ADR + the `docs/testing.md` split of labor (docs-only) | — |
| **M61b #1382** | `GOSELF.ELF` (`user/go/selftest`), report files, thin `go-selftest` spec | M61a |
| **M61c #1383** | Intake: host drops `IN/` fixtures, guest chews them, writes `OUT/` | M61b |
| **M61d #1384** | File-ABI case pack on the share (create/write/read/truncate/delete/list) | M61b |
| **M61e #1385** | Window receipt (`OUT/window.txt`), not a PNG golden | M61b |
| **M61f #1386** | `share-equals` / `share-contains` vgate asserts (SPEC.md amendment, own issue + pilot) | M61b |

Per-card acceptance lives on each issue; this file is the contract they
share.

## Non-goals

No JS test runner. No deleting CALC/NOTEPAD/TABWM. No CI VZ runner
(#1340 closed). No WMP. No new virtio. No packing fixtures into
`disk.img`. No touching claimed moonshots (`user/go/r3d/**`,
`user/go/ttf/**`) or `user/go/calc/**` (#1378). No `live-*` retirement.
TLS/SSH/net responders stay host-side. Framebuffer goldens stay host-side.

## Consequences

- A new in-OS case is an app change plus a host assertion on files that
  exist on macOS — no new boot script, no new serial grep, and the spec
  surface stops growing one `live-foo.spec` per feature.
- Guest-written evidence is only as strong as what the host reads back:
  the host checks bytes on its own filesystem, so a run cannot pass by
  printing. It assumes the file channel is honest; a kernel bug that
  corrupts writes in both directions is not detectable from inside one
  run, which is exactly why the syscall-ABI and file cases in M61d exist
  as cases at all.
- `SPEC.md` stays frozen except the M61f amendment (two share assert
  kinds, its own issue and pilot, per the rule already in that file).
- CI still proves class A only. `go-selftest` is a class-B gate on Apple
  silicon (`just gate go-selftest`); its portable half — the case logic —
  is covered by `go test` where it can run off-guest.
- The fleet's retirement path is deliberately slow: nothing is deleted
  until a GOSELF case is strictly stronger, so the two evidence channels
  will overlap for a while. That is accepted.

## Verification (this card)

Docs-only. The card is complete when this file exists and reads ACCEPTED
and `docs/testing.md` names the share layout and the serial contract.
No VZ, no build, no gate run is required — M61b–f carry their own.
