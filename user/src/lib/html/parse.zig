//! VirelaiOS HTML parser (M-web S2, ADR 0028 D3).
//!
//! Bytes → a flat node array with parent/child/sibling indices. No pointers,
//! no allocator, no framebuffer. Caller supplies the node and text arenas.
//!
//! Whitespace (pinned in docs/html-renderer-scoping.md):
//!   - normal flow: ASCII whitespace collapses to a single space; leading
//!     and trailing space at a block boundary is dropped
//!   - `pre` and `code`: whitespace is preserved; CR/CRLF become LF
//!
//! Unknown elements stay in the tree as `.unknown` so layout can lift their
//! text in document order (D5). Tables, definition lists, and headings
//! through h6 are first-class as of S2.

const std = @import("std");

pub const max_nodes: usize = 512;
pub const max_text: usize = 32 * 1024;
pub const none: u16 = 0xffff;
pub const max_depth: usize = 16;

pub const Tag = enum(u8) {
    document,
    h1,
    h2,
    h3,
    h4,
    h5,
    h6,
    p,
    br,
    hr,
    ul,
    ol,
    li,
    dl,
    dt,
    dd,
    blockquote,
    pre,
    code,
    strong,
    em,
    a,
    table,
    thead,
    tbody,
    tr,
    th,
    td,
    unknown,
    text,
};

pub const Node = struct {
    tag: Tag = .unknown,
    parent: u16 = none,
    first_child: u16 = none,
    last_child: u16 = none,
    next_sibling: u16 = none,
    text_off: u16 = 0,
    text_len: u16 = 0,
    href_off: u16 = 0,
    href_len: u16 = 0,
};

pub const Document = struct {
    nodes: []Node,
    node_count: u16,
    text: []u8,
    text_len: u16,
    truncated: bool,

    pub fn node(self: Document, idx: u16) *const Node {
        return &self.nodes[idx];
    }

    pub fn textOf(self: Document, idx: u16) []const u8 {
        const n = self.nodes[idx];
        return self.text[n.text_off .. n.text_off + n.text_len];
    }

    pub fn hrefOf(self: Document, idx: u16) []const u8 {
        const n = self.nodes[idx];
        if (n.href_len == 0) return &.{};
        return self.text[n.href_off .. n.href_off + n.href_len];
    }
};

pub fn isHeading(tag: Tag) bool {
    return switch (tag) {
        .h1, .h2, .h3, .h4, .h5, .h6 => true,
        else => false,
    };
}

pub fn isBlock(tag: Tag) bool {
    return switch (tag) {
        .document,
        .h1,
        .h2,
        .h3,
        .h4,
        .h5,
        .h6,
        .p,
        .hr,
        .ul,
        .ol,
        .li,
        .dl,
        .dt,
        .dd,
        .blockquote,
        .pre,
        .table,
        .thead,
        .tbody,
        .tr,
        .th,
        .td,
        => true,
        else => false,
    };
}

pub fn isVoid(tag: Tag) bool {
    return tag == .br or tag == .hr;
}

pub fn parse(src: []const u8, nodes: []Node, text: []u8) Document {
    var p = Parser{
        .src = src,
        .nodes = nodes,
        .text = text,
    };
    const root = p.allocNode() orelse {
        return p.finish();
    };
    p.nodes[root].tag = .document;
    p.push(root);
    p.run();
    return p.finish();
}

