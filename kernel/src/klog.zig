//! VirelaiOS klog — the kernel's serial-log seam (issue #990, claim #997).
//!
//! Kernel modules live BELOW main.zig in the import graph (main imports
//! them), so they cannot call main.zig's `uart_puts` directly. This leaf
//! module carries a function hook that main.zig points at `uart_puts` during
//! boot; any module can then emit one greppable serial line through
//! `klog.line` without an import cycle. A null hook (pre-boot, host tests)
//! is a no-op — logging must never be load-bearing.
//!
//! No allocation, no libc, no POSIX.

/// The boot-time write hook (main.zig installs `uart_puts`). Null = silent.
pub var line_hook: ?*const fn (bytes: []const u8) void = null;

/// Emit one line through the boot hook. Truncates nothing — the caller
/// formats into its own buffer. A no-op until main.zig arms the hook.
pub fn line(bytes: []const u8) void {
    if (line_hook) |hook| hook(bytes);
}
