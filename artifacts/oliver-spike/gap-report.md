# Gap report — oliver as a native AArch64 ELF app on VirelaiOS

**Verdict: VIABLE.** A real Zig HTML tool runs on VZ today as a native ELF
app, and the HTML it produces is byte-identical to the reference tool's own
output. One measured constraint bounds the story: the tool gets **no argv**
(raw ELF images cannot receive arguments). Size is not a constraint — the image
uses **47.5% of the real 512 KiB loader memory cap** (see B3's correction
note).

Spec: `tools/gate/specs/live-oliver.spec` · Evidence:
`artifacts/live-oliver-serial-01.log`, `artifacts/live-oliver-oliver-html-guest.html`,
`artifacts/live-oliver-report.txt`, `artifacts/oliver-spike/native-build-log.txt`.

## 1. What actually runs (observed on VZ)

`exec OLIVER.ELF` — a 253,160 B native image, compiled by the **real host zig**
(`aarch64-freestanding -O ReleaseSmall -fstrip -fno-PIE -fno-entry
-z max-page-size=4096 -T tools/zc-host-link.ld`) and launched from the host
share:

| observation | value |
|---|---|
| loader accepted it (serial) | `exec: loaded OLIVER.ELF size=0x000000000003cc18 entry=0x0000000000402b1c stack=0x0000000063650000` |
| app ran at EL0 and read the share | `/host/MD.TXT` via slots 23/24/26, 2048-byte chunks |
| app wrote the share back (M34 HF) | `/host/OLIVER.HTML`, 754 B — host-side file, 754 B |
| **byte-exactness** | guest sha256 `540f240054ad929c7311f29d83e0432b01551300ab97f01cf2aaac82f76a390e` == reference-CLI sha256 `540f2400…f76a390e` |
| app report + exit status | `oliver: wrote 754 bytes`, exit status 754 (= bytes written) |
| determinism | same byte count/sha on a second live boot (`BOOTS=2`) |
| FAIL needles | no `error: `, no `[EXC] parking:`, no loader refusal |

The exact shipped capability: **Markdown in → HTML out through the guest file
table and host share, using oliver's own `parse` + `html.render`**, with no
libc, no POSIX, no WASI, no network, no threads, no clock, and no kernel
change.

## 2. Blockers, quantified, with verdicts

### B1 — raw ELF images cannot receive argv (the one hard blocker for "CLI tools")

`kernel/src/exec.zig` packs the argv block only for `dsk1_magic` and
`dsk3_magic`; the ELF branch returns `.no_args_room`:

```zig
} else {
    // ELF images: their text region is fixed by the loader contract.
    return .no_args_room;
}
```

Observed consequence: `exec OLIVER.ELF` arrives with **`argc == 0`, argv
NULL** (the app's first live attempt printed its usage line, `status=2`).
`OLIVER.ELF arg1 arg2` would be refused outright (`error: image leaves no room
for the argv block (256 bytes)`). A real CLI tool — `oliver render --from
markdown < in > out` — therefore cannot be driven with flags today; the
shipped slice uses fixed, documented defaults instead.

**Verdict (3) hard → card it, blocked on #1163.** `kernel/src/elf.zig` and
`kernel/src/exec.zig` are held by the active #1163 claim (go-port phase 0a,
which generalizes exactly this loader surface), so this claim does not touch
them; the measurements are recorded here and on #1163.

### B2 — the data segment must be *exactly* adjacent, and the recipe's `ALIGN(16)` can violate that

`kernel/src/elf.zig` requires segment 1 at **`text_base + p_memsz[0]`**, exact.
Two size probes with static `.bss` buffers fail the repo's own checker by 8
bytes because `tools/zc-host-link.ld` aligns `.data` to 16 while the text
memory image ended 8-byte aligned:

```
CONTRACT FAIL: data base 0x4142a0 != text_base + p_memsz[0] (0x414298)   # render-only probe
CONTRACT FAIL: data base 0x4298a0 != text_base + p_memsz[0] (0x42989a)   # parse-only probe
```

**Verdict (1) trivial:** either drop `ALIGN(16)` on `.data` (the loader's rule
is exact adjacency, not alignment), or fold it into #1163's per-`p_vaddr`
segment model. The **shipped image dodges the trap entirely**: every buffer is
anonymous `sys_mmap`, so it has *no* writable segment at all — one PT_LOAD,
R+X, `phnum=1`. (The `.no_args_room` message above is that same 256-byte block
trying to land in a writable tail.)

### B3 — size is NOT a blocker: 248,776 B is 47.5% of the real 512 KiB cap