const Parser = struct {
    src: []const u8,
    i: usize = 0,
    nodes: []Node,
    text: []u8,
    node_count: u16 = 0,
    text_len: u16 = 0,
    truncated: bool = false,
    stack: [max_depth]u16 = [_]u16{none} ** max_depth,
    stack_len: u8 = 0,
    skip_leading_ws: bool = true,
    last_was_space: bool = false,
    pre_depth: u8 = 0,
    code_depth: u8 = 0,
    current_text: u16 = none,

    fn preserveWs(self: *const Parser) bool {
        return self.pre_depth > 0 or self.code_depth > 0;
    }

    fn finish(self: *Parser) Document {
        return .{
            .nodes = self.nodes,
            .node_count = self.node_count,
            .text = self.text,
            .text_len = self.text_len,
            .truncated = self.truncated,
        };
    }

    fn run(self: *Parser) void {
        while (self.i < self.src.len and !self.truncated) {
            if (self.src[self.i] == '<') {
                self.parseTag();
            } else {
                self.parseText();
            }
        }
    }

    fn allocNode(self: *Parser) ?u16 {
        if (self.node_count >= self.nodes.len) {
            self.truncated = true;
            return null;
        }
        const idx: u16 = self.node_count;
        self.nodes[idx] = .{};
        self.node_count += 1;
        return idx;
    }

    fn pushTextByte(self: *Parser, c: u8) void {
        if (self.text_len >= self.text.len) {
            self.truncated = true;
            return;
        }
        if (self.current_text == none) {
            const idx = self.allocNode() orelse return;
            self.nodes[idx].tag = .text;
            self.nodes[idx].text_off = self.text_len;
            self.appendChild(self.top(), idx);
            self.current_text = idx;
        }
        self.text[self.text_len] = c;
        self.text_len += 1;
        self.nodes[self.current_text].text_len += 1;
    }

    fn pushRawSlice(self: *Parser, bytes: []const u8) u16 {
        const off = self.text_len;
        for (bytes) |c| {
            if (self.text_len >= self.text.len) {
                self.truncated = true;
                break;
            }
            self.text[self.text_len] = c;
            self.text_len += 1;
        }
        return off;
    }

    fn appendChild(self: *Parser, parent: u16, child: u16) void {
        if (parent == none) return;
        self.nodes[child].parent = parent;
        if (self.nodes[parent].first_child == none) {
            self.nodes[parent].first_child = child;
        } else {
            self.nodes[self.nodes[parent].last_child].next_sibling = child;
        }
        self.nodes[parent].last_child = child;
    }

    fn top(self: *const Parser) u16 {
        if (self.stack_len == 0) return 0;
        return self.stack[self.stack_len - 1];
    }

    fn push(self: *Parser, idx: u16) void {
        if (self.stack_len >= max_depth) {
            self.truncated = true;
            return;
        }
        self.stack[self.stack_len] = idx;
        self.stack_len += 1;
    }

    fn pop(self: *Parser) void {
        if (self.stack_len == 0) return;
        const idx = self.stack[self.stack_len - 1];
        const tag = self.nodes[idx].tag;
        self.stack_len -= 1;
        if (tag == .pre and self.pre_depth > 0) self.pre_depth -= 1;
        if (tag == .code and self.code_depth > 0) self.code_depth -= 1;
        self.endText();
        if (isBlock(tag)) {
            self.trimTrailingSpace();
            self.skip_leading_ws = true;
            self.last_was_space = false;
        }
    }

    fn endText(self: *Parser) void {
        self.current_text = none;
    }

    fn trimTrailingSpace(self: *Parser) void {
        if (self.node_count == 0) return;
        var idx = self.node_count - 1;
        while (true) {
            const n = &self.nodes[idx];
            if (n.tag == .text and n.text_len > 0) {
                const last = self.text[n.text_off + n.text_len - 1];
                if (last == ' ' and self.pre_depth == 0 and self.code_depth == 0) {
                    n.text_len -= 1;
                    if (self.text_len == n.text_off + n.text_len + 1) {
                        self.text_len -= 1;
                    }
                }
                return;
            }
            if (idx == 0) return;
            idx -= 1;
        }
    }

    fn parseTag(self: *Parser) void {
        const start = self.i;
        self.i += 1;
        if (self.i >= self.src.len) {
            self.emitByte('<');
            return;
        }
        if (self.startsWith("!--")) {
            self.i = start + 4;
            self.skipUntil("-->");
            return;
        }
        if (self.src[self.i] == '!' or self.src[self.i] == '?') {
            self.skipUntil(">");
            return;
        }
        const is_end = self.src[self.i] == '/';
        if (is_end) self.i += 1;
        const name_start = self.i;
        while (self.i < self.src.len and isNameChar(self.src[self.i])) : (self.i += 1) {}
        const name = self.src[name_start..self.i];
        // A bare `<` (or `<<`) is text, not a tag — otherwise we scan to EOF
        // looking for `>` and hang the live gate (boot 03).
        if (name.len == 0) {
            self.i = start + 1;
            self.emitByte('<');
            return;
        }
        var href: []const u8 = &.{};
        var self_close = false;
        while (self.i < self.src.len and self.src[self.i] != '>') {
            const c = self.src[self.i];
            if (c == '/') {
                self_close = true;
                self.i += 1;
                continue;
            }
            if (isWs(c)) {
                self.i += 1;
                continue;
            }
            const attr = self.parseAttr();
            if (eqlCi(attr.name, "href")) href = attr.value;
        }
        if (self.i < self.src.len and self.src[self.i] == '>') self.i += 1;

        const tag = tagFromName(name);
        if (is_end) {
            self.closeTag(tag, name);
            return;
        }
        self.openTag(tag, href, self_close or isVoid(tag));
    }

    const Attr = struct { name: []const u8, value: []const u8 };

    fn parseAttr(self: *Parser) Attr {
        const name_start = self.i;
        while (self.i < self.src.len and isNameChar(self.src[self.i])) : (self.i += 1) {}
        const name = self.src[name_start..self.i];
        self.skipWs();
        if (self.i >= self.src.len or self.src[self.i] != '=') {
            return .{ .name = name, .value = &.{} };
        }
        self.i += 1;
        self.skipWs();
        if (self.i >= self.src.len) return .{ .name = name, .value = &.{} };
        const quote = self.src[self.i];
        if (quote == '"' or quote == '\'') {
            self.i += 1;
            const vstart = self.i;
            while (self.i < self.src.len and self.src[self.i] != quote) : (self.i += 1) {}
            const value = self.src[vstart..self.i];
            if (self.i < self.src.len) self.i += 1;
            return .{ .name = name, .value = value };
        }
        const vstart = self.i;
        while (self.i < self.src.len and !isWs(self.src[self.i]) and self.src[self.i] != '>') : (self.i += 1) {}
        return .{ .name = name, .value = self.src[vstart..self.i] };
    }

    fn openTag(self: *Parser, tag: Tag, href: []const u8, void_el: bool) void {
        if (tag == .p or isHeading(tag)) {
            self.closeOpen(.p);
        }
        if (tag == .li) self.closeOpen(.li);
        if (tag == .dt or tag == .dd) {
            self.closeOpen(.dd);
            self.closeOpen(.dt);
        }
        if (tag == .td or tag == .th) {
            self.closeOpen(.td);
            self.closeOpen(.th);
        }
        if (tag == .tr) self.closeOpen(.tr);
        if (isBlock(tag)) {
            self.endText();
            self.trimTrailingSpace();
            self.skip_leading_ws = true;
            self.last_was_space = false;
        } else {
            self.endText();
        }
        const idx = self.allocNode() orelse return;
        self.nodes[idx].tag = tag;
        if (href.len > 0) {
            self.nodes[idx].href_off = self.pushRawSlice(href);
            self.nodes[idx].href_len = @intCast(self.text_len - self.nodes[idx].href_off);
        }
        self.appendChild(self.top(), idx);
        if (void_el) return;
        self.push(idx);
        if (tag == .pre) self.pre_depth += 1;
        if (tag == .code) self.code_depth += 1;
    }

    fn closeTag(self: *Parser, tag: Tag, name: []const u8) void {
        _ = name;
        var n = self.stack_len;
        while (n > 1) {
            n -= 1;
            if (self.nodes[self.stack[n]].tag == tag) {
                while (self.stack_len > n) self.pop();
                return;
            }
        }
        // unmatched end tag: ignore
    }

    fn closeOpen(self: *Parser, tag: Tag) void {
        var n = self.stack_len;
        while (n > 1) {
            n -= 1;
            const t = self.nodes[self.stack[n]].tag;
            if (t == tag) {
                while (self.stack_len > n) self.pop();
                return;
            }
            if (isBlock(t) and t != .li and t != .p) return;
        }
    }

    fn parseText(self: *Parser) void {
        while (self.i < self.src.len and self.src[self.i] != '<' and !self.truncated) {
            if (self.src[self.i] == '&') {
                const decoded = self.parseEntity();
                self.emitByte(decoded);
                continue;
            }
            const c = self.src[self.i];
            self.i += 1;
            if (c == '\r') {
                if (self.i < self.src.len and self.src[self.i] == '\n') self.i += 1;
                self.emitByte('\n');
                continue;
            }
            self.emitByte(c);
        }
    }

    fn emitByte(self: *Parser, c: u8) void {
        if (self.preserveWs()) {
            self.skip_leading_ws = false;
            self.last_was_space = false;
            self.pushTextByte(c);
            return;
        }
        if (isWs(c)) {
            if (self.skip_leading_ws) return;
            if (self.last_was_space) return;
            self.pushTextByte(' ');
            self.last_was_space = true;
            return;
        }
        self.skip_leading_ws = false;
        self.last_was_space = false;
        self.pushTextByte(c);
    }

    fn parseEntity(self: *Parser) u8 {
        const amp_at = self.i;
        self.i += 1;
        if (self.i >= self.src.len) return '&';
        if (self.src[self.i] == '#') {
            self.i += 1;
            var hex = false;
            if (self.i < self.src.len and (self.src[self.i] == 'x' or self.src[self.i] == 'X')) {
                hex = true;
                self.i += 1;
            }
            var cp: u32 = 0;
            var digits: usize = 0;
            while (self.i < self.src.len) : (self.i += 1) {
                const c = self.src[self.i];
                if (hex) {
                    const v = hexVal(c) orelse break;
                    cp = cp *% 16 + v;
                } else {
                    if (c < '0' or c > '9') break;
                    cp = cp *% 10 + (c - '0');
                }
                digits += 1;
                if (digits > 6) break;
            }
            if (digits == 0) {
                self.i = amp_at + 1;
                return '&';
            }
            if (self.i < self.src.len and self.src[self.i] == ';') self.i += 1;
            if (cp == 0 or cp > 255) return '?';
            return @intCast(cp);
        }
        const name_start = self.i;
        while (self.i < self.src.len and std.ascii.isAlphabetic(self.src[self.i])) : (self.i += 1) {}
        const name = self.src[name_start..self.i];
        if (self.i < self.src.len and self.src[self.i] == ';') self.i += 1;
        if (eqlCi(name, "amp")) return '&';
        if (eqlCi(name, "lt")) return '<';
        if (eqlCi(name, "gt")) return '>';
        if (eqlCi(name, "quot")) return '"';
        if (eqlCi(name, "apos")) return '\'';
        if (eqlCi(name, "nbsp")) return 0xa0;
        self.i = amp_at + 1;
        return '&';
    }

    fn startsWith(self: *const Parser, lit: []const u8) bool {
        if (self.i + lit.len > self.src.len) return false;
        return std.mem.eql(u8, self.src[self.i .. self.i + lit.len], lit);
    }

    fn skipUntil(self: *Parser, lit: []const u8) void {
        while (self.i + lit.len <= self.src.len) {
            if (std.mem.eql(u8, self.src[self.i .. self.i + lit.len], lit)) {
                self.i += lit.len;
                return;
            }
            self.i += 1;
        }
        self.i = self.src.len;
    }

    fn skipWs(self: *Parser) void {
        while (self.i < self.src.len and isWs(self.src[self.i])) : (self.i += 1) {}
    }
};

