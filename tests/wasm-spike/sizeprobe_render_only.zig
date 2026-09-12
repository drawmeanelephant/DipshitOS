//! sizeprobe_render_only.zig — size probe (NOT a shipped tool): the lower
//! bound for any oliver HTML-emitting app. Links oliver's real
//! document.zig + html.zig and nothing else (no markdown frontend, no
//! textile, no cooklang, no C ABI), then renders a tiny in-memory document.
//! Its compiled size answers: "does the renderer+IR alone fit the
//! interpreter's 64 KiB module budget?"
const std = @import("std");
const v = @import("virelai");
const document = @import("oliver-src/document.zig");
const html = @import("oliver-src/html.zig");

var g_heap: [64 * 1024]u8 = undefined;
var g_out: [1024]u8 = undefined;

export fn _start() noreturn {
    var fba = std.heap.FixedBufferAllocator.init(&g_heap);
    const alloc = fba.allocator();
    var doc = document.Document.init(alloc, .{ .bytes = "# hi\n" }) catch v.exit(41);
    defer doc.deinit();
    var w = std.Io.Writer.fixed(&g_out);
    html.render(alloc, &w, &doc, .{}) catch v.exit(42);
    v.exit(@intCast(w.buffered().len));
}