| image (native, `-O ReleaseSmall -fstrip`) | file | total `p_memsz` | PT_LOADs |
|---|---|---|---|
| **OLIVER.ELF** (real tool: parse + render + file I/O, all buffers mmap'd) | 253,160 B | 248,776 B (**47.5% of cap**) | 1 |
| `sizeprobe-parse-only.zig` (document + markdown) | 174,592 B | — | 2 (contract-fails, B2) |
| `sizeprobe-render-only.zig` (document + html) | 87,040 B | — | 2 (contract-fails, B2) |

The ceiling is `exec.exec_program_max` = **512 KiB** (`kernel/src/exec.zig:98`)
and `elf.load_max` = **512 KiB** (`kernel/src/elf.zig:145`), so the real tool
leaves **275,512 B (~269 KiB) of headroom** — room for a substantially larger
tool, not merely one more feature.

**Verdict: not a blocker. The earlier "larger tools are blocked by the size
cap" verdict is WITHDRAWN.** The loader's remaining *shape* constraints (≤2
PT_LOAD, exact data adjacency, static, no relocations) are B2's subject.

**Correction (2026-09-12, pre-merge review).** This file originally reported a
256 KiB cap and ~5% headroom, and scored that as a hard blocker. The 256 KiB
figure came from a **stale doc comment** — `kernel/src/elf.zig:26` still reads
"total load size <= `load_max` (256 KiB — the shared `exec.exec_program_max`
staging buffer bound)" — and from the matching stale cap in a repo-owned tool,
`tools/check-zc-host-contract.py`'s `LOAD_MAX = 256 * 1024` (now raised to
512 KiB to mirror the kernel; the regenerated check is in
`native-build-log.txt`). Both kernel constants were already 512 KiB at this
branch's merge base, so the tool image, its gate and its pins were always
valid — only the prose was wrong. `kernel/src/elf.zig` belongs to #1163, so
its stale comment is reported there rather than edited here.

### B4 — the wasm channel (demoted to a footnote)

The original framing was measured first and is recorded in
`artifacts/wasm-zigtool-spike/wasm-footnote.md`: oliver **compiles
contract-clean** for `wasm32-freestanding` (imports exactly the frozen
`env.*` names, 23 of 32 memory pages), but the module is 274,698 B against the
interpreter's 64 KiB `max_module_size` — 4.19× over, with the renderer-only
floor (69,300 B) already over too.

## 3. Observed vs inferred

* **Observed (live VZ, this host):** the loader accepting `OLIVER.ELF`; EL0
  execution; the file-table reads; the guest→host write landing as a real host
  file; byte-exact equality with the reference output; exit status 754;
  `argc == 0` for the raw-ELF exec (usage line + status 2 in the first live
  attempt); the loader/contract outputs quoted above.
* **Observed (host-side tooling):** sizes, PT_LOAD counts and the two contract
  failures (`tools/check-zc-host-contract.py`), the sha256 pins.
* **Inferred (not observed):** that the wasm path would be rejected with
  `wasm: module too large`/exit 4 — read from `user/src/wasm.zig`'s
  `max_module_size` (line 3098) and its fail path, plus the measured module
  size; the wasm module was never executed live. That boris-scale tools would
  be blocked by the *size* limit — **withdrawn**: with the corrected 512 KiB
  cap there is ~269 KiB of headroom, and boris's PT_LOAD/relocation shape was
  never measured (it was out of scope this round).
* **Not attempted:** demand-paging *fault* behaviour for guest stores into the
  non-`MAP_POPULATE` arena was exercised only indirectly (every page the app
  used was already touched by guest code before the kernel copied it out), so
  "demand paging works for kernel-copied buffers without `MAP_POPULATE`" is
  **not** a claim made here.

## 4. Deliberately not done

* No edits to `kernel/src/elf.zig` / `kernel/src/exec.zig` (held by #1163) and
  none to `tools/zc-host-link.ld` (canonical recipe; B2 is recorded, not
  patched).
* No vendoring of oliver's source into the repo: the branch carries the pinned
  image + the 150-line slice source + the exact rebuild recipe, with the
  vendored `src/` as untracked build input. Making the *gate* rebuild the
  image would mean committing 1.4 MB / 30k lines of a third-party project —
  a maintainer decision, flagged in `tests/oliver-spike/README.md`.
* No argument-driven invocation, no multi-file/manifest mode, no Textile or
  Cooklang dialects (the slice is the Markdown → HTML path), no xhtml profile.
* **Converters deferred:** the two non-HTML projects named in the original
  brief were not inventoried, copied, or compiled.
