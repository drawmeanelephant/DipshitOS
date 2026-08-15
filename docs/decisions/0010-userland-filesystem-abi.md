# ADR 0010: Userland Filesystem & Storage ABI

Status: **accepted** · Date: 2026-08-15 · Milestone: ten (userland filesystem & storage platform)

## Context

Milestones zero through nine delivered an AArch64 operating system on Apple silicon:
preemptive multitasking, per-process virtual memory, kernel FAT32 storage, virtio-net,
virtio-gpu window manager (Driving Award), USB xHCI / HID input, human-interface shell,
and interactive EL0 application events.

However, EL0 user programs currently have **no direct storage or filesystem access**: user
processes cannot open, read, write, or enumerate files on either the ESP or DATA FAT32 partitions.
User applications must currently hardcode all data or exchange memory buffers via IPC.

Milestone ten turns DipshitOS into a **persistent storage platform for user applications** by
exposing a bounded, safe per-process file handle table and syscall ABI (ADR 0007 slots 23–27).

This ADR establishes the normative path syntax, volume routing rules, access mode bitmasks,
directory entry wire layout, error codes, and syscall numbers.

---

## Decisions

### D1. Path syntax, volume routing, and traversal defense

All userland filesystem paths follow standard hierarchical slash (`/`) syntax:

1. **Volume Prefix Routing:**
   - `/data/<path>` or `data:<path>` routes to the persistent **DATA** volume (the Linux-FS GUID partition).
   - `/esp/<path>` or `esp:<path>` routes to the boot **ESP** volume.
   - Bare paths (e.g. `hello.txt` or `/hello.txt` without a recognized volume prefix) default to the **DATA** volume.
2. **Canonicalization & Normalization:**
   - Leading, trailing, and duplicate slashes are normalized (`//data///dir//file.txt` -> volume `DATA`, subpath `DIR/FILE.TXT`).
   - Path components are case-insensitive and mapped to FAT 8.3 / directory names.
3. **Traversal Defense:**
   - Any path containing `..` (dot-dot) component segments is strictly rejected with `-1` (`EINVAL`). User programs cannot traverse above partition roots.

---

### D2. Access mode bitmasks

The `flags` argument to `sys_file_open` is a 32-bit bitmask specifying requested operations:

| Bit | Constant | Value | Description |
|:---:|:---------|:-----:|:------------|
| 0 | `MODE_READ` | `0x0001` | Open file for reading. File must exist unless `MODE_CREATE` is also specified. |
| 1 | `MODE_WRITE` | `0x0002` | Open file for writing. |
| 2 | `MODE_CREATE` | `0x0004` | Create file if it does not exist. |
| 3 | `MODE_APPEND` | `0x0008` | Open with initial cursor at end-of-file (`size`), preserving existing content. |

- Invalid or zero flags return `-1` (`EINVAL`).
- Writing to a handle opened without `MODE_WRITE` returns `-7` (`EACCES`).
- Reading from a handle opened without `MODE_READ` returns `-7` (`EACCES`).

---

### D3. Normative 40-byte directory entry wire layout

The directory listing syscall (`sys_dir_list`) returns an array of packed, fixed-size 40-byte `DirEntry` structures:

```zig
pub const DirEntry = extern struct {
    /// NUL-terminated or padded 8.3 display filename (up to 31 chars + NUL).
    name: [32]u8,
    /// Size of the file in bytes (0 for directories).
    size: u32,
    /// 1 if entry is a subdirectory, 0 if entry is a file.
    is_dir: u8,
    /// Reserved for alignment and future metadata.
    reserved: [3]u8,
};
```

- Total size is exactly **40 bytes**: `32 + 4 + 1 + 3 = 40`.
- Memory is copied out to user memory through `uaccess.copy_out` in whole-entry increments.

---

### D4. Syscall ABI amendments (ADR 0007 slots 23–27)

Milestone 10 allocates slots 23 through 27 in the frozen ADR 0007 syscall table:

