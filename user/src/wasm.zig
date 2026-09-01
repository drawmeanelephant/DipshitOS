//! The in-guest WASM core interpreter (M35 W1b, issue #762).
//!
//! Parses + validates + executes a bounded wasm-core integer subset:
//! i32/i64, block/loop/if/br/br_if/br_table/return/call/call_indirect,
//! one linear memory (2 MiB / 32 pages max — trap on `memory.grow`
//! beyond, NO unbounded mmap), one function table. Traps are named with
//! module + byte offset. Floats, threads, atomics, SIMD, bulk-memory are
//! OUT of subset (W4 / never).
//!
//! Import dispatch to ADR 0007 syscalls is W3 (`docs/wasm-import-
//! contract.md`); imported functions parse + validate, but calling one
//! traps `imported_unwired`. Imported tables/memories/globals are
//! rejected at validation (W3).
//!
//! Bounded like zc: one source file, fixed buffers, zero heap. Machine
//! state is a file-scope `Machine` (segmented DSK3 writable .data/.bss)
//! so the EL0 stack never carries it.

const std = @import("std");

// ---------------------------------------------------------------------------
// Bounds (the zc discipline: fixed arrays, no heap)
// ---------------------------------------------------------------------------
pub const max_types = 64; // func type section entries
pub const max_funcs = 64; // imported + defined functions
pub const max_params = 16;
pub const max_results = 2;
pub const max_globals = 64;
pub const max_imports = 16;
pub const max_exports = 64;
pub const max_table = 256; // the single funcref table
pub const max_mem_pages = 32; // hard cap = 2 MiB (wasm-import-contract.md)
pub const max_locals = 64; // params + declared locals per function
pub const max_stack = 1024; // operand stack depth
pub const max_ctl = 64; // control stack depth
pub const max_frames = 32; // call depth
pub const max_datas = 64;
pub const max_elems = 64;

const page_size: usize = 64 * 1024;

// ---------------------------------------------------------------------------
// Value model
// ---------------------------------------------------------------------------
pub const ValType = enum(u8) {
    i32 = 0x7F,
    i64 = 0x7E,
    f32 = 0x7D, // parsed; rejected at validation (W4)
    f64 = 0x7C, // parsed; rejected at validation (W4)

    pub fn fromByte(b: u8) ParseError!ValType {
        return switch (b) {
            0x7F => .i32,
            0x7E => .i64,
            0x7D => .f32,
            0x7C => .f64,
            else => error.UnknownValueType,
        };
    }
};

/// Machine value. Only i32/i64 lanes are produced; the opcode selects
/// which lane to read.
pub const Value = extern union {
    i32: i32,
    i64: i64,
};

pub const FuncType = struct {
    params: [max_params]ValType = undefined,
    results: [max_results]ValType = undefined,
    param_count: u8 = 0,
    result_count: u8 = 0,

    fn eql(a: FuncType, b: FuncType) bool {
        if (a.param_count != b.param_count or a.result_count != b.result_count) return false;
        for (0..a.param_count) |i| if (a.params[i] != b.params[i]) return false;
        for (0..a.result_count) |i| if (a.results[i] != b.results[i]) return false;
        return true;
    }
};

pub const ImportKind = enum(u8) { func = 0, table = 1, memory = 2, global = 3 };
pub const ExportKind = enum(u8) { func = 0, table = 1, memory = 2, global = 3 };

pub const Import = struct {
    module: []const u8,
    name: []const u8,
    kind: ImportKind,
    type_index: u32 = 0, // func only
};

pub const Global = struct {
    val_type: ValType,
    mutable: bool,
    init: Value, // i32.const / i64.const (subset init exprs)
};

pub const Export = struct {
    name: []const u8,
    kind: ExportKind,
    index: u32,
};

/// Active element segment (flag 0x00 form only; table 0).
pub const Element = struct {
    offset: u32,
    funcs: [max_table]u32 = undefined,
    count: u32 = 0,
    abs_off: usize = 0,
};

/// Active data segment (flag 0x00 form only; memory 0).
pub const Data = struct {
    offset: u32,
    bytes: []const u8 = &.{},
    abs_off: usize = 0,
};

pub const Func = struct {
    type_index: u32,
    body: []const u8 = &.{}, // code bytes after the locals declaration
    local_types: [max_locals]ValType = undefined,
    local_count: u8 = 0,
    abs_off: usize = 0, // module byte offset of the body's first instruction
};

pub const Module = struct {
    types: [max_types]FuncType = undefined,
    type_count: u16 = 0,
    funcs: [max_funcs]Func = undefined,
    func_count: u16 = 0,
    imported_funcs: u16 = 0, // front of funcs[] are imports
    globals: [max_globals]Global = undefined,
    global_count: u16 = 0,
    imports: [max_imports]Import = undefined,
    import_count: u16 = 0,
    exports: [max_exports]Export = undefined,
    export_count: u16 = 0,
    tables: [1]struct { min: u32, max: ?u32 } = undefined,
    table_count: u8 = 0,
    has_memory: bool = false,
    mem_min_pages: u32 = 0,
    mem_max_pages: ?u32 = null,
    start: ?u32 = null,
    elements: [max_elems]Element = undefined,
    element_count: u16 = 0,
    datas: [max_datas]Data = undefined,
    data_count: u16 = 0,
};

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------
pub const ParseError = error{
    BadMagic,
    BadVersion,
    Truncated,
    MalformedLeb,
    UnknownSection,
    DuplicateSection,
    SectionOutOfOrder,
    UnknownValueType,
    UnknownImportKind,
    UnknownExportKind,
    BadElementKind,
    TooManyEntries,
    TooManyParams,
    TooManyResults,
    TooManyLocals,
    CodeCountMismatch,
    TrailingBytes, // non-empty bytes after a section payload
};

pub const ValidationError = ParseError || error{
    FloatOutOfSubset, // f32/f64 anywhere (W4)
    UnknownType,
    UnknownFunc,
    UnknownGlobal,
    UnknownLocal,
    UnknownLabel,
    UnknownExport,
    TypeMismatch,
    MemoryRequired,
    TableRequired,
    BadAlign,
    UnbalancedControl,
    UnterminatedBody,
    StartNotVoid,
    DuplicateExport,
    IndexOutOfRange,
    LimitsInvalid,
    MemoryTooBig, // declared max pages > 32
    TableTooBig, // declared max > 256 entries
    UnsupportedImport, // imported table/memory/global (W3)
    MultiValueBlock, // blocktype with a type index (multi-value)
    StackOverflow,
};

pub const TrapKind = enum {
    @"unreachable", // the wasm `unreachable` instruction (keyword-escaped)
    bounds, // memory/table/index out of bounds
    call_indirect_type,
    div_by_zero,
    grow_limit,
    call_depth,
    stack_overflow,
    imported_unwired, // calling an imported func before W3 dispatch
};

pub const Trap = struct {
    kind: TrapKind,
    module: []const u8,
    offset: usize, // module byte offset of the faulting instruction
};

// ---------------------------------------------------------------------------
// Reader (wasm is little-endian LEB128)
// ---------------------------------------------------------------------------
const Reader = struct {
    bytes: []const u8,
    pos: usize = 0,
    base: usize = 0, // absolute module offset of bytes[0]

    fn take(r: *Reader, n: usize) ParseError![]const u8 {
        if (r.pos + n > r.bytes.len) return error.Truncated;
        const s = r.bytes[r.pos .. r.pos + n];
        r.pos += n;
        return s;
    }

    fn u8_(r: *Reader) ParseError!u8 {
        return (try r.take(1))[0];
    }

    fn absPos(r: *const Reader) usize {
        return r.base + r.pos;
    }

    /// Unsigned LEB128 u32 (max 5 bytes; >32 bits rejected).
    fn uleb(r: *Reader) ParseError!u32 {
        var result: u32 = 0;
        var shift: u5 = 0; // u32 shift counts must fit 5 bits (zig 0.16)
        var count: u8 = 0;
        while (true) : (count += 1) {
            if (count >= 5) return error.MalformedLeb;
            const b = try r.u8_();
            if (count == 4 and (b & 0x80) != 0) return error.MalformedLeb;
            const low: u32 = b & 0x7F;
            if (count == 4 and (low & 0xF0) != 0) return error.MalformedLeb;
            result |= low << shift;
            if (b & 0x80 == 0) return result;
            shift += 7;
        }
    }

    /// Signed LEB128 i64 (i32.const reads this then truncates).
    fn sleb(r: *Reader) ParseError!i64 {
        var result: i64 = 0;
        var shift: u6 = 0;
        var b: u8 = 0;
        while (true) {
            if (shift >= 64) return error.MalformedLeb;
            b = try r.u8_();
            result |= @as(i64, @intCast(b & 0x7F)) << shift;
            shift += 7;
            if (b & 0x80 == 0) break;
        }
        if (shift < 64 and (b & 0x40) != 0) {
            result |= -(@as(i64, 1) << @intCast(shift));
        }
        return result;
    }

    fn name(r: *Reader) ParseError![]const u8 {
        const len = try r.uleb();
        return r.take(len);
    }
};

// ---------------------------------------------------------------------------
// Parse
// ---------------------------------------------------------------------------
pub fn parse(bytes: []const u8) ParseError!Module {
    var m = Module{};
    var r = Reader{ .bytes = bytes };

    const magic = try r.take(4);
    if (!std.mem.eql(u8, magic, "\x00asm")) return error.BadMagic;
    const ver = try r.take(4);
    if (!std.mem.eql(u8, ver, "\x01\x00\x00\x00")) return error.BadVersion;

    var seen = [_]bool{false} ** 11;
    var prev_id: u8 = 0;
    while (r.pos < r.bytes.len) {
        const id = try r.u8_();
        if (id == 0) { // custom section: skip payload
            _ = try r.take(try r.uleb());
            continue;
        }
        if (id > 11) return error.UnknownSection;
        if (seen[id]) return error.DuplicateSection;
        if (id < prev_id) return error.SectionOutOfOrder;
        seen[id] = true;
        prev_id = id;
        const size = try r.uleb();
        const payload_pos = r.pos;
        const payload = try r.take(size);
        var pr = Reader{ .bytes = payload, .base = payload_pos };
        try parseSection(&m, &pr, id);
        if (pr.pos != pr.bytes.len) return error.TrailingBytes;
    }
    return m;
}

