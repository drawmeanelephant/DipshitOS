//! VirelaiOS HTML layout (M-web S1, ADR 0028 D3).
//!
//! Nodes + UA style + content width → block boxes and line boxes. Pure: the
//! measure function is injected so host tests stub 8 px/char instead of a
//! real face. Paint lives in `user/src/doc.zig`.
//!
//! Wrap rule is NOTEPAD's `TextLayout.last_space` (claim 1771): overflow
//! breaks at the last space on the line; no space → a hard break.

const std = @import("std");
const parse = @import("parse.zig");

pub const max_blocks: usize = 256;
pub const max_lines: usize = 512;
pub const max_spans: usize = 1024;
pub const page_margin: u32 = 10;
pub const quote_bar_w: u32 = 2;
pub const quote_indent: u32 = 12;
pub const list_indent: u32 = 16;
pub const pre_indent: u32 = 8;
pub const hr_height: u32 = 1;

pub const MeasureFn = *const fn (text: []const u8, mono: bool, size: u32) u32;

pub const SpanFlags = packed struct(u8) {
    bold: bool = false,
    em: bool = false,
    link: bool = false,
    mono: bool = false,
    _pad: u4 = 0,
};

pub const Span = struct {
    text_off: u16 = 0,
    text_len: u16 = 0,
    x: u16 = 0,
    w: u16 = 0,
    size: u8 = 14,
    flags: SpanFlags = .{},
    href_off: u16 = 0,
    href_len: u16 = 0,
};

pub const Line = struct {
    y: u16 = 0,
    h: u16 = 0,
    x: u16 = 0,
    first_span: u16 = 0,
    span_count: u16 = 0,
};

pub const BlockKind = enum(u8) {
    flow,
    pre,
    hr,
};

pub const Marker = enum(u8) {
    none,
    disc,
    decimal,
};

pub const Block = struct {
    tag: parse.Tag = .p,
    y: u16 = 0,
    h: u16 = 0,
    x: u16 = 0,
    w: u16 = 0,
    kind: BlockKind = .flow,
    quote_bar: bool = false,
    marker: Marker = .none,
    marker_index: u8 = 0,
    first_line: u16 = 0,
    line_count: u16 = 0,
};

pub const Layout = struct {
    blocks: []Block,
    block_count: u16,
    lines: []Line,
    line_count: u16,
    spans: []Span,
    span_count: u16,
    text: []const u8,
    content_h: u32,
    truncated: bool,

    pub fn spanText(self: Layout, s: Span) []const u8 {
        return self.text[s.text_off .. s.text_off + s.text_len];
    }
};

pub const Style = struct {
    size: u32,
    before: u32,
    after: u32,
    indent: u32,
    leading: u32,
    mono: bool,
};

pub fn styleOf(tag: parse.Tag) Style {
    return switch (tag) {
        .h1 => .{ .size = 24, .before = 12, .after = 8, .indent = 0, .leading = 6, .mono = false },
        .h2 => .{ .size = 18, .before = 10, .after = 6, .indent = 0, .leading = 5, .mono = false },
        .h3 => .{ .size = 15, .before = 8, .after = 4, .indent = 0, .leading = 4, .mono = false },
        .pre => .{ .size = 13, .before = 8, .after = 8, .indent = pre_indent, .leading = 4, .mono = true },
        .blockquote => .{ .size = 14, .before = 6, .after = 6, .indent = quote_indent, .leading = 4, .mono = false },
        .ul, .ol => .{ .size = 14, .before = 4, .after = 4, .indent = list_indent, .leading = 4, .mono = false },
        .li => .{ .size = 14, .before = 2, .after = 2, .indent = 0, .leading = 4, .mono = false },
        .hr => .{ .size = 1, .before = 8, .after = 8, .indent = 0, .leading = 0, .mono = false },
        else => .{ .size = 14, .before = 0, .after = 8, .indent = 0, .leading = 4, .mono = false },
    };
}

pub fn lineHeight(tag: parse.Tag) u32 {
    const s = styleOf(tag);
    return s.size + s.leading;
}

pub fn stubMeasure(text: []const u8, mono: bool, size: u32) u32 {
    _ = mono;
    _ = size;
    return @as(u32, @intCast(text.len)) * 8;
}