/// Pinned oliver output (`tests/oliver-spike/expect.html`). Kept in-tree so
/// host tests do not depend on the runner cwd / package embed path.
pub const oliver_fixture =
    \\<h1>VirelaiOS wasm channel</h1>
    \\<p>A <em>real</em> Zig tool -- <strong>oliver</strong> -- rendering Markdown to HTML in-guest.</p>
    \\<h2>Inline</h2>
    \\<p>Text with <code>code</code>, a <a href="https://example.com">link</a>, an autolink <a href="https://virelai.os">https://virelai.os</a>,
    \\entities &amp; and <em>raw html</em>, plus a hard<br />
    \\break.</p>
    \\<h2>Blocks</h2>
    \\<ul>
    \\<li>one</li>
    \\<li>two
    \\<ul>
    \\<li>nested</li>
    \\</ul>
    \\</li>
    \\</ul>
    \\<ol>
    \\<li>first</li>
    \\<li>second</li>
    \\</ol>
    \\<blockquote>
    \\<p>quoted <code>text</code></p>
    \\</blockquote>
    \\<pre><code class="language-zig">const x = 1; // fence
    \\</code></pre>
    \\<table>
    \\<thead>
    \\<tr>
    \\<th>a</th>
    \\<th>b</th>
    \\</tr>
    \\</thead>
    \\<tbody>
    \\<tr>
    \\<td>1</td>
    \\<td>2</td>
    \\</tr>
    \\</tbody>
    \\</table>
    \\<hr />
    \\<p>Trailing paragraph.</p>
    \\