fn parseSection(m: *Module, r: *Reader, id: u8) ParseError!void {
    switch (id) {
        1 => { // type
            const n = try r.uleb();
            for (0..n) |_| try parseFuncType(m, r);
        },
        2 => { // import
            const n = try r.uleb();
            for (0..n) |_| try parseImport(m, r);
        },
        3 => { // function
            const n = try r.uleb();
            if (m.func_count + n > max_funcs) return error.TooManyEntries;
            for (0..n) |_| {
                m.funcs[m.func_count] = .{ .type_index = try r.uleb() };
                m.func_count += 1;
            }
        },
        4 => { // table
            const n = try r.uleb();
            if (m.table_count + n > 1) return error.TooManyEntries;
            for (0..n) |_| {
                const elem = try r.u8_();
                if (elem != 0x70) return error.UnknownValueType; // funcref
                const lim = try parseLimit(r);
                m.tables[m.table_count] = .{ .min = lim.min, .max = lim.max };
                m.table_count += 1;
            }
        },
        5 => { // memory
            const n = try r.uleb();
            if (m.has_memory or n != 1) return error.TooManyEntries;
            m.has_memory = true;
            const lim = try parseLimit(r);
            m.mem_min_pages = lim.min;
            m.mem_max_pages = lim.max;
        },
        6 => { // global
            const n = try r.uleb();
            for (0..n) |_| try parseGlobal(m, r);
        },
        7 => { // export
            const n = try r.uleb();
            for (0..n) |_| {
                const name = try r.name();
                const kb = try r.u8_();
                const kind: ExportKind = switch (kb) {
                    0 => .func,
                    1 => .table,
                    2 => .memory,
                    3 => .global,
                    else => {
                        return error.UnknownExportKind;
                    },
                };
                if (m.export_count >= max_exports) return error.TooManyEntries;
                m.exports[m.export_count] = .{ .name = name, .kind = kind, .index = try r.uleb() };
                m.export_count += 1;
            }
        },
        8 => { // start
            m.start = try r.uleb();
        },
        9 => { // element
            const n = try r.uleb();
            for (0..n) |_| {
                const seg_abs = r.absPos();
                const flags = try r.u8_();
                if (flags == 0x02) {
                    // active segment with explicit table index
                    const tidx = try r.uleb();
                    if (tidx != 0) return error.BadElementKind; // single table only
                } else if (flags != 0x00) {
                    // 0x00 = active, table 0 implicit (no index byte).
                    // 1/3/4/5/6/7 = passive/declarative/expr: out of subset
                    return error.BadElementKind;
                }
                const init = try parseConstExpr(r);
                const cnt = try r.uleb();
                if (cnt > max_table) return error.TooManyEntries;
                if (m.element_count >= max_elems) return error.TooManyEntries;
                var el = Element{ .offset = @bitCast(init.i32), .count = cnt, .abs_off = seg_abs };
                for (0..cnt) |i| el.funcs[i] = try r.uleb();
                m.elements[m.element_count] = el;
                m.element_count += 1;
            }
        },
        10 => { // code
            const n = try r.uleb();
            if (n != m.func_count) return error.CodeCountMismatch;
            for (0..n) |i| try parseCode(m, r, i);
        },
        11 => { // data
            const n = try r.uleb();
            for (0..n) |_| {
                const seg_abs = r.absPos();
                const flags = try r.u8_();
                if (flags != 0x00) return error.BadElementKind;
                const midx = try r.uleb();
                if (midx != 0) return error.BadElementKind;
                const init = try parseConstExpr(r);
                const len = try r.uleb();
                if (m.data_count >= max_datas) return error.TooManyEntries;
                m.datas[m.data_count] = .{
                    .offset = @bitCast(init.i32),
                    .bytes = try r.take(len),
                    .abs_off = seg_abs,
                };
                m.data_count += 1;
            }
        },
        else => unreachable,
    }
}

fn parseLimit(r: *Reader) ParseError!struct { min: u32, max: ?u32 } {
    const flag = try r.u8_();
    if (flag == 0) return .{ .min = try r.uleb(), .max = null };
    if (flag == 1) return .{ .min = try r.uleb(), .max = try r.uleb() };
    return error.UnknownValueType;
}

fn parseFuncType(m: *Module, r: *Reader) ParseError!void {
    if (m.type_count >= max_types) return error.TooManyEntries;
    const tag = try r.u8_();
    if (tag != 0x60) return error.UnknownValueType;
    var ft = FuncType{};
    const np = try r.uleb();
    if (np > max_params) return error.TooManyParams;
    ft.param_count = @intCast(np);
    for (0..np) |i| ft.params[i] = try ValType.fromByte(try r.u8_());
    const nr = try r.uleb();
    if (nr > max_results) return error.TooManyResults;
    ft.result_count = @intCast(nr);
    for (0..nr) |i| ft.results[i] = try ValType.fromByte(try r.u8_());
    m.types[m.type_count] = ft;
    m.type_count += 1;
}

fn parseImport(m: *Module, r: *Reader) ParseError!void {
    if (m.import_count >= max_imports) return error.TooManyEntries;
    const module = try r.name();
    const name = try r.name();
    const kb = try r.u8_();
    const kind: ImportKind = switch (kb) {
        0 => .func,
        1 => .table,
        2 => .memory,
        3 => .global,
        else => {
            return error.UnknownImportKind;
        },
    };
    var imp = Import{ .module = module, .name = name, .kind = kind };
    switch (kind) {
        .func => {
            const ti = try r.uleb();
            imp.type_index = ti;
            if (m.func_count >= max_funcs) return error.TooManyEntries;
            m.funcs[m.func_count] = .{ .type_index = ti };
            m.func_count += 1;
            m.imported_funcs += 1;
        },
        .table => {
            const elem = try r.u8_();
            if (elem != 0x70) return error.UnknownValueType;
            _ = try parseLimit(r);
        },
        .memory => {
            _ = try parseLimit(r);
        },
        .global => {
            _ = try ValType.fromByte(try r.u8_());
            _ = try r.u8_(); // mutability
        },
    }
    m.imports[m.import_count] = imp;
    m.import_count += 1;
}

fn parseGlobal(m: *Module, r: *Reader) ParseError!void {
    if (m.global_count >= max_globals) return error.TooManyEntries;
    const vt = try ValType.fromByte(try r.u8_());
    const mut = try r.u8_();
    if (mut > 1) return error.UnknownValueType;
    m.globals[m.global_count] = .{ .val_type = vt, .mutable = mut == 1, .init = try parseConstExpr(r) };
    m.global_count += 1;
}

/// Subset init expr: i32.const / i64.const followed by `end`.
fn parseConstExpr(r: *Reader) ParseError!Value {
    const op = try r.u8_();
    var v: Value = .{ .i64 = 0 };
    switch (op) {
        0x41 => v = .{ .i32 = @truncate(try r.sleb()) },
        0x42 => v = .{ .i64 = try r.sleb() },
        else => {
            return error.UnknownValueType;
        },
    }
    if ((try r.u8_()) != 0x0B) return error.UnknownValueType;
    return v;
}

/// Blocktype byte: 0x40 (empty) or one valtype (single result).
/// Multi-value block types (s33) are out of subset.
fn parseBlockType(r: *Reader) (ParseError || ValidationError)!?ValType {
    const b = try r.u8_();
    if (b == 0x40) return null;
    return ValType.fromByte(b) catch return error.MultiValueBlock;
}

fn parseCode(m: *Module, r: *Reader, func_i: usize) ParseError!void {
    const body_size = try r.uleb();
    const size_pos = r.pos;
    const ft = &m.types[m.funcs[func_i].type_index];

    // locals declaration: vec of (count, valtype) groups
    var local_types: [max_locals]ValType = undefined;
    var local_count: u8 = 0;
    for (0..ft.param_count) |i| {
        local_types[local_count] = ft.params[i];
        local_count += 1;
    }
    const groups = try r.uleb();
    for (0..groups) |_| {
        const cnt = try r.uleb();
        const vt = try ValType.fromByte(try r.u8_());
        if (local_count + cnt > max_locals) return error.TooManyLocals;
        for (0..cnt) |_| {
            local_types[local_count] = vt;
            local_count += 1;
        }
    }
    const body_start = r.pos;
    const remain = body_size - (body_start - size_pos);
    m.funcs[func_i].body = try r.take(remain);
    m.funcs[func_i].local_types = local_types;
    m.funcs[func_i].local_count = local_count;
    m.funcs[func_i].abs_off = body_start;
}

// ---------------------------------------------------------------------------
// Validation
// ---------------------------------------------------------------------------
const VStack = struct {
    items: [max_stack]ValType = undefined,
    len: usize = 0,
    polymorphic: bool = false, // unreachable: pops at frame height are unknown
};

const VCtl = struct {
    kind: enum { block, loop, if_, func },
    height: usize,
    blocktype: ?ValType = null, // null = 0x40 empty; else single result
    else_seen: bool = false,
};

fn vpush(vs: *VStack, t: ValType) ValidationError!void {
    if (vs.len >= max_stack) return error.StackOverflow;
    vs.items[vs.len] = t;
    vs.len += 1;
}

fn vpop(vs: *VStack, ctl: []const VCtl, want: ValType) ValidationError!void {
    if (vs.polymorphic and vs.len <= ctl[ctl.len - 1].height) return;
    if (vs.len == 0) return error.TypeMismatch;
    const got = vs.items[vs.len - 1];
    vs.len -= 1;
    if (got != want) return error.TypeMismatch;
}

fn vpopAny(vs: *VStack, ctl: []const VCtl) ValType {
    if (vs.polymorphic and vs.len <= ctl[ctl.len - 1].height) return .i32;
    if (vs.len == 0) return .i32;
    vs.len -= 1;
    return vs.items[vs.len];
}

fn vpopAll(vs: *VStack, ctl: []const VCtl, types: []const ValType) ValidationError!void {
    var i: usize = types.len;
    while (i > 0) {
        i -= 1;
        try vpop(vs, ctl, types[i]);
    }
}

/// Check the top of the stack matches `types`, leaving it unchanged.
fn vpeekMatch(vs: *VStack, ctl: []const VCtl, types: []const ValType) ValidationError!void {
    var saved: [max_results]ValType = undefined;
    var saved_len: usize = 0;
    var i: usize = types.len;
    while (i > 0) : (i -= 1) {
        saved[saved_len] = vpopAny(vs, ctl);
        saved_len += 1;
    }
    while (saved_len > 0) {
        saved_len -= 1;
        try vpush(vs, saved[saved_len]);
    }
}

fn labelAt(ctl: []const VCtl, depth: u32) ValidationError!*const VCtl {
    if (depth >= ctl.len) return error.UnknownLabel;
    return &ctl[ctl.len - 1 - depth];
}