| Slot | Name | Signature | Semantics |
|:----:|:-----|:----------|:----------|
| 23 | `sys_file_open` | `open(path_ptr, path_len, flags) -> i64` | Opens or creates a file on the specified volume. Returns a non-negative file descriptor `0..7` on success, or negative error code. |
| 24 | `sys_file_read` | `read(fd, buf_ptr, count) -> i64` | Reads up to `count` bytes from open file `fd` starting at the handle's current offset into user buffer `buf_ptr`. Advances cursor. Returns bytes read (0 at EOF), or negative error code. |
| 25 | `sys_file_write` | `write(fd, buf_ptr, count) -> i64` | Writes up to `count` bytes from user buffer `buf_ptr` to open file `fd` at current cursor offset. Updates file size and advances cursor. Returns bytes written, or negative error code. |
| 26 | `sys_file_close` | `close(fd) -> i64` | Closes open file handle `fd` for the calling process and releases the handle slot. Returns `0` on success, or negative error code. |
| 27 | `sys_dir_list` | `dir_list(path_ptr, path_len, buf_ptr, max_entries) -> i64` | Enumerates directory entries at `path_ptr` and copies up to `max_entries` 40-byte `DirEntry` records to `buf_ptr`. Returns count of entries populated (>= 0), or negative error code. |

- `implemented_count` in `kernel/src/syscall.zig` becomes **28** (slots 0..27).
- All pointers crossing EL0/EL1 boundary strictly validate through `uaccess.copy_in` and `uaccess.copy_out`.

---

### D5. Return error codes

Negative return values encode error conditions:

| Value | Constant | Meaning |
|:-----:|:---------|:--------|
| 0 | success | Operation completed successfully. |
| -1 | `EINVAL` | Invalid argument, bad flags, `..` path traversal, or arithmetic overflow. |
| -2 | `EBADF` | Invalid file descriptor (out of range `0..7` or handle slot not in use). |
| -3 | `EFAULT` | User pointer outside valid text/stack aperture or fault during copy. |
| -4 | `ENOSYS` | Unimplemented or unknown syscall slot. |
| -5 | `ENOSPC` | Per-process handle table full (8 open handles max) or disk partition full. |
| -6 | `ENOENT` | File or parent directory path not found. |
| -7 | `EACCES` | Permission denied (e.g. write on read-only handle or invalid volume write). |
| -8 | `ENAMETOOLONG` | Path string or component exceeds maximum supported length (64 bytes). |

---

### D6. Process isolation and handle table bounds

- **Handle Capacity:** Exactly 8 open file handles per process slot (`max_handles_per_process = 8`).
- **Memory Discipline:** Statically allocated in kernel BSS (`[process.max_processes][8]FileHandle`). 0 heap allocation.
- **Process Isolation:** File descriptors are per-process integers `0..7`. Process A cannot read, write, or close Process B's handles.
- **Lifecycle Cleanup:** All open handles belonging to a process are automatically closed and released when `exit_current` or `process.free` is executed.

---

### D7. Enforceability and verification gates

| Subsystem | Requirement | Gate |
|:----------|:------------|:-----|
| Contract | Wire layout, bitmasks, 40B `DirEntry`, error codes | Class A unit tests (`kernel/src/file_table.zig`) |
| Handle table | 8 handles per process, offset tracking, isolation | Class A unit tests (`kernel/src/file_table.zig`) |
| Path routing | `/esp/`, `/data/`, bare paths, traversal rejection | Class A unit tests (`kernel/src/file_table.zig`) |
| Syscall seam | Slots 23–27 uaccess dispatch and error return | Class A unit tests (`kernel/src/syscall.zig`) |
| Persistent apps | `SAVETEXT.BIN`, `TYPE.BIN`, `DIR.BIN` on live VZ | Class B capstone gate (`tools/verify-live-user-fs.sh`) |

---

## Consequences

- EL0 user programs can persistently store, retrieve, and enumerate files on disk.
- Data written by one process or boot session persists across system reboots on the DATA partition.
- Syscall dispatch table grows to 28 implemented slots (0..27).
