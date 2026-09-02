/*
 * virelai.h — host-author shim for the frozen WASM `env.*` import contract
 * (docs/wasm-import-contract.md, W1a #778). Thin spelling ONLY: the
 * contract document is the ABI. Compile with
 *   zig cc -target wasm32-freestanding -nostdlib -ffreestanding -I . app.c
 * Each declaration emits `__attribute__((import_module("env"),
 * import_name("<name>")))` so wasm-ld resolves it as an import — no
 * hand-written WAT. No libc, no POSIX.
 */
#ifndef VIRELAI_H
#define VIRELAI_H

#include <stdint.h>

/* §5.1 file MODE_* flags (ADR 0010 D2) */
#define V_MODE_READ   0x1
#define V_MODE_WRITE  0x2
#define V_MODE_CREATE 0x4
#define V_MODE_APPEND 0x8
#define V_MODE_DIR    0x10
/* §5.5 mmap constants (same values as the kernel) */
#define V_PROT_READ    1
#define V_PROT_WRITE   2
#define V_PROT_EXEC    4
#define V_MAP_PRIVATE  0x02
#define V_MAP_ANONYMOUS 0x20
#define V_MAP_POPULATE 0x8000

#define V_IMPORT(n) __attribute__((import_module("env"), import_name(n)))

/* W2 debug pair (contract §7) */
V_IMPORT("write") int v_write(int fd, const void *buf, unsigned long n);
V_IMPORT("exit") __attribute__((noreturn)) void v_exit(int status);

/* §5.1 file — slots 23–27 + 34–37 */
V_IMPORT("file_open") int v_file_open(const char *path, unsigned long path_len, unsigned long flags);
V_IMPORT("file_read") int v_file_read(int fd, void *buf, unsigned long cap);
V_IMPORT("file_write") int v_file_write(int fd, const void *buf, unsigned long len);
V_IMPORT("file_close") int v_file_close(int fd);
V_IMPORT("dir_list") int v_dir_list(const char *path, unsigned long path_len, void *out, unsigned long max_entries);
V_IMPORT("file_delete") int v_file_delete(const char *path, unsigned long path_len);
V_IMPORT("file_rename") int v_file_rename(const char *old_p, unsigned long old_len, const char *new_p, unsigned long new_len);
V_IMPORT("file_truncate") int v_file_truncate(int fd, unsigned long size);
V_IMPORT("file_free") int v_file_free(unsigned long volume);

/* §5.2 window — slots 12–20 (ids 2..5, kernel-owned back-buffers) */
V_IMPORT("win_open") int v_win_open(unsigned long x, unsigned long y, unsigned long w, unsigned long h);
V_IMPORT("win_fill") int v_win_fill(int id, unsigned long x, unsigned long y, unsigned long w, unsigned long h, unsigned long rgb);
V_IMPORT("win_present") int v_win_present(int id);
V_IMPORT("win_close") int v_win_close(int id);
V_IMPORT("win_move") int v_win_move(int id, unsigned long x, unsigned long y);
V_IMPORT("win_raise") int v_win_raise(int id);
V_IMPORT("win_get") int v_win_get(int id, void *out);
V_IMPORT("win_query") int v_win_query(int id, void *out);
V_IMPORT("win_set_visible") int v_win_set_visible(int id, unsigned long visible);

/* §5.3 audio — slots 42–45 */
V_IMPORT("audio_info") int v_audio_info(void *out);
V_IMPORT("audio_play") int v_audio_play(const void *buf, unsigned long len);
V_IMPORT("audio_volume") int v_audio_volume(unsigned long vol);
V_IMPORT("audio_mute") int v_audio_mute(unsigned long muted);

/* §5.4 timers — slots 40/41 (delivery via the interpreter's event pump) */
V_IMPORT("timer_set") int v_timer_set(unsigned long delay_ticks);
V_IMPORT("timer_cancel") int v_timer_cancel(void);

/* §5.5 mmap arena — slot 63 (+ munmap 64); separate from memory.grow */
V_IMPORT("mmap") int v_mmap(unsigned long addr, unsigned long len, unsigned long prot, unsigned long flags);
V_IMPORT("munmap") int v_munmap(unsigned long addr, unsigned long len);

/* §5.6/5.7 processes + wait — slots 7/8 */
V_IMPORT("procs") int v_procs(void *buf, unsigned long max);
V_IMPORT("wait") int v_wait(unsigned long pid);

/* §5.1 DirEntry — 40 bytes LE (NOT the HF2 file-channel LIST row) */
struct v_dirent {
    char name[32];      /* NUL-padded, truncated host name */
    uint32_t size;      /* file bytes; 0 for dirs */
    uint8_t is_dir;     /* 0 = file, 1 = directory */
    uint8_t reserved[3];
};
_Static_assert(sizeof(struct v_dirent) == 40, "v_dirent must be 40 bytes");

/* §5.3 AudioInfo — 16 bytes LE (the "24 bytes" comment in kernel source is stale) */
struct v_audio_info {
    uint32_t ready;         /* 0/1; first call drives probe+SET_PARAMS */
    uint8_t format;         /* FMT_* code (0xff = none) */
    uint8_t rate;           /* RATE_* code (0xff = none) */
    uint8_t channels;       /* 1 or 2 */
    uint8_t padding;
    uint32_t period_bytes;
    uint32_t max_len;       /* 64 KiB */
};
_Static_assert(sizeof(struct v_audio_info) == 16, "v_audio_info must be 16 bytes");

#endif /* VIRELAI_H */