pub fn validate(m: *Module) ValidationError!void {
    if (m.table_count > 0) {
        const t = m.tables[0];
        if (t.max) |mx| {
            if (mx < t.min) return error.LimitsInvalid;
            if (mx > max_table) return error.TableTooBig;
        }
        if (t.min > max_table) return error.TableTooBig;
    }
    if (m.has_memory) {
        const mx = m.mem_max_pages orelse m.mem_min_pages;
        if (mx < m.mem_min_pages) return error.LimitsInvalid;
        if (mx > max_mem_pages) return error.MemoryTooBig;
    }
    for (m.imports[0..m.import_count]) |imp| {
        switch (imp.kind) {
            .func => if (imp.type_index >= m.type_count) return error.UnknownType,
            .table, .memory, .global => {
                return error.UnsupportedImport;
            },
        }
    }
    for (m.types[0..m.type_count]) |ft| {
        for (0..ft.param_count) |i| {
            if (ft.params[i] == .f32 or ft.params[i] == .f64) return error.FloatOutOfSubset;
        }
        for (0..ft.result_count) |i| {
            if (ft.results[i] == .f32 or ft.results[i] == .f64) return error.FloatOutOfSubset;
        }
    }
    for (m.globals[0..m.global_count]) |g| {
        if (g.val_type == .f32 or g.val_type == .f64) return error.FloatOutOfSubset;
    }
    for (m.funcs[0..m.func_count]) |f| {
        if (f.type_index >= m.type_count) return error.UnknownType;
    }
    if (m.start) |si| {
        if (si >= m.func_count) return error.UnknownFunc;
        const st = &m.types[m.funcs[si].type_index];
        if (st.param_count != 0 or st.result_count != 0) return error.StartNotVoid;
    }
    for (m.exports[0..m.export_count]) |e| {
        switch (e.kind) {
            .func => if (e.index >= m.func_count) return error.UnknownExport,
            .table => if (e.index >= m.table_count) return error.UnknownExport,
            .memory => if (!m.has_memory) return error.UnknownExport,
            .global => if (e.index >= m.global_count) return error.UnknownExport,
        }
    }
    for (0..m.export_count) |i| {
        for (i + 1..m.export_count) |j| {
            if (std.mem.eql(u8, m.exports[i].name, m.exports[j].name)) return error.DuplicateExport;
        }
    }
    for (m.elements[0..m.element_count]) |el| {
        for (0..el.count) |i| {
            if (el.funcs[i] >= m.func_count) return error.UnknownFunc;
        }
        if (m.table_count == 0) return error.TableRequired;
    }
    if (m.data_count > 0 and !m.has_memory) return error.MemoryRequired;

    for (0..m.func_count) |fi| {
        if (fi < m.imported_funcs) continue; // imports have no body
        try validateBody(m, fi);
    }
}

fn validateBody(m: *Module, fi: usize) ValidationError!void {
    var vs = VStack{};
    var ctl: [max_ctl]VCtl = undefined;
    var ctl_len: usize = 1;
    const f = &m.funcs[fi];
    const ft = &m.types[f.type_index];
    if (ft.result_count > 1) return error.MultiValueBlock;
    ctl[0] = .{ .kind = .func, .height = 0, .blocktype = if (ft.result_count == 1) ft.results[0] else null };

    var pc: usize = 0;
    while (pc < f.body.len) {
        var body = Reader{ .bytes = f.body, .pos = pc };
        pc = try validateOp(m, f, ft, &vs, &ctl, &ctl_len, &body);
    }
    // the final `end` consumed the frame; a non-polymorphic stack must be
    // empty (results were checked by the vpop in the `end` handler)
    if (ctl_len != 0) return error.UnterminatedBody;
    if (!vs.polymorphic and vs.len != 0) return error.TypeMismatch;
}

fn validateOp(
    m: *Module,
    f: *const Func,
    ft: *const FuncType,
    vs: *VStack,
    ctl: []VCtl,
    ctl_len: *usize,
    body: *Reader,
) ValidationError!usize {
    const op = try body.u8_();
    switch (op) {
        0x00 => { // unreachable
            vs.len = ctl[ctl_len.* - 1].height;
            vs.polymorphic = true;
        },
        0x01 => {},
        0x02, 0x03, 0x04 => { // block / loop / if
            const bt = try parseBlockType(body);
            if (ctl_len.* >= max_ctl) return error.StackOverflow;
            if (op == 0x04) {
                try vpop(vs, ctl[0..ctl_len.*], .i32);
            }
            ctl[ctl_len.*] = .{ .kind = if (op == 0x02) .block else if (op == 0x03) .loop else .if_, .height = vs.len, .blocktype = bt };
            ctl_len.* += 1;
        },
        0x05 => { // else
            const frame = &ctl[ctl_len.* - 1];
            if (frame.kind != .if_ or frame.else_seen) return error.UnbalancedControl;
            frame.else_seen = true;
            if (frame.blocktype) |bt| try vpop(vs, ctl[0..ctl_len.*], bt);
            vs.len = frame.height;
            vs.polymorphic = false;
        },
        0x0B => { // end
            if (ctl_len.* == 0) return error.UnbalancedControl;
            const frame = &ctl[ctl_len.* - 1];
            if (frame.kind == .if_ and !frame.else_seen and frame.blocktype != null) {
                return error.TypeMismatch; // if without else must be void
            }
            if (frame.blocktype) |bt| try vpop(vs, ctl[0..ctl_len.*], bt);
            vs.len = frame.height;
            vs.polymorphic = false;
            ctl_len.* -= 1;
            if (frame.kind != .func) {
                if (frame.blocktype) |bt| try vpush(vs, bt);
            }
        },
        0x0C => { // br
            const depth = try body.uleb();
            const target = try labelAt(ctl[0..ctl_len.*], depth);
            if (target.blocktype) |bt| try vpopAll(vs, ctl[0..ctl_len.*], &[_]ValType{bt});
            vs.len = ctl[ctl_len.* - 1].height;
            vs.polymorphic = true;
        },
        0x0D => { // br_if
            try vpop(vs, ctl[0..ctl_len.*], .i32);
            const depth = try body.uleb();
            const target = try labelAt(ctl[0..ctl_len.*], depth);
            if (target.blocktype) |bt| try vpeekMatch(vs, ctl[0..ctl_len.*], &[_]ValType{bt});
        },
        0x0E => { // br_table
            try vpop(vs, ctl[0..ctl_len.*], .i32);
            const n = try body.uleb();
            if (n > max_ctl) return error.UnknownLabel;
            var target_bt: ?ValType = null;
            for (0..n) |_| {
                const d = try body.uleb();
                target_bt = (try labelAt(ctl[0..ctl_len.*], d)).blocktype;
            }
            const dd = try body.uleb();
            const def = try labelAt(ctl[0..ctl_len.*], dd);
            if (target_bt) |bt| {
                if (def.blocktype != null and def.blocktype.? != bt) return error.TypeMismatch;
            }
            if (def.blocktype) |bt| try vpeekMatch(vs, ctl[0..ctl_len.*], &[_]ValType{bt});
        },
        0x0F => { // return
            if (ft.result_count == 1) try vpop(vs, ctl[0..ctl_len.*], ft.results[0]);
            vs.len = ctl[ctl_len.* - 1].height;
            vs.polymorphic = true;
        },
        0x10 => { // call
            const fi = try body.uleb();
            if (fi >= m.func_count) return error.UnknownFunc;
            const callee = &m.types[m.funcs[fi].type_index];
            try vpopAll(vs, ctl[0..ctl_len.*], callee.params[0..callee.param_count]);
            for (callee.results[0..callee.result_count]) |t| try vpush(vs, t);
        },
        0x11 => { // call_indirect
            try vpop(vs, ctl[0..ctl_len.*], .i32);
            if (m.table_count == 0) return error.TableRequired;
            const ti = try body.uleb();
            _ = try body.u8_(); // reserved table index byte
            if (ti >= m.type_count) return error.UnknownType;
            const callee = &m.types[ti];
            try vpopAll(vs, ctl[0..ctl_len.*], callee.params[0..callee.param_count]);
            for (callee.results[0..callee.result_count]) |t| try vpush(vs, t);
        },
        0x1A => {
            _ = vpopAny(vs, ctl[0..ctl_len.*]);
        },
        0x1B => { // select
            try vpop(vs, ctl[0..ctl_len.*], .i32);
            const t2 = vpopAny(vs, ctl[0..ctl_len.*]);
            const t1 = vpopAny(vs, ctl[0..ctl_len.*]);
            if (t1 != t2) return error.TypeMismatch;
            try vpush(vs, t1);
        },
        0x20 => { // local.get
            const idx = try body.uleb();
            if (idx >= f.local_count) return error.UnknownLocal;
            try vpush(vs, f.local_types[idx]);
        },
        0x21 => { // local.set
            const idx = try body.uleb();
            if (idx >= f.local_count) return error.UnknownLocal;
            try vpop(vs, ctl[0..ctl_len.*], f.local_types[idx]);
        },
        0x22 => { // local.tee
            const idx = try body.uleb();
            if (idx >= f.local_count) return error.UnknownLocal;
            try vpop(vs, ctl[0..ctl_len.*], f.local_types[idx]);
            try vpush(vs, f.local_types[idx]);
        },
        0x23 => { // global.get
            const idx = try body.uleb();
            if (idx >= m.global_count) return error.UnknownGlobal;
            try vpush(vs, m.globals[idx].val_type);
        },
        0x24 => { // global.set
            const idx = try body.uleb();
            if (idx >= m.global_count) return error.UnknownGlobal;
            if (!m.globals[idx].mutable) return error.TypeMismatch;
            try vpop(vs, ctl[0..ctl_len.*], m.globals[idx].val_type);
        },
        0x28...0x29, 0x2C...0x35 => { // loads (f32/f64.load = 0x2A/0x2B excluded)
            if (!m.has_memory) return error.MemoryRequired;
            const al = try body.uleb();
            _ = try body.uleb();
            if (al > natAlign(op)) return error.BadAlign;
            try vpop(vs, ctl[0..ctl_len.*], .i32);
            try vpush(vs, loadType(op));
        },
        0x36...0x37, 0x3A...0x3E => { // stores (f32/f64.store = 0x38/0x39 excluded)
            if (!m.has_memory) return error.MemoryRequired;
            const al = try body.uleb();
            _ = try body.uleb();
            if (al > natAlign(op)) return error.BadAlign;
            try vpop(vs, ctl[0..ctl_len.*], storeType(op));
            try vpop(vs, ctl[0..ctl_len.*], .i32);
        },
        0x2A, 0x2B, 0x38, 0x39 => {
            return error.FloatOutOfSubset;
        }, // float memory ops
        0x3F => { // memory.size
            if (!m.has_memory) return error.MemoryRequired;
            _ = try body.u8_();
            try vpush(vs, .i32);
        },
        0x40 => { // memory.grow
            if (!m.has_memory) return error.MemoryRequired;
            _ = try body.u8_();
            try vpop(vs, ctl[0..ctl_len.*], .i32);
            try vpush(vs, .i32);
        },
        0x41 => {
            _ = try body.sleb();
            try vpush(vs, .i32);
        },
        0x42 => {
            _ = try body.sleb();
            try vpush(vs, .i64);
        },
        0x43, 0x44 => {
            return error.FloatOutOfSubset;
        },
        0x45 => {
            try vpop(vs, ctl[0..ctl_len.*], .i32);
            try vpush(vs, .i32);
        },
        0x50 => {
            try vpop(vs, ctl[0..ctl_len.*], .i64);
            try vpush(vs, .i32);
        },
        0x46...0x4F => {
            try vpop(vs, ctl[0..ctl_len.*], .i32);
            try vpop(vs, ctl[0..ctl_len.*], .i32);
            try vpush(vs, .i32);
        },
        0x51...0x5A => {
            try vpop(vs, ctl[0..ctl_len.*], .i64);
            try vpop(vs, ctl[0..ctl_len.*], .i64);
            try vpush(vs, .i32);
        },
        0x5B...0x66, 0x8B...0xA6, 0xAA...0xBF => { // f32/f64: cmp, arith, trunc, convert, reinterpret
            return error.FloatOutOfSubset;
        },
        0x67...0x78 => {
            const unary = op <= 0x69;
            try vpop(vs, ctl[0..ctl_len.*], .i32);
            if (!unary) try vpop(vs, ctl[0..ctl_len.*], .i32);
            try vpush(vs, .i32);
        },
        0x79...0x8A => {
            const unary = op <= 0x7B;
            try vpop(vs, ctl[0..ctl_len.*], .i64);
            if (!unary) try vpop(vs, ctl[0..ctl_len.*], .i64);
            try vpush(vs, .i64);
        },
        0xA7 => {
            try vpop(vs, ctl[0..ctl_len.*], .i64);
            try vpush(vs, .i32);
        },
        0xA8, 0xA9 => { // i64.extend_i32_s / _u
            try vpop(vs, ctl[0..ctl_len.*], .i32);
            try vpush(vs, .i64);
        },
        0xC0...0xC4 => {
            const t: ValType = if (op <= 0xC1) .i32 else .i64;
            try vpop(vs, ctl[0..ctl_len.*], t);
            try vpush(vs, t);
        },
        else => {
            return error.UnknownValueType;
        },
    }
    return body.pos;
}

