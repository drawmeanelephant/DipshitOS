# WASM `env.*` import contract — frozen (W1a, #778)

Status: **FROZEN** · Date: 2026-09-01 · **Amended 2026-09-01 (audit, claim 5335):** §5.1 `file_open` MODE_* flags + DirEntry layout, §5.3 AudioInfo (16 B), §5.5 munmap, §6 list — corrected against the kernel dispatch table · Owner: W1a (#778) \
Source of truth for: W3 (#764, import breadth), W5 (#766, `wc` capstone) \
Normative syscall ABI: `docs/decisions/0007-syscall-abi.md` (ADR 0007) \
Scoping doc: `docs/wasm-core-scoping.md` (W1a–W5 gated split)

> A **fresh host author** can implement any listed `env.*` import from this
> document alone, without reading `kernel/src/syscall.zig`. Parameter shapes,
> linear-memory conventions, and per-import error mappings are frozen here.
> Unlisted imports are **not** in scope for M35; W3/W5 bodies reference this
> file normatively.

---

## 1. Namespace and module shape

* **Import module name:** `env` (one namespace). Every import below is
  `env.<name>`. No `wasi_snapshot_preview1`, no `env` drift, no ad-hoc
  growth — the W3 card grows only within this frozen list.
* **Wasm target:** `wasm32` (`i32` pointers/lengths, `i64` for a few kernel
  64-bit values when noted). The interpreter validates the module, instantiates
  exactly **one linear memory** (see §3), one function table for
  `call_indirect`, and the `env.*` imports listed in §5. Unknown imports
  → validation failure (trap before start).
* **Calling convention:** imports are ordinary wasm imports; the interpreter
  dispatches each call through the ADR 0007 `svc #0` seam (`x8 = slot`,
  `x0..x5 = args`, `x0 = result`). No new syscall slots, no kernel change.

### Host shims (non-normative, author convenience)

* `virelai.h` (C) and `virelai.zig` (Zig) emit `__attribute__((import_module("env"), import_name("<name>")))` / `extern "env"` declarations matching the WAT signatures in §5, so normal freestanding C (`zig cc -target wasm32-freestanding -nostdlib`) links without hand-written WAT. The shims are thin spelling; **this document** is the ABI, not the header.

---

## 2. Three pinned decisions (W1a)

These are frozen here, not re-decided in W1b/W3/W5.

### D1 — Go wasm deferred to post-M35 (option b)

* `GOOS=wasip1 GOARCH=wasm` output imports **WASI** symbols (`wasi_snapshot_preview1.*`), not `env.*`. The shim question (a `wasi → env` adaptor vs. a separate WASI surface) is **documented, not built**.
* **M35 scope:** `zig cc -target wasm32-freestanding` (684-B trivial module,
  proven) and `rustc --target wasm32-unknown-unknown` only. The W2 live gate
  uses the 684-B `zig cc` fixture, not the 1.9-MB Go fixture.
* Rationale: keeping the import surface ADR-0007-shaped, not POSIX-shaped,
  upholds the project's reject-POSIX premise; Go's runtime shape (goroutine
  scheduler, WASI imports) is larger than the bounded first interpreter.
* Post-M35: revisit under a new card with an explicit WASI-shim design.

### D2 — Linear memory capped at 2 MiB / 32 pages; `memory.grow` beyond traps

* **Initial/max pages:** the module may declare `memory 0..32` (1 page = 64 KiB).
  The interpreter backs the reservation with `sys_mmap` (slot 63, ADR 0007/M29)
  — `MAP_ANONYMOUS|MAP_PRIVATE`, on demand (not `MAP_POPULATE`), zero-filled
  on first fault (the M29 demand-paging seam). The reservation is per-instance,
  in the calling WASM.BIN process's address space, not a global kernel pool.
* **Cap:** **2 MiB (32 pages) total**. `memory.size` returns current pages;
  `memory.grow(delta)`:
  * if `current + delta ≤ 32` → grow, zero-fill new pages, return old size;
  * if `current + delta > 32` → **trap** (wasm `unreachable`-class trap,
    diagnostic names `module+offset`, no partial grow, no wrap).
  Behavior is identical for `memory.grow 0` probing. The interpreter never
  silently clamps; it traps. `memory.grow` is the **only** way wasm memory
  grows — `env.mmap` (§5.10) is a separate, opt-in heap seam, not the linear
  memory itself.
* **Multiple memories:** out of scope for M35 (one memory only, imported
  memory not supported). Spec proposal `multi-memory` is explicitly deferred.
* **OOB access:** any `load`/`store` with `addr + width` outside the current
  bounds traps (the validator does not prove bounds; the executor checks each
  access). The trap naming rule (every trap names `module+offset`) applies.

### D3 — W5 capstone = `wc`

* **The M35 capstone app is `wc`** — byte/line/word counts over file-channel
  reads, byte-exact. `wc` exercises the file imports (23–27 + 34–37) as data,
  not ELF, and is integer-only (so W4 floats are tied to a separate **named**
  C float utility, not to `wc`). `wc` ships as an HF4 app (`wc.wasm` dropped
  into `--cvc-file` and run via `exec WASM.BIN wc.wasm`).
* **Provenance proof (§5 rule for W5):** a second app written **from this
  contract alone** (no interpreter source read) compiles against `virelai.h`
  and runs — the W5 gate's standalone-author test.
* Deferred candidates (`cat`, `hexdump`, etc.) are post-M35.

---

## 3. Linear-memory conventions (applies to every import with a pointer)

* **Pointer = `i32` offset** into the single linear memory. `0` is a valid
  null only where noted; for most buffer/path pointers, `ptr + len` must lie
  within `memory.size × 64KiB`, else the import traps (not `EFAULT`) — the
  interpreter validates the range **before** copying. Zero-length with any
  `ptr` is valid (no access).
* **Lengths/caps = `i32`** (`u32` semantics, ≥0). Where the kernel caps at
  `2048`/`64`/etc., the interpreter honors the cap by truncation or error per
  §5, without growing memory.
* **Strings/paths:** byte strings, **not** NUL-terminated. `path_ptr/path_len`
  are `(i32,i32)` slices. `max_path_len = 64` (ADR 0010 / `file_table.zig`);
  longer → `EINVAL`/`ENAMETOOLONG` per row. `/`-separated, root-relative;
  `..` is rejected (no traversal).
* **Copy discipline:** every pointer-taking import crosses the kernel
  `uaccess` window (`copy_in`/`copy_out`); if the wasm bounds check passed but
  the kernel's own copy faults, the result is `EFAULT` (−3), never a kernel
  panic — same as the EL0 syscall seam.
* **Little-endian:** multi-byte structs in memory are LE (wasm's native
  endianness). The `AudioInfo` and `DirEntry` layouts in §5 are LE.

---

## 4. Error model

* **Return type:** every import returns `i32`. Non-negative = success value
  (bytes, handle, count, address). Negative = `−errno` from the kernel's
  `ErrorCode` enum (bit-cast of the `i64` in the `x0` result, truncated to
  `i32` — still negative, sign-preserved):

  | `errno` | Code | Meaning (kernel) |
  |--------:|------|------------------|
  | −1 | `EINVAL` | bad argument / geometry / over-long path / zero clamp / unknown window / bad flags |
  | −2 | `EBADF` | bad file handle fd |
  | −3 | `EFAULT` | bad wasm pointer caught at kernel copy boundary (wasm OOB already trapped earlier) |
  | −4 | `ENOSYS` | unknown syscall number / subcommand (not exposed as env.*) |
  | −5 | `ENOSPC` | file table full / window slots full / region table full |
  | −6 | `ENOENT` | file/path not found |
  | −7 | `EACCES` | not the window owner, or not authorized to re-map a shared region |
  | −8 | `ENAMETOOLONG` | 8.3 / path-name too long (where noted) |
  | −9 | `ENXIO` | no device / unarmed compositor (audio, GPU) |
  | −10 | `ENOMEM` | page allocation / region-list exhaustion |

* **Not POSIX `errno`:** no global, no `perror`, no libc — the negative
  return is the whole error. W3/W5 apps switch on the `i32` directly (or use
  the `virelai.h` constants).
* **Determinism:** success and error returns are pinned by fixtures in
  `tests/wasm-corpus/` (W1b/W3/W4 gates) — byte-identical outputs.

---

## 5. Frozen import surface — `env.*` → ADR 0007

The only imports W3 implements. Each row gives the WAT signature, the kernel
slot it dispatches to, and the per-import argument/error shape. Unless noted,
**all `ptr`/`len` pairs follow §3** and all `i32` returns follow §4.

### 5.1 File — slots 23–27 (ADR 0010) + 34–37 (M13 mutating)

| Wasm import (WAT) | Slot | Signature (wasm) | Success → | Error mapping |
|-------------------|------|-------------------|-----------|---------------|
| `env.file_open` `(ptr i32, len i32, flags i32) -> i32` | 23 `sys_file_open` | `path_ptr, path_len, flags` — `flags` are ADR 0010 D2 `MODE_*` bits: bit0 `MODE_READ 0x1`, bit1 `MODE_WRITE 0x2`, bit2 `MODE_CREATE 0x4`, bit3 `MODE_APPEND 0x8`, bit4 `MODE_DIR 0x10` (create-directory); READ or WRITE required; `flags==0` or unknown bits → `EINVAL` | fd `0..7` (per-process, ≤8 handles) | `EINVAL` bad path/zero/over-64/invalid flags, `EFAULT` bad ptr, `ENOENT` absent, `ENAMETOOLONG` name too long, `ENOSPC` table full |
| `env.file_read` `(fd i32, buf i32, cap i32) -> i32` | 24 `sys_file_read` | reads at most `cap` bytes (kernel stages ≤2048, honest truncation — `cap=0` → 0) | bytes read `0..cap` (`0` = EOF) | `EBADF` bad/closed fd, `EFAULT` bad buf (on non-empty read), `ENOSPC` if `cap>2048` is **not** an error — it truncates to 2048 (the kernel's `take_count` clamp) |
| `env.file_write` `(fd i32, buf i32, len i32) -> i32` | 25 `sys_file_write` | writes exactly `len` bytes (kernel stages ≤2048; `len>2048` → error, not truncation) | bytes written `== len` | `EBADF`, `EFAULT`, `ENOSPC` when `len>2048` |
| `env.file_close` `(fd i32) -> i32` | 26 `sys_file_close` | — | `0` | `EBADF` |
| `env.dir_list` `(path_ptr i32, path_len i32, out_ptr i32, max_entries i32) -> i32` | 27 `sys_dir_list` | `path` empty (`len 0`) = root; `path_ptr` ignored when `len==0` (any value OK); `max_entries==0` → `0` | entry count actually written `0..min(max_entries,16)` (each entry is 40-byte `DirEntry` — see below); also copies the entries into `out_ptr` | `EINVAL` non-process caller, `EFAULT` bad path/out ptr, `ENAMETOOLONG` path>64, `ENOENT` absent path |
| `env.file_delete` `(path_ptr i32, path_len i32) -> i32` | 34 `sys_file_delete` | — | `0` | `EINVAL` bad path/empty/directory, `ENOENT`, `EFAULT` |
| `env.file_rename` `(old_ptr i32, old_len i32, new_ptr i32, new_len i32) -> i32` | 35 `sys_file_rename` | same-directory rename only (cross-directory → `EINVAL`); target-exists → `EINVAL` (no `EEXIST` row) | `0` | `EINVAL` bad path/cross-dir/exists, `ENAMETOOLONG` bad 8.3, `ENOENT`, `EFAULT` |
| `env.file_truncate` `(fd i32, size i32) -> i32` | 36 `sys_file_truncate` | resize OPEN handle to `size` (shrink truncates, grow zero-fills; kernel bound ≤2048) | `0` | `EBADF` bad/closed handle, `EACCES` not open for write, `ENOSPC` size over bound, `ENOENT` |
| `env.file_free` `(volume i32) -> i32` | 37 `sys_file_free` | `volume` `0` = DATA, `1` = ESP; query only | free bytes on volume (`≥0`, fits in `i32` on current volumes) | `EINVAL` bad volume, `ENOENT` unmounted, `EFAULT` n/a (no ptr) |

**`DirEntry` layout** at `out_ptr` (LE, 40 bytes per entry — ADR 0010 D3's
`file_table.DirEntry`, verified from `handle_dir_list`'s `copy_out`; NOT the
HF2 file-channel LIST row, which is a different 40-byte shape):

```
offset  size  field
0       32    name (NUL-padded, truncated host name ≤32 bytes shown)
32      4     size  (u32 LE, file bytes; 0 for dirs)
36      1     is_dir  (0 = file, 1 = directory)
37      3     reserved (zero)
```

WAT helper in `virelai.h`: `struct v_dirent { char name[32]; uint32_t size; uint8_t is_dir; uint8_t reserved[3]; }` with `_Static_assert(sizeof==40)`.

### 5.2 Window — slots 12–20 (M6 G5/G6, ADR 0011)

Windows are ids `2…5` (up to 4 user windows), owned by the creating process
(auto-close on `exit`). Rendering is via kernel-owned back-buffers; the wasm
app never holds a framebuffer pointer. Geometry is window-local.

| Wasm import (WAT) | Slot | Signature (wasm) | Success → | Error mapping |
|-------------------|------|-------------------|-----------|---------------|
| `env.win_open` `(x i32, y i32, w i32, h i32) -> i32` | 12 `sys_win_open` | `x,y` top-left, `w,h` size (pixels) | window id `2..5` | `EINVAL` bad geometry/outside scanout or no GPU, `ENOSPC` both / all slots full, `EINVAL` non-process caller |
| `env.win_fill` `(id i32, x i32, y i32, w i32, h i32, rgb i32) -> i32` | 13 `sys_win_fill` | fill rect `x,y,w,h` in window `id` with `0xRRGGBB` (24-bit) | `0` | `EINVAL` unknown id / not owner / rect outside window / bad rgb |
| `env.win_present` `(id i32) -> i32` | 14 `sys_win_present` | mark window `id` dirty → compositor blits on next idle tick | `0` | `EINVAL` unknown id / not owner |
| `env.win_close` `(id i32) -> i32` | 15 `sys_win_close` | release owned window (frees id) | `0` | `EINVAL` unknown/fixed window or not owner |
| `env.win_move` `(id i32, x i32, y i32) -> i32` | 16 `sys_win_move` | reposition top-left to `x,y` (clamped on-scanout) | `0` | `EINVAL` unknown/not owner/bad geometry/no GPU |
| `env.win_raise` `(id i32) -> i32` | 17 `sys_win_raise` | raise owned window to top of z-order | `0` | `EINVAL` unknown/not owner |
| `env.win_get` `(id i32, out_ptr i32) -> i32` | 18 `sys_win_get` | copies geometry `x,y,w,h` as 4×`u32` LE (16 bytes) to `out_ptr` | `0` | `EINVAL` unknown/fixed/not owner, `EFAULT` bad `out_ptr` |
| `env.win_query` `(id i32, out_ptr i32) -> i32` | 19 `sys_win_query` | copies full state `x,y,w,h,z,focused,visible,dirty` as 8×`u32` LE (32 bytes) to `out_ptr` | `0` | `EINVAL` unknown/fixed/not owner, `EFAULT` bad ptr |
| `env.win_set_visible` `(id i32, visible i32) -> i32` | 20 `sys_win_set_visible` | `visible` `0`=hide, `1`=show | `0` | `EINVAL` unknown/fixed/not owner or `visible∉{0,1}` |

Notes: `win_get`/`win_query` are the only window imports with a pointer.

### 5.3 Audio — slots 42–45 (M15, virtio-snd)

| Wasm import (WAT) | Slot | Signature (wasm) | Success → | Error mapping |
|-------------------|------|-------------------|-----------|---------------|
| `env.audio_info` `(out_ptr i32) -> i32` | 42 `sys_audio_info` | copies 16-byte `AudioInfo` to `out_ptr` (see layout) | `0` | `EINVAL` non-process caller, `EFAULT` bad ptr |
| `env.audio_play` `(buf i32, len i32) -> i32` | 43 `sys_audio_play` | play `len` bytes of PCM (format/rate/channels as reported by `audio_info`) | bytes played `== len` | `EINVAL` zero len / non-process caller, `ENAMETOOLONG` `len>64 KiB`, `EFAULT` bad ptr, `ENXIO` no sound device or device refusal |
| `env.audio_volume` `(vol i32) -> i32` | 44 `sys_audio_volume` | `vol` `0..100` percent (kernel-side gain; persists across `--sound` re-attach) | `vol` (echoed) | `EINVAL` out-of-range / non-process caller |
| `env.audio_mute` `(muted i32) -> i32` | 45 `sys_audio_mute` | `muted` `0`=unmute, `1`=mute (zeroed samples still drain) | `0` | `EINVAL` `muted∉{0,1}` |

**`AudioInfo` layout** at `out_ptr` (LE, **16 bytes** — `kernel/src/virtio_snd.zig`
`AudioInfo`, verified `@sizeOf == 16`; the "24 bytes" comment in the kernel
source is stale):

```
offset  size  field            semantics (observed VZ, claims 6140/7636)
0       4     ready            u32 0/1 (first call drives probe+SET_PARAMS; later cached)
4       1     format           u8 negotiated FMT_* code (0xff = none)
5       1     rate             u8 negotiated RATE_* code (0xff = none)
6       1     channels         u8 1 or 2 (VZ is stereo 2)
7       1     padding          u8 (zero)
8       4     period_bytes     u32 negotiated period size
12      4     max_len          u32 64 KiB (audio_max_len)
```

WAT helper: `struct v_audio_info { uint32_t ready; uint8_t format, rate, channels, padding; uint32_t period_bytes, max_len; }` with `_Static_assert(sizeof==16)`.

### 5.4 Timers — slots 40/41 (M14 S2)

| Wasm import (WAT) | Slot | Signature (wasm) | Success → | Error mapping |
|-------------------|------|-------------------|-----------|---------------|
| `env.timer_set` `(delay_ticks i32) -> i32` | 40 `sys_timer_set` | arm calling process's ONE-shot app timer to fire a `TIMER` event (kind 9, ADR 0009) after `delay_ticks` scheduler ticks; `0` clamps to `1`; over-long truncates at `3600`; re-arm replaces pending | `0` | `EINVAL` non-process caller (never `EFAULT` — no pointer) |
| `env.timer_cancel` `() -> i32` | 41 `sys_timer_cancel` | disarm pending timer | `1`=canceled, `0`=none armed | `EINVAL` non-process caller |

Timer delivery goes through the per-process event queue (`sys_poll_event`/
`sys_wait_event` are **not** part of this `env.*` surface — the wasm app
receives `TIMER` via the interpreter's event pump, not by importing the raw
event syscalls; the translator drains ticks via the scheduler's `on_tick` seam.
If a future card needs explicit poll/wait imports, it extends this contract
by ADR, not ad hoc.

### 5.5 Mmap — slot 63 (M29/M33)

| Wasm import (WAT) | Slot | Signature (wasm) | Success → | Error mapping |
|-------------------|------|-------------------|-----------|---------------|
| `env.mmap` `(addr i32, len i32, prot i32, flags i32) -> i32` | 63 `sys_mmap` | anonymous mapping only — `flags` must include `MAP_ANONYMOUS 0x20`; `prot` bits `1=R,2=W,4=X`; `len==0` or `len>16 MiB` → `EINVAL`; `addr==0` or page-aligned hint else next-fit | wasm offset `≥0` (kernel VA truncated to `i32` — the interpreter maps it as the wasm heap arena offset; fits in 2 MiB window) | `EINVAL` bad len/flags/prot or `MAP_ANONYMOUS` missing, `ENOMEM` no pages/region slots, `ENOSPC` shared-region table full (shared flag path — not in base M35; see below), `EFAULT` n/a at wasm level (pointer traps earlier), `EACCES` shared re-map unauthorized |

**Constants (same values as kernel):**
`PROT_READ=1, PROT_WRITE=2, PROT_EXEC=4, MAP_PRIVATE=0x02, MAP_ANONYMOUS=0x20, MAP_POPULATE=0x8000`.
**`M33_MAP_SHARED 0x10000` and the high-tag scanout/window binds (`0x4000…`/`0x8000…`) are RESERVED and not exposed via `env.mmap` in M35** — a wasm `mmap` carrying them returns `EINVAL` until a future ADR explicitly widens this row. The linear-memory backing described in D2 uses the plain M29 path internally; the interpreter does not expose the seam-B surface tags to wasm.

The `env.mmap` area is **separate** from `memory.grow` (§2 D2): `memory.grow`
extends the single linear memory; `mmap`/`munmap` manage a disjoint heap arena
the `virelai.h` bump allocator (`malloc` shim) uses. Both are `0..2 MiB`
capped at the interpreter level; `munmap` below tears down the arena.

| Wasm import (WAT) | Slot | Signature (wasm) | Success → | Error mapping |
|-------------------|------|-------------------|-----------|---------------|
| `env.munmap` `(addr i32, len i32) -> i32` | 64 `sys_munmap` | unmap a prior `mmap` region (page-aligned `addr`, non-zero `len`; full-region only for scanout/shared surfaces) | `0` | `EINVAL` zero/unaligned `addr`, zero `len`, or partial unmap of a scanout/shared region |

> `munmap` is listed for completeness — it is **not** part of the W3 frozen
> set (the prompt's "mmap 63" row is the capstone requirement), but the
> interpreter exposes it with this shape so the `virelai.h` heap can free
> arenas. W3's `wc` does not require it.

### 5.6 Processes — slot 7 (follow-on 4, 4a)

| Wasm import (WAT) | Slot | Signature (wasm) | Success → | Error mapping |
|-------------------|------|-------------------|-----------|---------------|
| `env.procs` `(buf i32, max i32) -> i32` | 7 `sys_procs` | copy a bounded snapshot of the process table into `buf` (`max` bytes, floored to whole 40-byte rows — honest truncation); `max==0` → `0`; each row 40 bytes `{pid:u64, state:u64, exit_status:u64, name:char[16]}` LE (`state` 1=created, 2=running, 3=exited) | row count written `≥0` | `EFAULT` bad `buf` |

### 5.7 Wait — slot 8 (follow-on 4, 4c)

| Wasm import (WAT) | Slot | Signature (wasm) | Success → | Error mapping |
|-------------------|------|-------------------|-----------|---------------|
| `env.wait` `(pid i32) -> i32` | 8 `sys_wait` | block until process `pid` exits, then return its `exit_status`; already-exited → immediate; waiting on self / `created` / free / out-of-range → `EINVAL` | exit status (`≥0`) | `EINVAL` bad target / self-wait / `created` state / not a process, `EFAULT` n/a |

---

## 6. What is NOT in the contract (explicit out of scope)

* **WASI** — not exposed; `wasi_snapshot_preview1.*` imports always fail validation.
* **Threads / atomics / SIMD / bulk-memory / multi-memory / GC** — traps or validation failure.
* **Floating point** (W4) — `f32`/`f64` and their ops are **not** in the W1b/W3 subset; W4 adds them with a named float utility as gate. Linking a float-using module before W4 traps at validation.
* **Networking (slots 9–11, 30–33), clipboard (38–39), exec/kill (28/29), wmctl (65)** — not `env.*` in M35. Raw `poll_event`/`wait_event` (21/22) are not imports; the interpreter pumps events.
* **Window-depth and other kernel syscalls not in §5** — win_fill_batch (46), win_resize (47), win_raise_front (49), win_lower_back (50), notify (51), win_set_unsaved (53), drag_read (55), pipe_read/pipe_write (56/57), font_size (58), ping_send/ping_poll (59/60), win_set_title (61), net_stats (62) — all reserved for M35; a wasm app needing resize/title/unsaved flags is a future contract extension by ADR, never ad hoc.
* **File-system mutation beyond §5.1:** pipe/mmap-shared tags/scanout — reserved.
* Any import not listed in §5 — validation failure, never silent.

---

## 7. Verification & author recipe

* **Compile C:** `zig cc -target wasm32-freestanding -nostdlib -I . app.c virelai.c -o app.wasm` (or Rust `rustc --target wasm32-unknown-unknown` with the `virelai.zig` shim). Inspect with `wasm-objdump -x app.wasm` — imports must be exactly `env.*` from §5.
* **Drop & run:** copy `app.wasm` into the host share (`--cvc-file <dir>`) → guest `exec WASM.BIN app.wasm`. File paths resolve inside the share root; `write(1, ...)` (if used via the debug `env.write` shim) lands on the console byte-exact.
* **Determinism:** modules are data — byte-identical input, deterministic traps. Gate fixtures pin stdout/exit/status exactly.

---

## 8. Normative references

* ADR 0007 — slot numbers, error codes, dispatch-table shape (§4, §5).
* ADR 0009 — `TIMER` event kind 9 pumped by `timer_set`.
* ADR 0010 — file pathname canon and `DirEntry` wire shape (§5.1).
* ADR 0011 — window registry and compositor (§5.2).
* `docs/wasm-core-scoping.md` — M35 gated card split (W1a/W1b/W2–W5) and proposal survey.

W3 implementors: implement imports exactly as §5; W5 (`wc`) authors: use only §5.