pub fn layout(
    doc: parse.Document,
    width: u32,
    blocks: []Block,
    lines: []Line,
    spans: []Span,
    measure: MeasureFn,
) Layout {
    var eng = Engine{
        .doc = doc,
        .width = if (width > 2 * page_margin) width - 2 * page_margin else width,
        .blocks = blocks,
        .lines = lines,
        .spans = spans,
        .measure = measure,
        .y = page_margin,
    };
    if (doc.node_count > 0) {
        eng.flowChildren(0, page_margin, eng.width, .p);
    }
    eng.content_h = eng.y + page_margin;
    return .{
        .blocks = blocks,
        .block_count = eng.block_count,
        .lines = lines,
        .line_count = eng.line_count,
        .spans = spans,
        .span_count = eng.span_count,
        .text = doc.text[0..doc.text_len],
        .content_h = eng.content_h,
        .truncated = eng.truncated or doc.truncated,
    };
}

const Engine = struct {
    doc: parse.Document,
    width: u32,
    blocks: []Block,
    lines: []Line,
    spans: []Span,
    measure: MeasureFn,
    y: u32 = 0,
    block_count: u16 = 0,
    line_count: u16 = 0,
    span_count: u16 = 0,
    content_h: u32 = 0,
    truncated: bool = false,

    fn flowChildren(self: *Engine, parent: u16, x: u32, w: u32, inherit: parse.Tag) void {
        var idx = self.doc.nodes[parent].first_child;
        var run_head: u16 = parse.none;
        while (idx != parse.none) {
            const tag = self.doc.nodes[idx].tag;
            if (parse.isBlock(tag) and tag != .document) {
                self.flushRun(run_head, x, w, inherit);
                run_head = parse.none;
                self.layoutBlock(idx, x, w);
            } else {
                if (run_head == parse.none) run_head = idx;
            }
            idx = self.doc.nodes[idx].next_sibling;
        }
        self.flushRun(run_head, x, w, inherit);
    }

    fn flushRun(self: *Engine, head: u16, x: u32, w: u32, inherit: parse.Tag) void {
        if (head == parse.none) return;
        if (!runHasInk(self.doc, head)) return;
        const st = styleOf(inherit);
        self.addBlock(.{
            .tag = inherit,
            .y = @intCast(self.y),
            .x = @intCast(x),
            .w = @intCast(w),
            .kind = .flow,
            .first_line = self.line_count,
        });
        const start_y = self.y;
        const first_line = self.line_count;
        self.wrapInlines(head, x, w, inherit);
        const b = &self.blocks[self.block_count - 1];
        b.line_count = self.line_count - first_line;
        b.h = @intCast(self.y - start_y);
        self.y += st.after;
    }

    fn layoutBlock(self: *Engine, idx: u16, x: u32, w: u32) void {
        const tag = self.doc.nodes[idx].tag;
        const st = styleOf(tag);
        self.y += st.before;
        const inner_x = x + st.indent;
        const inner_w = if (w > st.indent) w - st.indent else w;

        if (tag == .hr) {
            self.addBlock(.{
                .tag = .hr,
                .y = @intCast(self.y),
                .h = hr_height,
                .x = @intCast(x),
                .w = @intCast(w),
                .kind = .hr,
            });
            self.y += hr_height + st.after;
            return;
        }

        if (tag == .pre) {
            self.layoutPre(idx, inner_x, inner_w, st);
            self.y += st.after;
            return;
        }

        if (tag == .ul or tag == .ol) {
            self.addBlock(.{
                .tag = tag,
                .y = @intCast(self.y),
                .x = @intCast(inner_x),
                .w = @intCast(inner_w),
                .kind = .flow,
            });
            const start_y = self.y;
            const start_b = self.block_count - 1;
            var child = self.doc.nodes[idx].first_child;
            var item: u8 = 1;
            while (child != parse.none) {
                if (self.doc.nodes[child].tag == .li) {
                    self.layoutLi(child, inner_x, inner_w, if (tag == .ol) item else 0);
                    item +%= 1;
                } else if (parse.isBlock(self.doc.nodes[child].tag)) {
                    self.layoutBlock(child, inner_x, inner_w);
                }
                child = self.doc.nodes[child].next_sibling;
            }
            self.blocks[start_b].h = @intCast(self.y - start_y);
            self.y += st.after;
            return;
        }

        const quote = tag == .blockquote;
        self.addBlock(.{
            .tag = tag,
            .y = @intCast(self.y),
            .x = @intCast(inner_x),
            .w = @intCast(inner_w),
            .kind = .flow,
            .quote_bar = quote,
            .first_line = self.line_count,
        });
        const start_y = self.y;
        const start_b = self.block_count - 1;
        const first_line = self.line_count;
        if (hasDirectInlines(self.doc, idx)) {
            self.wrapInlines(self.doc.nodes[idx].first_child, inner_x, inner_w, tag);
        }
        var child = self.doc.nodes[idx].first_child;
        while (child != parse.none) {
            if (parse.isBlock(self.doc.nodes[child].tag)) {
                self.layoutBlock(child, inner_x, inner_w);
            }
            child = self.doc.nodes[child].next_sibling;
        }
        self.blocks[start_b].line_count = self.line_count - first_line;
        self.blocks[start_b].h = @intCast(self.y - start_y);
        if (self.blocks[start_b].h == 0) {
            // empty heading/p still occupies a line
            self.y += lineHeight(tag);
            self.blocks[start_b].h = @intCast(lineHeight(tag));
        }
        self.y += st.after;
    }

    fn layoutLi(self: *Engine, idx: u16, x: u32, w: u32, decimal: u8) void {
        const st = styleOf(.li);
        self.y += st.before;
        self.addBlock(.{
            .tag = .li,
            .y = @intCast(self.y),
            .x = @intCast(x),
            .w = @intCast(w),
            .kind = .flow,
            .marker = if (decimal == 0) .disc else .decimal,
            .marker_index = decimal,
            .first_line = self.line_count,
        });
        const start_y = self.y;
        const start_b = self.block_count - 1;
        const first_line = self.line_count;
        const text_x = x + 12;
        const text_w = if (w > 12) w - 12 else w;
        if (hasDirectInlines(self.doc, idx)) {
            self.wrapInlines(self.doc.nodes[idx].first_child, text_x, text_w, .li);
        }
        var child = self.doc.nodes[idx].first_child;
        while (child != parse.none) {
            if (parse.isBlock(self.doc.nodes[child].tag)) {
                self.layoutBlock(child, x, w);
            }
            child = self.doc.nodes[child].next_sibling;
        }
        self.blocks[start_b].line_count = self.line_count - first_line;
        self.blocks[start_b].h = @intCast(self.y - start_y);
        if (self.blocks[start_b].h == 0) {
            self.y += lineHeight(.li);
            self.blocks[start_b].h = @intCast(lineHeight(.li));
        }
        self.y += st.after;
    }

    fn layoutPre(self: *Engine, idx: u16, x: u32, w: u32, st: Style) void {
        self.addBlock(.{
            .tag = .pre,
            .y = @intCast(self.y),
            .x = @intCast(x),
            .w = @intCast(w),
            .kind = .pre,
            .first_line = self.line_count,
        });
        const start_y = self.y;
        const start_b = self.block_count - 1;
        const first_line = self.line_count;
        const lh = st.size + st.leading;
        // Walk text/code descendants, split on LF, no wrap (S1 clips overflow).
        self.emitPreLines(self.doc.nodes[idx].first_child, x, w, lh, st.size);
        self.blocks[start_b].line_count = self.line_count - first_line;
        self.blocks[start_b].h = @intCast(self.y - start_y);
        if (self.blocks[start_b].h == 0) {
            self.y += lh;
            self.blocks[start_b].h = @intCast(lh);
        }
    }

    fn emitPreLines(self: *Engine, start: u16, x: u32, w: u32, lh: u32, size: u32) void {
        var idx = start;
        while (idx != parse.none) {
            const n = self.doc.nodes[idx];
            if (n.tag == .text) {
                const slice = self.doc.textOf(idx);
                var off: usize = 0;
                while (off <= slice.len) {
                    const nl = std.mem.indexOfScalarPos(u8, slice, off, '\n');
                    const end = nl orelse slice.len;
                    const line = slice[off..end];
                    self.addPreLine(line, n.text_off + @as(u16, @intCast(off)), x, w, lh, size);
                    if (nl) |p| {
                        off = p + 1;
                    } else break;
                }
            } else if (n.first_child != parse.none) {
                self.emitPreLines(n.first_child, x, w, lh, size);
            }
            idx = n.next_sibling;
        }
    }

    fn addPreLine(self: *Engine, line: []const u8, off: u16, x: u32, w: u32, lh: u32, size: u32) void {
        const line_idx = self.addLine(.{
            .y = @intCast(self.y),
            .h = @intCast(lh),
            .x = @intCast(x),
            .first_span = self.span_count,
            .span_count = 0,
        }) orelse return;
        var used: u32 = 0;
        var i: usize = 0;
        while (i < line.len) {
            const remain_w = if (w > used) w - used else 0;
            if (remain_w < 8) break; // clip
            const take = @min(line.len - i, remain_w / 8);
            if (take == 0) break;
            const piece = line[i .. i + take];
            const pw = self.measure(piece, true, size);
            _ = self.addSpan(.{
                .text_off = off + @as(u16, @intCast(i)),
                .text_len = @intCast(take),
                .x = @intCast(used),
                .w = @intCast(pw),
                .size = @intCast(size),
                .flags = .{ .mono = true },
            });
            self.lines[line_idx].span_count += 1;
            used += pw;
            i += take;
            if (pw == 0) break;
        }
        self.y += lh;
    }

    const InlineState = struct {
        size: u32 = 14,
        bold: bool = false,
        em: bool = false,
        link: bool = false,
        mono: bool = false,
        href_off: u16 = 0,
        href_len: u16 = 0,
    };

    fn wrapInlines(self: *Engine, start: u16, x: u32, w: u32, inherit: parse.Tag) void {
        const st = styleOf(inherit);
        var ist = InlineState{ .size = st.size, .mono = st.mono };
        if (inherit == .h1 or inherit == .h2 or inherit == .h3) ist.size = st.size;
        self.openLine(x, st.size + st.leading);
        self.walkInline(start, x, w, inherit, ist);
        self.closeLineIfOpen();
    }

    fn walkInline(self: *Engine, start: u16, x: u32, w: u32, stop_parent_blocks: parse.Tag, ist: InlineState) void {
        _ = stop_parent_blocks;
        var idx = start;
        while (idx != parse.none) {
            const n = self.doc.nodes[idx];
            if (parse.isBlock(n.tag) and n.tag != .br) break;
            if (n.tag == .br) {
                self.breakLine(x, lineHeight(.p));
                idx = n.next_sibling;
                continue;
            }
            var child_ist = ist;
            switch (n.tag) {
                .strong => child_ist.bold = true,
                .em => child_ist.em = true,
                .a => {
                    child_ist.link = true;
                    child_ist.href_off = n.href_off;
                    child_ist.href_len = n.href_len;
                },
                .code => {
                    child_ist.mono = true;
                    child_ist.size = 13;
                },
                else => {},
            }
            if (n.tag == .text) {
                self.emitWrapped(self.doc.textOf(idx), n.text_off, x, w, child_ist);
            } else if (n.first_child != parse.none) {
                self.walkInline(n.first_child, x, w, .p, child_ist);
            }
            idx = n.next_sibling;
        }
    }

    fn emitWrapped(self: *Engine, text: []const u8, off: u16, x: u32, w: u32, ist: InlineState) void {
        if (self.line_count == 0) self.openLine(x, ist.size + 4);
        var i: usize = 0;
        while (i < text.len) {
            const line = &self.lines[self.line_count - 1];
            var used: u32 = 0;
            var s: u16 = 0;
            while (s < line.span_count) : (s += 1) {
                used += self.spans[line.first_span + s].w;
            }
            const remain = if (w > used) w - used else 0;
            const rest = text[i..];
            const fit = self.fitPrefix(rest, remain, ist);
            if (fit.len == 0) {
                if (used == 0) {
                    // hard-break a single glyph so we always make progress
                    const one = rest[0..1];
                    const pw = self.measure(one, ist.mono, ist.size);
                    self.pushSpan(off + @as(u16, @intCast(i)), 1, used, pw, ist);
                    i += 1;
                    self.breakLine(x, ist.size + 4);
                    continue;
                }
                self.breakLine(x, ist.size + 4);
                continue;
            }
            const take = fit.len;
            const piece = rest[0..take];
            // drop a wrapping space at the start of a new line
            if (used == 0 and piece[0] == ' ') {
                i += 1;
                continue;
            }
            // if we broke at a space, keep it on this line (trailing, invisible)
            const pw = self.measure(piece, ist.mono, ist.size);
            self.pushSpan(off + @as(u16, @intCast(i)), @intCast(take), used, pw, ist);
            i += take;
            if (fit.broke) self.breakLine(x, ist.size + 4);
        }
    }

    const Fit = struct { len: usize, broke: bool };

    fn fitPrefix(self: *Engine, text: []const u8, max_w: u32, ist: InlineState) Fit {
        if (text.len == 0 or max_w == 0) return .{ .len = 0, .broke = max_w == 0 };
        var used: u32 = 0;
        var last_space: ?usize = null;
        var i: usize = 0;
        while (i < text.len) {
            const ch = text[i .. i + 1];
            const cw = self.measure(ch, ist.mono, ist.size);
            if (used + cw > max_w) {
                if (last_space) |sp| return .{ .len = sp + 1, .broke = true };
                if (i == 0) return .{ .len = 0, .broke = true };
                return .{ .len = i, .broke = true };
            }
            used += cw;
            if (text[i] == ' ') last_space = i;
            i += 1;
        }
        return .{ .len = text.len, .broke = false };
    }

    fn openLine(self: *Engine, x: u32, h: u32) void {
        _ = self.addLine(.{
            .y = @intCast(self.y),
            .h = @intCast(h),
            .x = @intCast(x),
            .first_span = self.span_count,
            .span_count = 0,
        });
    }

    fn closeLineIfOpen(self: *Engine) void {
        if (self.line_count == 0) return;
        const line = self.lines[self.line_count - 1];
        if (line.span_count == 0 and self.y == line.y) {
            // unused open line at the end — drop it
            self.line_count -= 1;
            return;
        }
        if (self.y == line.y) self.y += line.h;
    }

    fn breakLine(self: *Engine, x: u32, h: u32) void {
        if (self.line_count > 0) {
            const line = self.lines[self.line_count - 1];
            if (self.y == line.y) self.y += line.h;
        }
        self.openLine(x, h);
    }

    fn pushSpan(self: *Engine, off: u16, len: u16, x: u32, w: u32, ist: InlineState) void {
        if (self.line_count == 0) return;
        _ = self.addSpan(.{
            .text_off = off,
            .text_len = len,
            .x = @intCast(x),
            .w = @intCast(w),
            .size = @intCast(ist.size),
            .flags = .{
                .bold = ist.bold,
                .em = ist.em,
                .link = ist.link,
                .mono = ist.mono,
            },
            .href_off = ist.href_off,
            .href_len = ist.href_len,
        });
        self.lines[self.line_count - 1].span_count += 1;
    }

    fn addBlock(self: *Engine, b: Block) void {
        if (self.block_count >= self.blocks.len) {
            self.truncated = true;
            return;
        }
        self.blocks[self.block_count] = b;
        self.block_count += 1;
    }

    fn addLine(self: *Engine, l: Line) ?u16 {
        if (self.line_count >= self.lines.len) {
            self.truncated = true;
            return null;
        }
        const idx = self.line_count;
        self.lines[idx] = l;
        self.line_count += 1;
        return idx;
    }

    fn addSpan(self: *Engine, s: Span) void {
        if (self.span_count >= self.spans.len) {
            self.truncated = true;
            return;
        }
        self.spans[self.span_count] = s;
        self.span_count += 1;
    }
};