fn natAlign(op: u8) u32 {
    return switch (op) {
        0x2C, 0x2D, 0x30, 0x31 => 0, // 8-bit
        0x2E, 0x2F, 0x32, 0x33 => 1, // 16-bit
        0x28, 0x34, 0x35, 0x36, 0x3A, 0x3B, 0x3E => 2, // 32-bit
        0x29, 0x37, 0x3C, 0x3D => 3, // 64-bit
        else => 0,
    };
}

fn loadType(op: u8) ValType {
    return switch (op) {
        0x28, 0x2C...0x2F => .i32,
        else => .i64,
    };
}

fn storeType(op: u8) ValType {
    return switch (op) {
        0x36, 0x3A, 0x3B => .i32,
        else => .i64,
    };
}

// ---------------------------------------------------------------------------
// Execution
// ---------------------------------------------------------------------------
const Frame = struct {
    func_idx: u32 = 0,
    locals: [max_locals]Value = undefined,
    height: usize = 0, // operand-stack base for this call
    ctl_base: usize = 0,
    body: []const u8 = &.{},
    pc: usize = 0,
    abs_off: usize = 0,
};

const ECtl = struct {
    kind: enum { block, loop, if_, func },
    height: usize,
    blocktype: ?ValType = null,
    else_pc: ?usize = null, // if-only
    end_pc: usize = 0, // pc of the matching `end`
    arity: u8 = 0, // 0 or 1
};

pub const CallResult = union(enum) {
    ret: struct {
        vals: [max_results]Value = undefined,
        count: u8 = 0,
    },
    trap: Trap,
};

const TrapError = error{Trap};

fn mkTrap(kind: TrapKind, module: []const u8, offset: usize) CallResult {
    return .{ .trap = .{ .kind = kind, .module = module, .offset = offset } };
}

/// The machine: file-scope global (segmented DSK3 .data/.bss) so the
/// EL0 stack never carries it. One instance; the runner re-instantiates
/// per module.
pub var machine = Machine{};

pub const Machine = struct {
    stack: [max_stack]Value = undefined,
    sp: usize = 0,
    ctl: [max_ctl]ECtl = undefined,
    ctl_len: usize = 0,
    frames: [max_frames]Frame = undefined,
    frame_len: usize = 0,
    table: [max_table]u32 = undefined,
    table_len: u32 = 0,
    store: []u8 = &.{},
    mem_pages: u32 = 0,
    mem_max: u32 = 0,
    globals: [max_globals]Value = undefined,
    module_name: []const u8 = "module",
    last_trap: ?Trap = null,
};

pub fn resetMachine(mm: *Machine) void {
    mm.sp = 0;
    mm.ctl_len = 0;
    mm.frame_len = 0;
    mm.table_len = 0;
    mm.store = &.{};
    mm.mem_pages = 0;
    mm.mem_max = 0;
    mm.module_name = "module";
    mm.last_trap = null;
}

/// Bind the store, apply element + data segments, then run `start` (if any).
/// Returns null on success or the instantiation trap.
pub fn instantiate(mm: *Machine, m: *const Module, store: []u8, module_name: []const u8) ?CallResult {
    resetMachine(mm);
    mm.module_name = module_name;
    mm.store = store;
    mm.table_len = if (m.table_count > 0) m.tables[0].min else 0;
    if (m.has_memory) {
        const declared = m.mem_max_pages orelse max_mem_pages;
        const store_pages: u32 = @intCast(@min(@as(usize, std.math.maxInt(u32)), store.len / page_size));
        mm.mem_max = @min(declared, @min(max_mem_pages, store_pages));
        mm.mem_pages = @min(m.mem_min_pages, mm.mem_max);
    }
    for (0..m.global_count) |i| mm.globals[i] = m.globals[i].init;
    for (m.elements[0..m.element_count]) |el| {
        if (el.offset + el.count > mm.table_len) return mkTrap(.bounds, module_name, el.abs_off);
        for (0..el.count) |i| mm.table[el.offset + i] = el.funcs[i];
    }
    for (m.datas[0..m.data_count]) |d| {
        const mem_len = @as(u64, mm.mem_pages) * page_size;
        if (@as(u64, d.offset) + d.bytes.len > mem_len) return mkTrap(.bounds, module_name, d.abs_off);
        @memcpy(mm.store[d.offset .. d.offset + d.bytes.len], d.bytes);
    }
    if (m.start) |si| {
        const r = callInternal(mm, m, si, &.{}); // si validated < func_count
        if (r == .trap) return r;
    }
    return null;
}

/// Invoke a defined function. `args` values are copied into the callee's
/// locals (param slots first). Trap results carry module + offset.
pub fn call(mm: *Machine, m: *const Module, func_idx: u32, args: []const Value) CallResult {
    if (func_idx >= m.func_count) return mkTrap(.bounds, mm.module_name, 0);
    if (func_idx < m.imported_funcs) return mkTrap(.imported_unwired, mm.module_name, 0);
    return callInternal(mm, m, func_idx, args);
}

fn callInternal(mm: *Machine, m: *const Module, func_idx: u32, args: []const Value) CallResult {
    const f = &m.funcs[func_idx];
    const ft = &m.types[f.type_index];
    if (args.len != ft.param_count) return mkTrap(.bounds, mm.module_name, f.abs_off);
    if (mm.frame_len >= max_frames) return mkTrap(.call_depth, mm.module_name, f.abs_off);

    var frame = Frame{
        .func_idx = func_idx,
        .height = mm.sp,
        .ctl_base = mm.ctl_len,
        .body = f.body,
        .abs_off = f.abs_off,
    };
    for (0..f.local_count) |i| frame.locals[i] = .{ .i64 = 0 };
    for (0..args.len) |i| frame.locals[i] = args[i];
    mm.frames[mm.frame_len] = frame;
    mm.frame_len += 1;

    if (mm.ctl_len >= max_ctl) {
        mm.frame_len -= 1;
        return mkTrap(.stack_overflow, mm.module_name, f.abs_off);
    }
    mm.ctl[mm.ctl_len] = .{
        .kind = .func,
        .height = mm.sp,
        .blocktype = if (ft.result_count == 1) ft.results[0] else null,
        .arity = ft.result_count,
    };
    mm.ctl_len += 1;
    mm.sp = frame.height; // args copied into locals; stack starts empty

    const r = execBody(mm, m, ft);
    mm.ctl_len = frame.ctl_base;
    mm.frame_len -= 1;
    mm.sp = frame.height;
    return r;
}

fn tryPush(mm: *Machine, v: Value) error{StackOverflow}!void {
    if (mm.sp >= max_stack) return error.StackOverflow;
    mm.stack[mm.sp] = v;
    mm.sp += 1;
}

fn popVal(mm: *Machine) Value {
    mm.sp -= 1;
    return mm.stack[mm.sp];
}

/// Scan the body from `from` for the matching `end` (and `else` for an
/// if) at nesting depth 0. The scanner skips over immediates so bytes
/// inside i32.const etc. never confuse the depth counter.
fn findBlockEnd(body: []const u8, from: usize, want_else: bool) struct { end_pc: usize, else_pc: ?usize } {
    var depth: usize = 0;
    var pc = from;
    var else_pc: ?usize = null;
    while (pc < body.len) {
        const op = body[pc];
        switch (op) {
            0x02, 0x03, 0x04 => {
                depth += 1;
                pc += 2; // opcode + blocktype byte
            },
            0x05 => {
                if (depth == 0 and want_else and else_pc == null) else_pc = pc;
                pc += 1;
            },
            0x0B => {
                if (depth == 0) return .{ .end_pc = pc, .else_pc = else_pc };
                depth -= 1;
                pc += 1;
            },
            else => pc = skipInstr(body, pc),
        }
    }
    return .{ .end_pc = body.len, .else_pc = else_pc };
}