;

fn isWs(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

fn isNameChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == ':';
}

fn hexVal(c: u8) ?u32 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

fn eqlCi(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    }
    return true;
}

fn tagFromName(name: []const u8) Tag {
    if (eqlCi(name, "h1")) return .h1;
    if (eqlCi(name, "h2")) return .h2;
    if (eqlCi(name, "h3")) return .h3;
    if (eqlCi(name, "h4")) return .h4;
    if (eqlCi(name, "h5")) return .h5;
    if (eqlCi(name, "h6")) return .h6;
    if (eqlCi(name, "p")) return .p;
    if (eqlCi(name, "br")) return .br;
    if (eqlCi(name, "hr")) return .hr;
    if (eqlCi(name, "ul")) return .ul;
    if (eqlCi(name, "ol")) return .ol;
    if (eqlCi(name, "li")) return .li;
    if (eqlCi(name, "dl")) return .dl;
    if (eqlCi(name, "dt")) return .dt;
    if (eqlCi(name, "dd")) return .dd;
    if (eqlCi(name, "blockquote")) return .blockquote;
    if (eqlCi(name, "pre")) return .pre;
    if (eqlCi(name, "code")) return .code;
    if (eqlCi(name, "strong")) return .strong;
    if (eqlCi(name, "em")) return .em;
    if (eqlCi(name, "a")) return .a;
    if (eqlCi(name, "table")) return .table;
    if (eqlCi(name, "thead")) return .thead;
    if (eqlCi(name, "tbody")) return .tbody;
    if (eqlCi(name, "tr")) return .tr;
    if (eqlCi(name, "th")) return .th;
    if (eqlCi(name, "td")) return .td;
    return .unknown;
}