fn hasDirectInlines(doc: parse.Document, idx: u16) bool {
    var child = doc.nodes[idx].first_child;
    while (child != parse.none) {
        const tag = doc.nodes[child].tag;
        if (!parse.isBlock(tag) or tag == .br) {
            if (tag == .text and doc.nodes[child].text_len == 0) {
                child = doc.nodes[child].next_sibling;
                continue;
            }
            return true;
        }
        child = doc.nodes[child].next_sibling;
    }
    return false;
}

fn runHasInk(doc: parse.Document, head: u16) bool {
    var idx = head;
    while (idx != parse.none) {
        const n = doc.nodes[idx];
        if (parse.isBlock(n.tag) and n.tag != .br) break;
        if (n.tag == .text and n.text_len > 0) return true;
        if (n.tag == .br) return true;
        if (n.first_child != parse.none and runHasInk(doc, n.first_child)) return true;
        idx = n.next_sibling;
    }
    return false;
}

test "html layout: headings stack and wrap at last space" {
    var nodes: [parse.max_nodes]parse.Node = undefined;
    var text: [parse.max_text]u8 = undefined;
    const doc = parse.parse("<h1>Title Word</h1><p>hello world this wraps</p>", nodes[0..], text[0..]);
    var blocks: [max_blocks]Block = undefined;
    var lines: [max_lines]Line = undefined;
    var spans: [max_spans]Span = undefined;
    // 80 px content + margins → 60 px inner? width 80 → content 60; 8px/char = 7 chars.
    const lay = layout(doc, 80, blocks[0..], lines[0..], spans[0..], stubMeasure);
    try std.testing.expect(lay.block_count >= 2);
    try std.testing.expect(lay.blocks[0].tag == .h1);
    try std.testing.expect(lay.blocks[0].y < lay.blocks[1].y);
    try std.testing.expect(lay.line_count >= 2);
    // "hello world this wraps" at 8px/char in ~60px (7 chars) must wrap.
    var p_lines: u16 = 0;
    var i: u16 = 0;
    while (i < lay.block_count) : (i += 1) {
        if (lay.blocks[i].tag == .p) p_lines = lay.blocks[i].line_count;
    }
    try std.testing.expect(p_lines >= 2);
}