/// Advance past one instruction (incl. immediates) at `pc`.
fn skipInstr(body: []const u8, pc: usize) usize {
    const op = body[pc];
    return switch (op) {
        0x0C, 0x0D => pc + 1 + lebLen(body, pc + 1),
        0x0E => blk: {
            // count uleb; count ulebs; default uleb (the vec is the count)
            var p = pc + 1;
            const n = readUlebRaw(body, &p);
            var i: u32 = 0;
            while (i < n) : (i += 1) _ = readUlebRaw(body, &p);
            _ = readUlebRaw(body, &p);
            break :blk p;
        },
        0x10, 0x11 => pc + 1 + lebLen(body, pc + 1) + @as(usize, @intFromBool(op == 0x11)),
        0x20...0x24 => pc + 1 + lebLen(body, pc + 1),
        0x28...0x3E => pc + 1 + lebLen(body, pc + 1) + lebLen(body, pc + 1 + lebLen(body, pc + 1)),
        0x3F, 0x40 => pc + 2, // memory.size/grow: one reserved byte
        0x41, 0x42 => blk: {
            var p = pc + 1;
            while (p < body.len and body[p] & 0x80 != 0) p += 1;
            break :blk p + 1;
        },
        else => pc + 1,
    };
}

/// Raw uleb read for the scanner (no error plumbing; bounded by max 5).
fn readUlebRaw(body: []const u8, p: *usize) u32 {
    var result: u32 = 0;
    var shift: u6 = 0;
    var count: u8 = 0;
    while (true) : ({
        count += 1;
        shift += 7;
    }) {
        const b = body[p.*];
        p.* += 1;
        if (count >= 5) return result; // malformed: scanner is best-effort
        result |= @as(u32, b & 0x7F) << @intCast(shift);
        if (b & 0x80 == 0) return result;
    }
}

fn lebLen(body: []const u8, from: usize) usize {
    var i: usize = 0;
    while (from + i < body.len and body[from + i] & 0x80 != 0) : (i += 1) {}
    return if (from + i >= body.len) body.len - from else i + 1;
}

fn blockArity(bt: ?ValType) u8 {
    return if (bt != null) 1 else 0;
}

fn branch(mm: *Machine, frame: *Frame, depth: u32, op_off: usize) CallResult {
    if (depth >= mm.ctl_len) return mkTrap(.bounds, mm.module_name, op_off);
    const target = mm.ctl[mm.ctl_len - 1 - depth];
    if (target.kind == .func) {
        // br to the function label == return
        const n_out: usize = mm.sp - frame.height;
        var res: [max_results]Value = undefined;
        for (0..n_out) |i| res[i] = mm.stack[frame.height + i];
        var out: [max_results]Value = undefined;
        for (0..n_out) |i| out[i] = res[n_out - 1 - i];
        mm.sp = frame.height;
        mm.ctl_len = frame.ctl_base;
        return .{ .ret = .{ .vals = out, .count = @intCast(n_out) } };
    }
    if (target.kind == .loop) {
        // loop: jump back to the body start with the loop label arity
        // values on the stack (the blocktype result is the loop param).
        frame.pc = target.end_pc; // stored: the loop's BODY start
        mm.sp = target.height + target.arity;
        mm.ctl_len -= depth; // keep the loop frame
        return .{ .ret = .{ .count = 0 } };
    } else {
        // block/if: jump past the matching end, popping the target frame
        const n_res: usize = if (target.blocktype != null) @as(usize, 1) else 0;
        frame.pc = target.end_pc + 1;
        mm.sp = target.height + n_res;
        mm.ctl_len -= depth + 1;
        return .{ .ret = .{ .count = 0 } };
    }
}