pub fn collectText(doc: Document, buf: []u8) []const u8 {
    var w: usize = 0;
    const idx = doc.nodes[0].first_child;
    w = collectWalk(doc, idx, buf, w);
    return buf[0..w];
}

fn collectWalk(doc: Document, start: u16, buf: []u8, w0: usize) usize {
    var w = w0;
    var idx = start;
    while (idx != none) {
        const n = doc.nodes[idx];
        if (n.tag == .text) {
            const slice = doc.textOf(idx);
            const take = @min(slice.len, buf.len - w);
            @memcpy(buf[w .. w + take], slice[0..take]);
            w += take;
        } else if (n.tag == .br) {
            if (w < buf.len) {
                buf[w] = '\n';
                w += 1;
            }
        }
        if (n.first_child != none) {
            w = collectWalk(doc, n.first_child, buf, w);
        }
        idx = n.next_sibling;
    }
    return w;
}

test "html parse: oliver fixture yields h1/h2 and table text in document order" {
    const src = oliver_fixture;
    var nodes: [max_nodes]Node = undefined;
    var text: [max_text]u8 = undefined;
    const doc = parse(src, nodes[0..], text[0..]);
    try std.testing.expect(!doc.truncated);
    try std.testing.expect(doc.node_count > 8);

    var saw_h1 = false;
    var saw_blockquote = false;
    var saw_pre = false;
    var saw_a = false;
    var i: u16 = 0;
    while (i < doc.node_count) : (i += 1) {
        switch (doc.nodes[i].tag) {
            .h1 => {
                saw_h1 = true;
                try std.testing.expectEqualStrings("VirelaiOS wasm channel", firstText(doc, i));
            },
            .blockquote => saw_blockquote = true,
            .pre => saw_pre = true,
            .a => {
                saw_a = true;
                if (std.mem.eql(u8, doc.hrefOf(i), "https://example.com")) {
                    try std.testing.expectEqualStrings("link", firstText(doc, i));
                }
            },
            else => {},
        }
    }
    try std.testing.expect(saw_h1 and saw_blockquote and saw_pre and saw_a);

    var buf: [512]u8 = undefined;
    const plain = collectText(doc, &buf);
    try std.testing.expect(std.mem.indexOf(u8, plain, "oliver") != null);
    try std.testing.expect(std.mem.indexOf(u8, plain, "nested") != null);
    try std.testing.expect(findTag(doc, .table) != none);
    try std.testing.expect(findTag(doc, .th) != none);
    try std.testing.expect(findTag(doc, .td) != none);
    try std.testing.expect(std.mem.indexOf(u8, plain, "a") != null);
    try std.testing.expect(std.mem.indexOf(u8, plain, "1") != null);
    try std.testing.expect(std.mem.indexOf(u8, plain, "Trailing paragraph.") != null);
}

