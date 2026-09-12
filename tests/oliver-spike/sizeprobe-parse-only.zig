//! sizeprobe-parse-only.zig — size probe (NOT a shipped tool): links oliver's
//! real document.zig + markdown.zig and nothing else, parses a tiny in-memory
//! document, and exits with the parsed node count. Isolates the Markdown
//! frontend's cost from the renderer's on the native target.
const std = @import("std");
const zc = @import("zc");
const document = @import("vendor/oliver/src/document.zig");
const markdown = @import("vendor/oliver/src/markdown.zig");
const diagnostic = @import("vendor/oliver/src/diagnostic.zig");

var heap: [64 * 1024]u8 = undefined;

pub export fn _start() callconv(.c) noreturn {
    var fba = std.heap.FixedBufferAllocator.init(&heap);
    const alloc = fba.allocator();
    var doc = document.Document.init(alloc, .{ .bytes = "# hi\n" }) catch zc.exit(41);
    defer doc.deinit();
    var diags = std.ArrayList(diagnostic.Diagnostic).empty;
    defer diags.deinit(alloc);
    markdown.parse(&doc, &diags, .{}) catch zc.exit(42);
    zc.exit(doc.root.children.items.len);
}