test "html layout: pre does not wrap; blockquote has a quote bar; hr is 1px" {
    var nodes: [parse.max_nodes]parse.Node = undefined;
    var text: [parse.max_text]u8 = undefined;
    const src = "<blockquote><p>quoted</p></blockquote><pre>const x = 1; // fence</pre><hr /><p>end</p>";
    const doc = parse.parse(src, nodes[0..], text[0..]);
    var blocks: [max_blocks]Block = undefined;
    var lines: [max_lines]Line = undefined;
    var spans: [max_spans]Span = undefined;
    const lay = layout(doc, 200, blocks[0..], lines[0..], spans[0..], stubMeasure);
    var saw_quote = false;
    var saw_hr = false;
    var pre_lines: u16 = 0;
    var i: u16 = 0;
    while (i < lay.block_count) : (i += 1) {
        if (lay.blocks[i].quote_bar) saw_quote = true;
        if (lay.blocks[i].kind == .hr) {
            saw_hr = true;
            try std.testing.expectEqual(@as(u16, 1), lay.blocks[i].h);
        }
        if (lay.blocks[i].tag == .pre) pre_lines = lay.blocks[i].line_count;
    }
    try std.testing.expect(saw_quote);
    try std.testing.expect(saw_hr);
    try std.testing.expectEqual(@as(u16, 1), pre_lines);
}

