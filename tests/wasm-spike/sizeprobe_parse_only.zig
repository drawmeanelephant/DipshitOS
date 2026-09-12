//! sizeprobe_parse_only.zig — size probe (NOT a shipped tool): links
//! oliver's real document.zig + markdown.zig and nothing else, parses a tiny
//! in-memory document, and exits with the parsed node count. Its compiled
//! size isolates the Markdown frontend's cost from the renderer's.
const std = @import("std");
const v = @import("virelai");
const document = @import("oliver-src/document.zig");
const markdown = @import("oliver-src/markdown.zig");
const diagnostic = @import("oliver-src/diagnostic.zig");

var g_heap: [64 * 1024]u8 = undefined;

export fn _start() noreturn {
    var fba = std.heap.FixedBufferAllocator.init(&g_heap);
    const alloc = fba.allocator();
    var doc = document.Document.init(alloc, .{ .bytes = "# hi\n" }) catch v.exit(41);
    defer doc.deinit();
    var diags = std.ArrayList(diagnostic.Diagnostic).empty;
    defer diags.deinit(alloc);
    markdown.parse(&doc, &diags, .{}) catch v.exit(42);
    v.exit(@intCast(doc.root.children.items.len));
}
