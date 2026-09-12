//! sizeprobe-render-only.zig — size probe (NOT a shipped tool): the floor for
//! any oliver app that emits HTML on the native target. Links oliver's real
//! document.zig + html.zig only (no Markdown frontend, no Cooklang, no CLI),
//! renders a tiny in-memory document, and exits with the rendered length.
const std = @import("std");
const zc = @import("zc");
const document = @import("vendor/oliver/src/document.zig");
const html = @import("vendor/oliver/src/html.zig");

var heap: [64 * 1024]u8 = undefined;
var out: [1024]u8 = undefined;

pub export fn _start() callconv(.c) noreturn {
    var fba = std.heap.FixedBufferAllocator.init(&heap);
    const alloc = fba.allocator();
    var doc = document.Document.init(alloc, .{ .bytes = "# hi\n" }) catch zc.exit(41);
    defer doc.deinit();
    var w = std.Io.Writer.fixed(&out);
    html.render(alloc, &w, &doc, .{}) catch zc.exit(42);
    zc.exit(w.buffered().len);
}