fn execBody(mm: *Machine, m: *const Module, ft0: *const FuncType) CallResult {
    _ = ft0;
    while (true) {
        const frame = &mm.frames[mm.frame_len - 1];
        if (frame.pc >= frame.body.len) return mkTrap(.bounds, mm.module_name, frame.abs_off + frame.pc);
        const op = frame.body[frame.pc];
        const op_off = frame.abs_off + frame.pc;
        frame.pc += 1;
        var body = Reader{ .bytes = frame.body, .pos = frame.pc };
        switch (op) {
            0x00 => {
                return mkTrap(.@"unreachable", mm.module_name, op_off);
            },
            0x01 => {},
            0x02, 0x03, 0x04 => { // block / loop / if
                const bt = parseBlockType(&body) catch return mkTrap(.bounds, mm.module_name, op_off);
                const ar = blockArity(bt);
                if (op == 0x04) { // if: pop condition
                    const cond = popVal(mm).i32;
                    if (cond == 0) {
                        // find the else/end and jump
                        const be = findBlockEnd(frame.body, body.pos, true);
                        if (be.else_pc) |ep| {
                            frame.pc = ep + 1;
                            // push a ctl frame for the else path so `end`
                            // pops it symmetrically
                            if (mm.ctl_len >= max_ctl) return mkTrap(.stack_overflow, mm.module_name, op_off);
                            mm.ctl[mm.ctl_len] = .{ .kind = .if_, .height = mm.sp, .blocktype = bt, .end_pc = be.end_pc, .arity = ar };
                            mm.ctl_len += 1;
                        } else {
                            frame.pc = be.end_pc; // run the `end` directly
                            if (mm.ctl_len >= max_ctl) return mkTrap(.stack_overflow, mm.module_name, op_off);
                            mm.ctl[mm.ctl_len] = .{ .kind = .if_, .height = mm.sp, .blocktype = bt, .end_pc = be.end_pc, .arity = ar };
                            mm.ctl_len += 1;
                        }
                        continue;
                    }
                }
                if (mm.ctl_len >= max_ctl) return mkTrap(.stack_overflow, mm.module_name, op_off);
                const be = findBlockEnd(frame.body, body.pos, false);
                mm.ctl[mm.ctl_len] = .{
                    .kind = if (op == 0x02) .block else if (op == 0x03) .loop else .if_,
                    .height = mm.sp,
                    .blocktype = bt,
                    .end_pc = if (op == 0x03) body.pos else be.end_pc,
                    .arity = ar,
                };
                mm.ctl_len += 1;
            },
            0x05 => { // else (true path fell through)
                const entry = &mm.ctl[mm.ctl_len - 1];
                if (entry.kind != .if_) return mkTrap(.@"unreachable", mm.module_name, op_off);
                // true-path values are dropped (the blocktype arity was
                // validated); jump to the matching end (if any)
                if (entry.blocktype) |_| {
                    // the true path SHOULD have left the result; verify the
                    // result slot count and drop everything above height
                    if (mm.sp >= entry.height + entry.arity) {
                        mm.sp = entry.height + entry.arity;
                    }
                } else {
                    mm.sp = entry.height;
                }
                frame.pc = entry.end_pc;
            },
            0x0B => { // end
                if (mm.ctl_len == 0) return mkTrap(.@"unreachable", mm.module_name, op_off);
                const entry = mm.ctl[mm.ctl_len - 1];
                mm.ctl_len -= 1;
                if (entry.kind == .func) {
                    var res: [max_results]Value = undefined;
                    var n: u8 = 0;
                    while (mm.sp > entry.height) {
                        res[n] = popVal(mm);
                        n += 1;
                    }
                    var out: [max_results]Value = undefined;
                    for (0..n) |i| out[i] = res[n - 1 - i];
                    mm.sp = entry.height;
                    return .{ .ret = .{ .vals = out, .count = n } };
                }
                // block/loop/if fall-through: keep the blocktype result
                mm.sp = entry.height + entry.arity;
                // (blocktype arity was validated: at most 1 value sits above)
            },
            0x0C => { // br
                const depth = body.uleb() catch return mkTrap(.bounds, mm.module_name, op_off);
                const r = branch(mm, frame, depth, op_off);
                if (r == .trap) return r;
                continue;
            },
            0x0D => { // br_if
                const depth = body.uleb() catch return mkTrap(.bounds, mm.module_name, op_off);
                const cond = popVal(mm).i32;
                if (cond != 0) {
                    const r = branch(mm, frame, depth, op_off);
                    if (r == .trap) return r;
                    continue;
                }
            },
            0x0E => { // br_table
                const n = body.uleb() catch return mkTrap(.bounds, mm.module_name, op_off);
                var depths: [max_ctl]u32 = undefined;
                for (0..n) |i| depths[i] = body.uleb() catch return mkTrap(.bounds, mm.module_name, op_off);
                const def = body.uleb() catch return mkTrap(.bounds, mm.module_name, op_off);
                const idx = popVal(mm).i32;
                const d: u32 = if (idx < 0 or @as(u32, @intCast(idx)) >= n) def else depths[@intCast(idx)];
                const r = branch(mm, frame, d, op_off);
                if (r == .trap) return r;
                continue;
            },
            0x0F => { // return
                const func_frame = &mm.frames[mm.frame_len - 1];
                const height = func_frame.height;
                const n_out: usize = mm.sp - height;
                var res: [max_results]Value = undefined;
                for (0..n_out) |i| res[i] = mm.stack[height + i];
                var out: [max_results]Value = undefined;
                for (0..n_out) |i| out[i] = res[n_out - 1 - i];
                mm.sp = height;
                return .{ .ret = .{ .vals = out, .count = @intCast(n_out) } };
            },
            0x10 => { // call
                const fi = body.uleb() catch return mkTrap(.bounds, mm.module_name, op_off);
                if (fi >= m.func_count) return mkTrap(.bounds, mm.module_name, op_off);
                if (fi < m.imported_funcs) return mkTrap(.imported_unwired, mm.module_name, op_off);
                const callee = &m.types[m.funcs[fi].type_index];
                // pop args into an array (last param topmost)
                var args: [max_params]Value = undefined;
                for (0..callee.param_count) |i| {
                    args[callee.param_count - 1 - i] = popVal(mm);
                }
                const r = callInternal(mm, m, fi, args[0..callee.param_count]);
                if (r == .trap) return r;
                for (0..r.ret.count) |i| tryPush(mm, r.ret.vals[i]) catch return mkTrap(.stack_overflow, mm.module_name, op_off);
            },
            0x11 => { // call_indirect
                const ti = body.uleb() catch return mkTrap(.bounds, mm.module_name, op_off);
                _ = body.u8_() catch return mkTrap(.bounds, mm.module_name, op_off);
                if (ti >= m.type_count) return mkTrap(.bounds, mm.module_name, op_off);
                const expected = &m.types[ti];
                const tbl_idx = popVal(mm).i32;
                if (tbl_idx < 0 or @as(u32, @intCast(tbl_idx)) >= mm.table_len) {
                    return mkTrap(.bounds, mm.module_name, op_off);
                }
                const fi = mm.table[@intCast(tbl_idx)];
                if (fi >= m.func_count) return mkTrap(.bounds, mm.module_name, op_off);
                if (fi < m.imported_funcs) return mkTrap(.imported_unwired, mm.module_name, op_off);
                const actual = &m.types[m.funcs[fi].type_index];
                if (!FuncType.eql(expected.*, actual.*)) return mkTrap(.call_indirect_type, mm.module_name, op_off);
                var args: [max_params]Value = undefined;
                for (0..actual.param_count) |i| {
                    args[actual.param_count - 1 - i] = popVal(mm);
                }
                const r = callInternal(mm, m, fi, args[0..actual.param_count]);
                if (r == .trap) return r;
                for (0..r.ret.count) |i| tryPush(mm, r.ret.vals[i]) catch return mkTrap(.stack_overflow, mm.module_name, op_off);
            },
            0x1A => {
                _ = popVal(mm);
            },
            0x1B => { // select
                const cond = popVal(mm).i32;
                const v2 = popVal(mm);
                const v1 = popVal(mm);
                tryPush(mm, if (cond != 0) v1 else v2) catch return mkTrap(.stack_overflow, mm.module_name, op_off);
            },
            0x20 => { // local.get
                const idx = body.uleb() catch return mkTrap(.bounds, mm.module_name, op_off);
                if (idx >= mm.frames[mm.frame_len - 1].locals.len) return mkTrap(.bounds, mm.module_name, op_off);
                tryPush(mm, mm.frames[mm.frame_len - 1].locals[idx]) catch return mkTrap(.stack_overflow, mm.module_name, op_off);
            },
            0x21 => { // local.set
                const idx = body.uleb() catch return mkTrap(.bounds, mm.module_name, op_off);
                if (idx >= mm.frames[mm.frame_len - 1].locals.len) return mkTrap(.bounds, mm.module_name, op_off);
                mm.frames[mm.frame_len - 1].locals[idx] = popVal(mm);
            },
            0x22 => { // local.tee
                const idx = body.uleb() catch return mkTrap(.bounds, mm.module_name, op_off);
                if (idx >= mm.frames[mm.frame_len - 1].locals.len) return mkTrap(.bounds, mm.module_name, op_off);
                const v = popVal(mm);
                mm.frames[mm.frame_len - 1].locals[idx] = v;
                tryPush(mm, v) catch return mkTrap(.stack_overflow, mm.module_name, op_off);
            },
            0x23 => { // global.get
                const idx = body.uleb() catch return mkTrap(.bounds, mm.module_name, op_off);
                if (idx >= m.global_count) return mkTrap(.bounds, mm.module_name, op_off);
                tryPush(mm, mm.globals[idx]) catch return mkTrap(.stack_overflow, mm.module_name, op_off);
            },
            0x24 => { // global.set
                const idx = body.uleb() catch return mkTrap(.bounds, mm.module_name, op_off);
                if (idx >= m.global_count) return mkTrap(.bounds, mm.module_name, op_off);
                mm.globals[idx] = popVal(mm);
            },
            0x28...0x35 => { // loads
                _ = body.uleb() catch return mkTrap(.bounds, mm.module_name, op_off);
                const off = body.uleb() catch return mkTrap(.bounds, mm.module_name, op_off);
                const addr = @as(u32, @bitCast(popVal(mm).i32));
                const v = loadMem(mm, op, addr, off) catch return mkTrap(.bounds, mm.module_name, op_off);
                tryPush(mm, v) catch return mkTrap(.stack_overflow, mm.module_name, op_off);
            },
            0x36...0x3E => { // stores
                _ = body.uleb() catch return mkTrap(.bounds, mm.module_name, op_off);
                const off = body.uleb() catch return mkTrap(.bounds, mm.module_name, op_off);
                const v = popVal(mm);
                const addr = @as(u32, @bitCast(popVal(mm).i32));
                storeMem(mm, op, addr, off, v) catch return mkTrap(.bounds, mm.module_name, op_off);
            },
            0x3F => { // memory.size
                _ = body.u8_() catch return mkTrap(.bounds, mm.module_name, op_off);
                tryPush(mm, .{ .i32 = @intCast(mm.mem_pages) }) catch return mkTrap(.stack_overflow, mm.module_name, op_off);
            },
            0x40 => { // memory.grow
                _ = body.u8_() catch return mkTrap(.bounds, mm.module_name, op_off);
                const delta = @as(u32, @bitCast(popVal(mm).i32));
                const cur = mm.mem_pages;
                const new = cur +% delta;
                if (new > mm.mem_max or new > max_mem_pages) return mkTrap(.grow_limit, mm.module_name, op_off);
                if (@as(u64, new) * page_size > mm.store.len) return mkTrap(.grow_limit, mm.module_name, op_off);
                @memset(mm.store[@as(usize, cur) * page_size .. @as(usize, new) * page_size], 0);
                mm.mem_pages = new;
                tryPush(mm, .{ .i32 = @intCast(cur) }) catch return mkTrap(.stack_overflow, mm.module_name, op_off);
            },
            0x41 => { // i32.const
                const v = body.sleb() catch return mkTrap(.bounds, mm.module_name, op_off);
                tryPush(mm, .{ .i32 = @truncate(v) }) catch return mkTrap(.stack_overflow, mm.module_name, op_off);
            },
            0x42 => { // i64.const
                const v = body.sleb() catch return mkTrap(.bounds, mm.module_name, op_off);
                tryPush(mm, .{ .i64 = v }) catch return mkTrap(.stack_overflow, mm.module_name, op_off);
            },
            0x45 => { // i32.eqz
                tryPush(mm, .{ .i32 = @intFromBool(popVal(mm).i32 == 0) }) catch return mkTrap(.stack_overflow, mm.module_name, op_off);
            },
            0x50 => { // i64.eqz
                tryPush(mm, .{ .i32 = @intFromBool(popVal(mm).i64 == 0) }) catch return mkTrap(.stack_overflow, mm.module_name, op_off);
            },
            0x46...0x4F => {
                const b = popVal(mm).i32;
                const a = popVal(mm).i32;
                tryPush(mm, .{ .i32 = cmpI32(op, a, b) }) catch return mkTrap(.stack_overflow, mm.module_name, op_off);
            },
            0x51...0x5A => {
                const b = popVal(mm).i64;
                const a = popVal(mm).i64;
                tryPush(mm, .{ .i32 = cmpI64(op, a, b) }) catch return mkTrap(.stack_overflow, mm.module_name, op_off);
            },
            0x67...0x78 => {
                const r = execI32(mm, op) catch return mkTrap(.div_by_zero, mm.module_name, op_off);
                tryPush(mm, .{ .i32 = r }) catch return mkTrap(.stack_overflow, mm.module_name, op_off);
            },
            0x79...0x8A => {
                const r = execI64(mm, op) catch return mkTrap(.div_by_zero, mm.module_name, op_off);
                tryPush(mm, .{ .i64 = r }) catch return mkTrap(.stack_overflow, mm.module_name, op_off);
            },
            0xA7 => { // i32.wrap_i64
                tryPush(mm, .{ .i32 = @truncate(popVal(mm).i64) }) catch return mkTrap(.stack_overflow, mm.module_name, op_off);
            },
            0xA8 => { // i64.extend_i32_s
                tryPush(mm, .{ .i64 = popVal(mm).i32 }) catch return mkTrap(.stack_overflow, mm.module_name, op_off);
            },
            0xA9 => { // i64.extend_i32_u
                const v = popVal(mm).i32;
                tryPush(mm, .{ .i64 = @intCast(@as(u32, @bitCast(v))) }) catch return mkTrap(.stack_overflow, mm.module_name, op_off);
            },
            0xC0, 0xC1 => { // i32.extend8_s / extend16_s
                const v = popVal(mm).i32;
                const r: i32 = if (op == 0xC0) @as(i8, @truncate(v)) else @as(i16, @truncate(v));
                tryPush(mm, .{ .i32 = r }) catch return mkTrap(.stack_overflow, mm.module_name, op_off);
            },
            0xC2...0xC4 => { // i64.extend8/16/32_s
                const v = popVal(mm).i64;
                const r: i64 = switch (op) {
                    0xC2 => @as(i8, @truncate(v)),
                    0xC3 => @as(i16, @truncate(v)),
                    else => @as(i32, @truncate(v)),
                };
                tryPush(mm, .{ .i64 = r }) catch return mkTrap(.stack_overflow, mm.module_name, op_off);
            },
            else => {
                return mkTrap(.bounds, mm.module_name, op_off);
            },
        }
        frame.pc = body.pos;
    }
}

fn loadMem(mm: *Machine, op: u8, addr: u32, off: u32) error{Bounds}!Value {
    const ea = @as(u64, addr) + off;
    const mem_len = @as(u64, mm.mem_pages) * page_size;
    if (ea + loadSize(op) > mem_len) return error.Bounds;
    const p = mm.store[@intCast(ea)..][0..loadSize(op)];
    return switch (op) {
        0x28 => .{ .i32 = @bitCast(readInt(u32, p[0..4])) },
        0x29 => .{ .i64 = @bitCast(readInt(u64, p[0..8])) },
        0x2C => .{ .i32 = @as(i8, @bitCast(p[0])) },
        0x2D => .{ .i32 = p[0] },
        0x2E => .{ .i32 = @as(i16, @bitCast(readInt(u16, p[0..2]))) },
        0x2F => .{ .i32 = readInt(u16, p[0..2]) },
        0x30 => .{ .i64 = @as(i8, @bitCast(p[0])) },
        0x31 => .{ .i64 = p[0] },
        0x32 => .{ .i64 = @as(i16, @bitCast(readInt(u16, p[0..2]))) },
        0x33 => .{ .i64 = readInt(u16, p[0..2]) },
        0x34 => .{ .i64 = @as(i32, @bitCast(readInt(u32, p[0..4]))) },
        0x35 => .{ .i64 = readInt(u32, p[0..4]) },
        else => unreachable,
    };
}

fn storeMem(mm: *Machine, op: u8, addr: u32, off: u32, v: Value) error{Bounds}!void {
    const ea = @as(u64, addr) + off;
    const mem_len = @as(u64, mm.mem_pages) * page_size;
    if (ea + storeSize(op) > mem_len) return error.Bounds;
    const p = mm.store[@intCast(ea)..][0..storeSize(op)];
    switch (op) {
        0x36 => writeInt(u32, p[0..4], @bitCast(v.i32)),
        0x37 => writeInt(u64, p[0..8], @bitCast(v.i64)),
        0x3A => p[0] = @truncate(@as(u32, @bitCast(v.i32))),
        0x3B => writeInt(u16, p[0..2], @truncate(@as(u32, @bitCast(v.i32)))),
        0x3C => p[0] = @truncate(@as(u64, @bitCast(v.i64))),
        0x3D => writeInt(u16, p[0..2], @truncate(@as(u64, @bitCast(v.i64)))),
        0x3E => writeInt(u32, p[0..4], @truncate(@as(u64, @bitCast(v.i64)))),
        else => unreachable,
    }
}