test "html layout: nested list indent and ol markers" {
    var nodes: [parse.max_nodes]parse.Node = undefined;
    var text: [parse.max_text]u8 = undefined;
    const src = "<ul><li>one</li><li>two<ul><li>nested</li></ul></li></ul><ol><li>first</li><li>second</li></ol>";
    const doc = parse.parse(src, nodes[0..], text[0..]);
    var blocks: [max_blocks]Block = undefined;
    var lines: [max_lines]Line = undefined;
    var spans: [max_spans]Span = undefined;
    const lay = layout(doc, 240, blocks[0..], lines[0..], spans[0..], stubMeasure);
    var discs: u8 = 0;
    var decimals: u8 = 0;
    var nested_x: u16 = 0;
    var top_x: u16 = 0;
    var i: u16 = 0;
    while (i < lay.block_count) : (i += 1) {
        if (lay.blocks[i].marker == .disc) {
            discs += 1;
            if (top_x == 0) top_x = lay.blocks[i].x else nested_x = lay.blocks[i].x;
        }
        if (lay.blocks[i].marker == .decimal) decimals += 1;
    }
    try std.testing.expect(discs >= 3);
    try std.testing.expectEqual(@as(u8, 2), decimals);
    try std.testing.expect(nested_x > top_x);
}

test "html layout: oliver fixture lays out without truncating" {
    const src = parse.oliver_fixture;
    var nodes: [parse.max_nodes]parse.Node = undefined;
    var text: [parse.max_text]u8 = undefined;
    const doc = parse.parse(src, nodes[0..], text[0..]);
    var blocks: [max_blocks]Block = undefined;
    var lines: [max_lines]Line = undefined;
    var spans: [max_spans]Span = undefined;
    const lay = layout(doc, 492, blocks[0..], lines[0..], spans[0..], stubMeasure);
    try std.testing.expect(!lay.truncated);
    try std.testing.expect(lay.block_count >= 8);
    try std.testing.expect(lay.line_count >= 8);
    try std.testing.expect(lay.content_h > page_margin * 2);
}