test "html parse: named and numeric entities" {
    var nodes: [max_nodes]Node = undefined;
    var text: [max_text]u8 = undefined;
    const doc = parse("<p>A &amp; B &lt; C &#65; &#x42; &#8212; end</p>", nodes[0..], text[0..]);
    var buf: [64]u8 = undefined;
    const plain = collectText(doc, &buf);
    try std.testing.expectEqualStrings("A & B < C A B ? end", plain);
}

test "html parse: whitespace collapses in flow and is preserved in pre" {
    var nodes: [max_nodes]Node = undefined;
    var text: [max_text]u8 = undefined;
    const doc = parse("<p>  hello   \n\t world  </p><pre>  a\n  b</pre>", nodes[0..], text[0..]);
    try std.testing.expectEqualStrings("hello world", firstText(doc, findTag(doc, .p)));
    try std.testing.expectEqualStrings("  a\n  b", firstText(doc, findTag(doc, .pre)));
}

test "html parse: nested lists and unknown tags keep text" {
    var nodes: [max_nodes]Node = undefined;
    var text: [max_text]u8 = undefined;
    const src =
        \\<ul><li>one</li><li>two<ul><li>nested</li></ul></li></ul>
        \\<table><tr><td>cell-a</td><td>cell-b</td></tr></table>
    ;
    const doc = parse(src, nodes[0..], text[0..]);
    try std.testing.expect(findTag(doc, .ul) != none);
    var buf: [128]u8 = undefined;
    const plain = collectText(doc, &buf);
    try std.testing.expect(std.mem.indexOf(u8, plain, "one") != null);
    try std.testing.expect(std.mem.indexOf(u8, plain, "nested") != null);
    try std.testing.expect(std.mem.indexOf(u8, plain, "cell-a") != null);
    try std.testing.expect(std.mem.indexOf(u8, plain, "cell-b") != null);
}

test "html parse: stray angle brackets are text, not an unbounded tag scan" {
    var nodes: [max_nodes]Node = undefined;
    var text: [max_text]u8 = undefined;
    const doc = parse("<p>ok <<<< <em>still", nodes[0..], text[0..]);
    try std.testing.expect(!doc.truncated);
    var buf: [64]u8 = undefined;
    const plain = collectText(doc, &buf);
    try std.testing.expect(std.mem.indexOf(u8, plain, "<<<<") != null);
    try std.testing.expect(std.mem.indexOf(u8, plain, "still") != null);
}

test "html parse: table/dl/h4–h6 tags" {
    var nodes: [max_nodes]Node = undefined;
    var text: [max_text]u8 = undefined;
    const src =
        \\<h4>Four</h4><h5>Five</h5><h6>Six</h6>
        \\<dl><dt>term</dt><dd>defn</dd></dl>
        \\<table><tr><th>H</th><td>C</td></tr></table>
    ;
    const doc = parse(src, nodes[0..], text[0..]);
    try std.testing.expect(findTag(doc, .h4) != none);
    try std.testing.expect(findTag(doc, .h5) != none);
    try std.testing.expect(findTag(doc, .h6) != none);
    try std.testing.expect(findTag(doc, .dl) != none);
    try std.testing.expectEqualStrings("term", firstText(doc, findTag(doc, .dt)));
    try std.testing.expectEqualStrings("defn", firstText(doc, findTag(doc, .dd)));
    try std.testing.expect(findTag(doc, .table) != none);
    try std.testing.expect(findTag(doc, .th) != none);
    try std.testing.expect(findTag(doc, .td) != none);
}

test "html parse: overflow sets truncated and never panics" {
    var nodes: [4]Node = undefined;
    var text: [8]u8 = undefined;
    const doc = parse("<p>hello world this is long</p><p>more</p>", nodes[0..], text[0..]);
    try std.testing.expect(doc.truncated);
    try std.testing.expect(doc.node_count <= 4);
}

fn findTag(doc: Document, tag: Tag) u16 {
    var i: u16 = 0;
    while (i < doc.node_count) : (i += 1) {
        if (doc.nodes[i].tag == tag) return i;
    }
    return none;
}

fn firstText(doc: Document, idx: u16) []const u8 {
    if (idx == none) return &.{};
    if (doc.nodes[idx].tag == .text) return doc.textOf(idx);
    var child = doc.nodes[idx].first_child;
    while (child != none) {
        if (doc.nodes[child].tag == .text) return doc.textOf(child);
        const nested = firstText(doc, child);
        if (nested.len > 0) return nested;
        child = doc.nodes[child].next_sibling;
    }
    return &.{};
}