fn loadSize(op: u8) usize {
    return switch (op) {
        0x2C, 0x2D, 0x30, 0x31 => 1,
        0x2E, 0x2F, 0x32, 0x33 => 2,
        0x34, 0x35, 0x28 => 4,
        else => 8,
    };
}

fn storeSize(op: u8) usize {
    return switch (op) {
        0x3A, 0x3C => 1,
        0x3B, 0x3D => 2,
        0x3E, 0x36 => 4,
        else => 8,
    };
}

fn readInt(comptime T: type, bytes: []const u8) T {
    return std.mem.readInt(T, bytes[0..@sizeOf(T)], .little);
}

fn writeInt(comptime T: type, bytes: []u8, v: T) void {
    std.mem.writeInt(T, bytes[0..@sizeOf(T)], v, .little);
}

fn cmpI32(op: u8, a: i32, b: i32) i32 {
    return switch (op) {
        0x46 => @intFromBool(a == b),
        0x47 => @intFromBool(a != b),
        0x48 => @intFromBool(a < b),
        0x49 => @intFromBool(@as(u32, @bitCast(a)) < @as(u32, @bitCast(b))),
        0x4A => @intFromBool(a > b),
        0x4B => @intFromBool(@as(u32, @bitCast(a)) > @as(u32, @bitCast(b))),
        0x4C => @intFromBool(a <= b),
        0x4D => @intFromBool(@as(u32, @bitCast(a)) <= @as(u32, @bitCast(b))),
        0x4E => @intFromBool(a >= b),
        0x4F => @intFromBool(@as(u32, @bitCast(a)) >= @as(u32, @bitCast(b))),
        else => unreachable,
    };
}

fn cmpI64(op: u8, a: i64, b: i64) i32 {
    return switch (op) {
        0x51 => @intFromBool(a == b),
        0x52 => @intFromBool(a != b),
        0x53 => @intFromBool(a < b),
        0x54 => @intFromBool(@as(u64, @bitCast(a)) < @as(u64, @bitCast(b))),
        0x55 => @intFromBool(a > b),
        0x56 => @intFromBool(@as(u64, @bitCast(a)) > @as(u64, @bitCast(b))),
        0x57 => @intFromBool(a <= b),
        0x58 => @intFromBool(@as(u64, @bitCast(a)) <= @as(u64, @bitCast(b))),
        0x59 => @intFromBool(a >= b),
        0x5A => @intFromBool(@as(u64, @bitCast(a)) >= @as(u64, @bitCast(b))),
        else => unreachable,
    };
}

const DivError = error{Div0};

fn execI32(mm: *Machine, op: u8) DivError!i32 {
    const b = popVal(mm).i32;
    if (op == 0x67) return @intCast(@clz(@as(u32, @bitCast(b))));
    if (op == 0x68) return @intCast(@ctz(@as(u32, @bitCast(b))));
    if (op == 0x69) return @intCast(@popCount(@as(u32, @bitCast(b))));
    const a = popVal(mm).i32;
    return switch (op) {
        0x6A => a +% b,
        0x6B => a -% b,
        0x6C => a *% b,
        0x6D => {
            if (b == 0) return error.Div0;
            if (a == std.math.minInt(i32) and b == -1) return error.Div0;
            return @divTrunc(a, b);
        },
        0x6E => {
            if (b == 0) return error.Div0;
            return @intCast(@divTrunc(@as(u32, @bitCast(a)), @as(u32, @bitCast(b))));
        },
        0x6F => {
            if (b == 0) return error.Div0;
            return @rem(a, b);
        },
        0x70 => {
            if (b == 0) return error.Div0;
            return @intCast(@rem(@as(u32, @bitCast(a)), @as(u32, @bitCast(b))));
        },
        0x71 => a & b,
        0x72 => a | b,
        0x73 => a ^ b,
        0x74 => @bitCast(@as(u32, @bitCast(a)) << @as(u5, @truncate(@as(u32, @bitCast(b))))),
        0x75 => @bitCast(@as(i32, a) >> @as(u5, @truncate(@as(u32, @bitCast(b))))),
        0x76 => @bitCast(@as(u32, @bitCast(a)) >> @as(u5, @truncate(@as(u32, @bitCast(b))))),
        0x77 => rotl32(a, b),
        0x78 => rotr32(a, b),
        else => unreachable,
    };
}

fn execI64(mm: *Machine, op: u8) DivError!i64 {
    const b = popVal(mm).i64;
    if (op == 0x79) return @intCast(@clz(@as(u64, @bitCast(b))));
    if (op == 0x7A) return @intCast(@ctz(@as(u64, @bitCast(b))));
    if (op == 0x7B) return @intCast(@popCount(@as(u64, @bitCast(b))));
    const a = popVal(mm).i64;
    return switch (op) {
        0x7C => a +% b,
        0x7D => a -% b,
        0x7E => a *% b,
        0x7F => {
            if (b == 0) return error.Div0;
            if (a == std.math.minInt(i64) and b == -1) return error.Div0;
            return @divTrunc(a, b);
        },
        0x80 => {
            if (b == 0) return error.Div0;
            return @intCast(@divTrunc(@as(u64, @bitCast(a)), @as(u64, @bitCast(b))));
        },
        0x81 => {
            if (b == 0) return error.Div0;
            return @rem(a, b);
        },
        0x82 => {
            if (b == 0) return error.Div0;
            return @intCast(@rem(@as(u64, @bitCast(a)), @as(u64, @bitCast(b))));
        },
        0x83 => a & b,
        0x84 => a | b,
        0x85 => a ^ b,
        0x86 => @bitCast(@as(u64, @bitCast(a)) << @as(u6, @truncate(@as(u64, @bitCast(b))))),
        0x87 => @bitCast(@as(i64, a) >> @as(u6, @truncate(@as(u64, @bitCast(b))))),
        0x88 => @bitCast(@as(u64, @bitCast(a)) >> @as(u6, @truncate(@as(u64, @bitCast(b))))),
        0x89 => rotl64(a, b),
        0x8A => rotr64(a, b),
        else => unreachable,
    };
}

fn rotl32(a: i32, b: i32) i32 {
    const n: u5 = @truncate(@as(u32, @bitCast(b)));
    const x = @as(u32, @bitCast(a));
    return @bitCast((x << n) | (x >> (~n +% 1)));
}

fn rotr32(a: i32, b: i32) i32 {
    const n: u5 = @truncate(@as(u32, @bitCast(b)));
    const x = @as(u32, @bitCast(a));
    return @bitCast((x >> n) | (x << (~n +% 1)));
}

fn rotl64(a: i64, b: i64) i64 {
    const n: u6 = @truncate(@as(u64, @bitCast(b)));
    const x = @as(u64, @bitCast(a));
    return @bitCast((x << n) | (x >> (~n +% 1)));
}

fn rotr64(a: i64, b: i64) i64 {
    const n: u6 = @truncate(@as(u64, @bitCast(b)));
    const x = @as(u64, @bitCast(a));
    return @bitCast((x >> n) | (x << (~n +% 1)));
}

// ---------------------------------------------------------------------------
// Guest entry (W1b: build marker; `wasm run` command lands in W2)
// ---------------------------------------------------------------------------
fn sys_write(buf: []const u8) i64 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> i64),
        : [num] "{x8}" (@as(u64, 1)),
          [fd] "{x0}" (@as(u64, 1)),
          [ptr] "{x1}" (@as(u64, @intFromPtr(buf.ptr))),
          [len] "{x2}" (@as(u64, buf.len)),
    );
}

fn console_puts(text: []const u8) void {
    if (text.len == 0) return;
    _ = sys_write(text);
}

fn sys_exit(status: u64) noreturn {
    asm volatile ("svc #0"
        :
        : [num] "{x8}" (@as(u64, 3)),
          [code] "{x0}" (status),
    );
    unreachable;
}

pub export fn _start(argc: usize, argv: ?[*]const [32]u8) callconv(.c) noreturn {
    // The `wasm run` command (module delivery through the file channel,
    // entry dispatch) is W2. W1b ships the interpreter core + host tests;
    // this marker is for the guest build/live gate.
    _ = argc;
    _ = argv;
    console_puts("wasm: W1b interpreter core built\n");
    sys_exit(0);
}

// ---------------------------------------------------------------------------
// Host tests
// ---------------------------------------------------------------------------
const testing = std.testing;

test "parse: rejects bad magic/version" {
    try testing.expectError(error.BadMagic, parse("AAAA"));
    try testing.expectError(error.BadVersion, parse("\x00asm\x02\x00\x00\x00"));
}

test "parse: rejects truncated and unknown sections" {
    try testing.expectError(error.Truncated, parse("\x00asm\x01\x00\x00\x00\x01\x0A"));
    try testing.expectError(error.UnknownSection, parse("\x00asm\x01\x00\x00\x00\x63\x00"));
}

test "validate: rejects f64 type (W4 float out of subset)" {
    // type section: one ( ) -> (f64) func type
    const bytes = "\x00\x61\x73\x6d\x01\x00\x00\x00\x01\x05\x01\x60\x00\x01\x7c";
    var m = try parse(bytes);
    try testing.expectError(error.FloatOutOfSubset, validate(&m));
}

test "exec: add module returns deterministic sums" {
    // (func (export "add3") (param i64 i64 i64) (result i64)
    //   local.get 0  local.get 1  i64.add  local.get 2  i64.add)
    // (module (type (;0;) (func (param i64 i64 i64) (result i64)))
    //   (func (;0;) (type 0) (param i64 i64 i64) (result i64)
    //     local.get 0  local.get 1  i64.add  local.get 2  i64.add)
    //   (export "add3" (func 0)))
    const bytes = "\x00\x61\x73\x6d\x01\x00\x00\x00\x01\x08\x01\x60\x03\x7e\x7e\x7e\x01\x7e\x03\x02\x01\x00\x07\x08\x01\x04\x61\x64\x64\x33\x00\x00\x0a\x0c\x01\x0a\x00\x20\x00\x20\x01\x7c\x20\x02\x7c\x0b";
    var m = try parse(bytes);
    try validate(&m);
    var store: [page_size]u8 = undefined;
    const inst = instantiate(&machine, &m, &store, "add3");
    try testing.expect(inst == null);
    const r = call(&machine, &m, 0, &.{ .{ .i64 = 2 }, .{ .i64 = 3 }, .{ .i64 = 4 } });
    try testing.expect(r == .ret);
    try testing.expectEqual(@as(i64, 9), r.ret.vals[0].i64);
    // deterministic: second run yields the same
    const r2 = call(&machine, &m, 0, &.{ .{ .i64 = 2 }, .{ .i64 = 3 }, .{ .i64 = 4 } });
    try testing.expect(r2 == .ret);
    try testing.expectEqual(@as(i64, 9), r2.ret.vals[0].i64);
}

test "exec: loop + br_if computes factorial" {
    // (func (export "fact") (param $n i64) (result i64)
    //   (local $acc i64) (local $i i64)
    //   i64.const 1  local.set 1        ;; acc = 1
    //   i64.const 1  local.set 2        ;; i = 1
    //   block
    //     loop
    //       local.get 2  local.get 0  i64.ge_u   ;; i >= n?
    //       br_if 1
    //       local.get 1  local.get 2  i64.mul  local.set 1   ;; acc *= i
    //       local.get 2  i64.const 1  i64.add  local.set 2   ;; i++
    //       br 0
    //     end
    //   end
    //   local.get 1)
    const bytes = "\x00\x61\x73\x6d\x01\x00\x00\x00\x01\x06\x01\x60\x01\x7e\x01\x7e\x03\x02\x01\x00\x07\x08\x01\x04\x66\x61\x63\x74\x00\x00\x0a\x2f\x01\x2d\x02\x01\x7e\x01\x7e\x42\x01\x21\x01\x42\x01\x21\x02\x02\x40\x03\x40\x20\x02\x20\x00\x56\x0d\x01\x20\x01\x20\x02\x7e\x21\x01\x20\x02\x42\x01\x7c\x21\x02\x0c\x00\x0b\x0b\x20\x01\x0b";
    var m = try parse(bytes);
    try validate(&m);
    var store: [page_size]u8 = undefined;
    try testing.expect(instantiate(&machine, &m, &store, "fact") == null);
    const r = call(&machine, &m, 0, &.{.{ .i64 = 5 }});
    try testing.expect(r == .ret);
    try testing.expectEqual(@as(i64, 120), r.ret.vals[0].i64);
    const r0 = call(&machine, &m, 0, &.{.{ .i64 = 0 }});
    try testing.expectEqual(@as(i64, 1), r0.ret.vals[0].i64);
}

test "exec: unreachable traps with module + offset" {
    // (func (export "boom") (unreachable))
    // (module (type (;0;) (func))
    //   (func (;0;) (type 0) unreachable)
    //   (export "boom" (func 0)))
    const bytes = "\x00\x61\x73\x6d\x01\x00\x00\x00\x01\x04\x01\x60\x00\x00\x03\x02\x01\x00\x07\x08\x01\x04\x62\x6f\x6f\x6d\x00\x00\x0a\x05\x01\x03\x00\x00\x0b";
    var m = try parse(bytes);
    try validate(&m);
    var store: [page_size]u8 = undefined;
    try testing.expect(instantiate(&machine, &m, &store, "boom") == null);
    const r = call(&machine, &m, 0, &.{});
    try testing.expect(r == .trap);
    try testing.expectEqual(TrapKind.@"unreachable", r.trap.kind);
    try testing.expectEqualStrings("boom", r.trap.module);
    try testing.expect(r.trap.offset > 0);
}

test "exec: div by zero traps (i32.div_s)" {
    // (func (export "div") (param i32 i32) (result i32)
    //   local.get 0  local.get 1  i32.div_s)
    const bytes = "\x00\x61\x73\x6d\x01\x00\x00\x00" ++
        "\x01\x07\x01\x60\x02\x7f\x7f\x01\x7f" ++
        "\x03\x02\x01\x00" ++
        "\x07\x07\x01\x03" ++ "div" ++ "\x00\x00" ++
        "\x0a\x09\x01\x07\x00\x20\x00\x20\x01\x6d\x0b";
    var m = try parse(bytes);
    try validate(&m);
    var store: [page_size]u8 = undefined;
    try testing.expect(instantiate(&machine, &m, &store, "div") == null);
    const r = call(&machine, &m, 0, &.{ .{ .i32 = 7 }, .{ .i32 = 0 } });
    try testing.expect(r == .trap);
    try testing.expectEqual(TrapKind.div_by_zero, r.trap.kind);
    const ok = call(&machine, &m, 0, &.{ .{ .i32 = 7 }, .{ .i32 = 2 } });
    try testing.expect(ok == .ret);
    try testing.expectEqual(@as(i32, 3), ok.ret.vals[0].i32);
}

test "exec: memory load/store round-trip and bounds trap" {
    // (func (export "store") (param i32 i64) local.get 0 local.get 1 i64.store)
    // (func (export "load") (param i32) (result i64) local.get 0 i64.load)
    const bytes = "\x00\x61\x73\x6d\x01\x00\x00\x00\x01\x0b\x02\x60\x02\x7f\x7e\x00\x60\x01\x7f\x01\x7e\x03\x03\x02\x00\x01\x05\x03\x01\x00\x01\x07\x10\x02\x05\x73\x74\x6f\x72\x65\x00\x00\x04\x6c\x6f\x61\x64\x00\x01\x0a\x13\x02\x09\x00\x20\x00\x20\x01\x37\x01\x00\x0b\x07\x00\x20\x00\x29\x03\x00\x0b";
    var m = try parse(bytes);
    try validate(&m);
    var store: [2 * page_size]u8 = undefined;
    try testing.expect(instantiate(&machine, &m, &store, "mem") == null);
    const s = call(&machine, &m, 0, &.{ .{ .i32 = 100 }, .{ .i64 = 0xDEAD_BEEF } });
    try testing.expect(s == .ret);
    const l = call(&machine, &m, 1, &.{.{ .i32 = 100 }});
    try testing.expect(l == .ret);
    try testing.expectEqual(@as(i64, 0xDEAD_BEEF), l.ret.vals[0].i64);
    // bounds trap: 8-byte load at 65530 straddles the 1-page (65536) end.
    // (65528 would be exactly in-bounds: 65528+8 == 65536.)
    const bo = call(&machine, &m, 1, &.{.{ .i32 = 65530 }});
    try testing.expect(bo == .trap);
    try testing.expectEqual(TrapKind.bounds, bo.trap.kind);
}

test "exec: memory.grow within cap, traps beyond (no unbounded mmap)" {
    // (func (export "grow") (param i32) (result i32) local.get 0 memory.grow)
    const bytes = "\x00\x61\x73\x6d\x01\x00\x00\x00\x01\x06\x01\x60\x01\x7f\x01\x7f\x03\x02\x01\x00\x05\x04\x01\x01\x01\x02\x07\x08\x01\x04\x67\x72\x6f\x77\x00\x00\x0a\x08\x01\x06\x00\x20\x00\x40\x00\x0b";
    var m = try parse(bytes);
    try validate(&m);
    var store: [page_size]u8 = undefined; // only 1 page of backing
    try testing.expect(instantiate(&machine, &m, &store, "grow") == null);
    try testing.expectEqual(@as(u32, 1), machine.mem_pages);
    // grow(0) returns current pages (spec behavior)
    const g0 = call(&machine, &m, 0, &.{.{ .i32 = 0 }});
    try testing.expect(g0 == .ret);
    try testing.expectEqual(@as(i32, 1), g0.ret.vals[0].i32);
    // grow(1) exceeds max(2) pages of backing store => trap
    const g1 = call(&machine, &m, 0, &.{.{ .i32 = 1 }});
    try testing.expect(g1 == .trap);
    try testing.expectEqual(TrapKind.grow_limit, g1.trap.kind);
}

test "exec: call_indirect type-check traps on mismatch" {
    // types: 0 (i64)->i64, 1 ()->()
    // func 0: (export "f") (i64)->i64 { local.get 0 i64.const 1 i64.add }
    // func 1: (export "g") ()->() {}
    // table 1 funcref (min 2), element: [func 0, func 1]
    // (export "callit") (param i32 i64) (result i64) {
    //   local.get 1  local.get 0  call_indirect (type 0) }
    const bytes = "\x00\x61\x73\x6d\x01\x00\x00\x00\x01\x0f\x03\x60\x01\x7e\x01\x7e\x60\x00\x00\x60\x02\x7f\x7e\x01\x7e\x03\x04\x03\x00\x01\x02\x04\x04\x01\x70\x00\x02\x07\x12\x03\x01\x66\x00\x00\x01\x67\x00\x01\x06\x63\x61\x6c\x6c\x69\x74\x00\x02\x09\x08\x01\x00\x41\x00\x0b\x02\x00\x01\x0a\x16\x03\x07\x00\x20\x00\x42\x01\x7c\x0b\x02\x00\x0b\x09\x00\x20\x01\x20\x00\x11\x00\x00\x0b";
    var m = try parse(bytes);
    try validate(&m);
    var store: [page_size]u8 = undefined;
    try testing.expect(instantiate(&machine, &m, &store, "ci") == null);
    // table[0] = func 0 (i64)->(i64): call with type 0 succeeds
    const ok = call(&machine, &m, 2, &.{ .{ .i32 = 0 }, .{ .i64 = 41 } });
    try testing.expect(ok == .ret);
    try testing.expectEqual(@as(i64, 42), ok.ret.vals[0].i64);
    // table[1] = func 1 ()->(): type 0 expected -> mismatch trap
    const bad = call(&machine, &m, 2, &.{ .{ .i32 = 1 }, .{ .i64 = 0 } });
    try testing.expect(bad == .trap);
    try testing.expectEqual(TrapKind.call_indirect_type, bad.trap.kind);
    // table index OOB traps bounds
    const oob = call(&machine, &m, 2, &.{ .{ .i32 = 5 }, .{ .i64 = 0 } });
    try testing.expect(oob == .trap);
    try testing.expectEqual(TrapKind.bounds, oob.trap.kind);
}

test "corpus: hand-built fixture executes deterministically (byte-identical output)" {
    // The committed corpus module: user/src/wasm-corpus/fib-loop.wasm — the
    // same loop+br_if structure as the factorial test, selected by the
    // fixture README. This test loads it through @embedFile and runs it
    // twice, asserting identical results.
    const fixture = @embedFile("wasm-corpus/fib-loop.wasm");
    var m = try parse(fixture);
    try validate(&m);
    var store: [page_size]u8 = undefined;
    try testing.expect(instantiate(&machine, &m, &store, "fib-loop") == null);
    const a = call(&machine, &m, 0, &.{.{ .i64 = 7 }});
    const b = call(&machine, &m, 0, &.{.{ .i64 = 7 }});
    try testing.expect(a == .ret and b == .ret);
    try testing.expectEqual(a.ret.vals[0].i64, b.ret.vals[0].i64);
    try testing.expectEqual(@as(i64, 5040), a.ret.vals[0].i64); // 7!
}
