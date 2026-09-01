//! The in-guest compiler (zc): compiles a Zig subset to AArch64 ELF32.
//! Bounded: <=32 functions, <=512 lines, zero heap.
//!
//! Usage: exec ZC.BIN <source.z> [<output.elf>]

const std = @import("std");
const asmenc = @import("lib/asmenc.zig");

// Encoders and constants from asmenc
const enc_movz = asmenc.enc_movz;
const enc_movk = asmenc.enc_movk;
const enc_mov_reg = asmenc.enc_mov_reg;
const enc_add_imm = asmenc.enc_add_imm;
const enc_add_reg = asmenc.enc_add_reg;
const enc_sub_imm = asmenc.enc_sub_imm;
const enc_sub_reg = asmenc.enc_sub_reg;
const enc_cmp_imm = asmenc.enc_cmp_imm;
const enc_cmp_reg = asmenc.enc_cmp_reg;
const enc_and_reg = asmenc.enc_and_reg;
const enc_orr_reg = asmenc.enc_orr_reg;
const enc_eor_reg = asmenc.enc_eor_reg;
const enc_b = asmenc.enc_b;
const enc_bl = asmenc.enc_bl;
const enc_b_cond = asmenc.enc_b_cond;
const enc_ldr = asmenc.enc_ldr;
const enc_str = asmenc.enc_str;
const enc_ldrb = asmenc.enc_ldrb;
const enc_strb = asmenc.enc_strb;
const enc_ret = asmenc.enc_ret;
const enc_svc = asmenc.enc_svc;
const enc_mul = asmenc.enc_mul;
const enc_udiv = asmenc.enc_udiv;
const enc_lsl = asmenc.enc_lsl;
const enc_lsr = asmenc.enc_lsr;
const enc_lsl_reg = asmenc.enc_lsl_reg;
const enc_lsr_reg = asmenc.enc_lsr_reg;
const enc_adr = asmenc.enc_adr;
const build_elf32 = asmenc.build_elf32;
const build_elf32_with_data = asmenc.build_elf32_with_data;
const elf_code_offset = asmenc.elf_code_offset;

// ---------------------------------------------------------------------------
// EL0 syscall seam
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

fn append_str(buf: []u8, pos: usize, src: []const u8) usize {
    const take = @min(src.len, buf.len - pos);
    @memcpy(buf[pos .. pos + take], src[0..take]);
    return pos + take;
}

fn fmt_u64(buf: []u8, value: u64) []const u8 {
    var v = value;
    var i: usize = buf.len;
    if (v == 0) {
        i -= 1;
        buf[i] = '0';
        return buf[i..];
    }
    while (v > 0) : (v /= 10) {
        i -= 1;
        buf[i] = @intCast('0' + (v % 10));
    }
    return buf[i..];
}

fn print_err(msg: []const u8, line: usize, detail: []const u8) void {
    var buf: [128]u8 = undefined;
    var pos: usize = 0;
    pos = append_str(&buf, pos, "Compile error at line ");
    var num_buf: [20]u8 = undefined;
    pos = append_str(&buf, pos, fmt_u64(&num_buf, line));
    pos = append_str(&buf, pos, ": ");
    pos = append_str(&buf, pos, msg);
    if (detail.len > 0) {
        pos = append_str(&buf, pos, " '");
        pos = append_str(&buf, pos, detail);
        pos = append_str(&buf, pos, "'");
    }
    pos = append_str(&buf, pos, "\n");
    console_puts(buf[0..pos]);
}

fn sys_exit(status: u64) noreturn {
    asm volatile ("svc #0"
        :
        : [num] "{x8}" (@as(u64, 3)),
          [code] "{x0}" (status),
    );
    unreachable;
}

const MODE_READ: u32 = 0x1;
const MODE_WRITE: u32 = 0x2;
const MODE_CREATE: u32 = 0x4;

fn file_open(path: []const u8, flags: u32) i64 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> i64),
        : [num] "{x8}" (@as(u64, 23)),
          [p] "{x0}" (@as(u64, @intFromPtr(path.ptr))),
          [l] "{x1}" (@as(u64, path.len)),
          [f] "{x2}" (@as(u64, flags)),
    );
}

fn file_read(fd: u32, buf: []u8) i64 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> i64),
        : [num] "{x8}" (@as(u64, 24)),
          [h] "{x0}" (@as(u64, fd)),
          [p] "{x1}" (@as(u64, @intFromPtr(buf.ptr))),
          [n] "{x2}" (@as(u64, buf.len)),
    );
}

fn file_write(fd: u32, buf: []const u8) i64 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> i64),
        : [num] "{x8}" (@as(u64, 25)),
          [h] "{x0}" (@as(u64, fd)),
          [p] "{x1}" (@as(u64, @intFromPtr(buf.ptr))),
          [n] "{x2}" (@as(u64, buf.len)),
    );
}

fn file_close(fd: u32) void {
    asm volatile ("svc #0"
        :
        : [num] "{x8}" (@as(u64, 26)),
          [h] "{x0}" (@as(u64, fd)),
    );
}

// ---------------------------------------------------------------------------
// Lexer
// ---------------------------------------------------------------------------
const TokenKind = enum {
    eof,
    invalid,
    keyword_fn,
    keyword_pub,
    keyword_let,
    keyword_var,
    keyword_const,
    keyword_if,
    keyword_else,
    keyword_while,
    keyword_return,
    ident,
    number,
    string_lit,
    char_lit,
    dot,
    at,
    l_paren,
    r_paren,
    l_brace,
    r_brace,
    l_bracket,
    r_bracket,
    comma,
    semicolon,
    colon,
    equal,
    plus,
    minus,
    star,
    slash,
    percent,
    ampersand,
    pipe,
    caret,
    excl,
    double_equal,
    excl_equal,
    less,
    less_equal,
    greater,
    greater_equal,
    less_less,
    greater_greater,
    double_ampersand,
    double_pipe,
};

const Token = struct {
    kind: TokenKind,
    text: []const u8,
    line: usize,
};

const Tokenizer = struct {
    src: []const u8,
    pos: usize = 0,
    line: usize = 1,

    fn next(self: *Tokenizer) Token {
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (c == '\n') {
                self.pos += 1;
                self.line += 1;
                continue;
            }
            if (std.ascii.isWhitespace(c)) {
                self.pos += 1;
                continue;
            }
            if (c == '/' and self.pos + 1 < self.src.len and self.src[self.pos + 1] == '/') {
                while (self.pos < self.src.len and self.src[self.pos] != '\n') self.pos += 1;
                continue;
            }
            break;
        }
        if (self.pos >= self.src.len) return Token{ .kind = .eof, .text = "", .line = self.line };

        const start = self.pos;
        const c = self.src[self.pos];
        self.pos += 1;

        switch (c) {
            '.' => return Token{ .kind = .dot, .text = self.src[start..self.pos], .line = self.line },
            '@' => return Token{ .kind = .at, .text = self.src[start..self.pos], .line = self.line },
            '(' => return Token{ .kind = .l_paren, .text = self.src[start..self.pos], .line = self.line },
            ')' => return Token{ .kind = .r_paren, .text = self.src[start..self.pos], .line = self.line },
            '{' => return Token{ .kind = .l_brace, .text = self.src[start..self.pos], .line = self.line },
            '}' => return Token{ .kind = .r_brace, .text = self.src[start..self.pos], .line = self.line },
            '[' => return Token{ .kind = .l_bracket, .text = self.src[start..self.pos], .line = self.line },
            ']' => return Token{ .kind = .r_bracket, .text = self.src[start..self.pos], .line = self.line },
            ',' => return Token{ .kind = .comma, .text = self.src[start..self.pos], .line = self.line },
            ';' => return Token{ .kind = .semicolon, .text = self.src[start..self.pos], .line = self.line },
            ':' => return Token{ .kind = .colon, .text = self.src[start..self.pos], .line = self.line },
            '+' => return Token{ .kind = .plus, .text = self.src[start..self.pos], .line = self.line },
            '-' => return Token{ .kind = .minus, .text = self.src[start..self.pos], .line = self.line },
            '*' => return Token{ .kind = .star, .text = self.src[start..self.pos], .line = self.line },
            '/' => return Token{ .kind = .slash, .text = self.src[start..self.pos], .line = self.line },
            '%' => return Token{ .kind = .percent, .text = self.src[start..self.pos], .line = self.line },
            '^' => return Token{ .kind = .caret, .text = self.src[start..self.pos], .line = self.line },
            '&' => {
                if (self.pos < self.src.len and self.src[self.pos] == '&') {
                    self.pos += 1;
                    return Token{ .kind = .double_ampersand, .text = self.src[start..self.pos], .line = self.line };
                }
                return Token{ .kind = .ampersand, .text = self.src[start..self.pos], .line = self.line };
            },
            '|' => {
                if (self.pos < self.src.len and self.src[self.pos] == '|') {
                    self.pos += 1;
                    return Token{ .kind = .double_pipe, .text = self.src[start..self.pos], .line = self.line };
                }
                return Token{ .kind = .pipe, .text = self.src[start..self.pos], .line = self.line };
            },
            '!' => {
                if (self.pos < self.src.len and self.src[self.pos] == '=') {
                    self.pos += 1;
                    return Token{ .kind = .excl_equal, .text = self.src[start..self.pos], .line = self.line };
                }
                return Token{ .kind = .excl, .text = self.src[start..self.pos], .line = self.line };
            },
            '=' => {
                if (self.pos < self.src.len and self.src[self.pos] == '=') {
                    self.pos += 1;
                    return Token{ .kind = .double_equal, .text = self.src[start..self.pos], .line = self.line };
                }
                return Token{ .kind = .equal, .text = self.src[start..self.pos], .line = self.line };
            },
            '<' => {
                if (self.pos < self.src.len and self.src[self.pos] == '=') {
                    self.pos += 1;
                    return Token{ .kind = .less_equal, .text = self.src[start..self.pos], .line = self.line };
                }
                if (self.pos < self.src.len and self.src[self.pos] == '<') {
                    self.pos += 1;
                    return Token{ .kind = .less_less, .text = self.src[start..self.pos], .line = self.line };
                }
                return Token{ .kind = .less, .text = self.src[start..self.pos], .line = self.line };
            },
            '>' => {
                if (self.pos < self.src.len and self.src[self.pos] == '=') {
                    self.pos += 1;
                    return Token{ .kind = .greater_equal, .text = self.src[start..self.pos], .line = self.line };
                }
                if (self.pos < self.src.len and self.src[self.pos] == '>') {
                    self.pos += 1;
                    return Token{ .kind = .greater_greater, .text = self.src[start..self.pos], .line = self.line };
                }
                return Token{ .kind = .greater, .text = self.src[start..self.pos], .line = self.line };
            },
            '"' => {
                while (self.pos < self.src.len and self.src[self.pos] != '"') {
                    if (self.pos + 1 < self.src.len and self.src[self.pos] == '\\') self.pos += 1;
                    self.pos += 1;
                }
                if (self.pos < self.src.len and self.src[self.pos] == '"') {
                    self.pos += 1;
                    return Token{ .kind = .string_lit, .text = self.src[start..self.pos], .line = self.line };
                }
                return Token{ .kind = .invalid, .text = self.src[start..self.pos], .line = self.line };
            },
            '\'' => {
                if (self.pos < self.src.len and self.src[self.pos] != '\'') {
                    self.pos += 1;
                    if (self.pos < self.src.len and self.src[self.pos] == '\'') {
                        self.pos += 1;
                        return Token{ .kind = .char_lit, .text = self.src[start..self.pos], .line = self.line };
                    }
                }
                return Token{ .kind = .invalid, .text = self.src[start..self.pos], .line = self.line };
            },
            else => {
                if (std.ascii.isAlphabetic(c) or c == '_') {
                    while (self.pos < self.src.len and (std.ascii.isAlphanumeric(self.src[self.pos]) or self.src[self.pos] == '_')) self.pos += 1;
                    const text = self.src[start..self.pos];
                    if (std.mem.eql(u8, text, "pub")) return Token{ .kind = .keyword_pub, .text = text, .line = self.line };
                    if (std.mem.eql(u8, text, "fn")) return Token{ .kind = .keyword_fn, .text = text, .line = self.line };
                    if (std.mem.eql(u8, text, "let")) return Token{ .kind = .keyword_let, .text = text, .line = self.line };
                    if (std.mem.eql(u8, text, "var")) return Token{ .kind = .keyword_var, .text = text, .line = self.line };
                    if (std.mem.eql(u8, text, "const")) return Token{ .kind = .keyword_const, .text = text, .line = self.line };
                    if (std.mem.eql(u8, text, "if")) return Token{ .kind = .keyword_if, .text = text, .line = self.line };
                    if (std.mem.eql(u8, text, "else")) return Token{ .kind = .keyword_else, .text = text, .line = self.line };
                    if (std.mem.eql(u8, text, "while")) return Token{ .kind = .keyword_while, .text = text, .line = self.line };
                    if (std.mem.eql(u8, text, "return")) return Token{ .kind = .keyword_return, .text = text, .line = self.line };
                    return Token{ .kind = .ident, .text = text, .line = self.line };
                }
                if (std.ascii.isDigit(c)) {
                    if (c == '0' and self.pos < self.src.len and (self.src[self.pos] == 'x' or self.src[self.pos] == 'X')) {
                        self.pos += 1;
                        while (self.pos < self.src.len and std.ascii.isHex(self.src[self.pos])) self.pos += 1;
                    } else {
                        while (self.pos < self.src.len and std.ascii.isDigit(self.src[self.pos])) self.pos += 1;
                    }
                    return Token{ .kind = .number, .text = self.src[start..self.pos], .line = self.line };
                }
                return Token{ .kind = .invalid, .text = self.src[start..self.pos], .line = self.line };
            },
        }
    }
};

// ---------------------------------------------------------------------------
// Compiler State & Symbols
// ---------------------------------------------------------------------------
const Function = struct {
    name: []const u8,
    address: u32,
    param_count: usize,
};

const LocalVar = struct {
    name: []const u8,
    offset: usize,
    is_array: bool = false,
    array_len: usize = 0,
    elem_size: usize = 8,
};

const CallPatch = struct {
    caller_pc: u32,
    target_func_idx: usize,
};

var code: [32768]u8 = undefined;
var code_len: usize = 0;

var data_buf: [32768]u8 = undefined;
var data_len: usize = 0;

const StringPatch = struct {
    code_pc: usize,
    data_off: usize,
    rd: u5,
};

var string_patches: [256]StringPatch = undefined;
var string_patches_count: usize = 0;

var tokens_buf: [2048]Token = undefined;
var tokens_count: usize = 0;

var functions: [32]Function = undefined;
var functions_count: usize = 0;

var locals: [64]LocalVar = undefined;
var locals_count: usize = 0;
var frame_size: usize = 0;

var call_patches: [64]CallPatch = undefined;
var call_patches_count: usize = 0;

fn emit(word: u32) void {
    std.mem.writeInt(u32, code[code_len..][0..4], word, .little);
    code_len += 4;
}

fn unescape_string(raw: []const u8, out: []u8) usize {
    if (raw.len < 2 or raw[0] != '"' or raw[raw.len - 1] != '"') return 0;
    const content = raw[1 .. raw.len - 1];
    var out_idx: usize = 0;
    var i: usize = 0;
    while (i < content.len and out_idx < out.len) {
        if (content[i] == '\\' and i + 1 < content.len) {
            i += 1;
            switch (content[i]) {
                'n' => {
                    out[out_idx] = '\n';
                    out_idx += 1;
                },
                'r' => {
                    out[out_idx] = '\r';
                    out_idx += 1;
                },
                't' => {
                    out[out_idx] = '\t';
                    out_idx += 1;
                },
                '0' => {
                    out[out_idx] = 0;
                    out_idx += 1;
                },
                '\\' => {
                    out[out_idx] = '\\';
                    out_idx += 1;
                },
                '"' => {
                    out[out_idx] = '"';
                    out_idx += 1;
                },
                '\'' => {
                    out[out_idx] = '\'';
                    out_idx += 1;
                },
                else => {
                    out[out_idx] = content[i];
                    out_idx += 1;
                },
            }
        } else {
            out[out_idx] = content[i];
            out_idx += 1;
        }
        i += 1;
    }
    return out_idx;
}

fn addString(raw: []const u8) anyerror!struct { off: usize, len: usize } {
    var tmp: [4096]u8 = undefined;
    const unescaped_len = unescape_string(raw, &tmp);
    if (data_len + unescaped_len > data_buf.len) return error.CompileError;
    const off = data_len;
    @memcpy(data_buf[off .. off + unescaped_len], tmp[0..unescaped_len]);
    data_len += unescaped_len;
    return .{ .off = off, .len = unescaped_len };
}

fn emitStringAdr(rd: u5, data_off: usize) void {
    string_patches[string_patches_count] = StringPatch{
        .code_pc = code_len,
        .data_off = data_off,
        .rd = rd,
    };
    string_patches_count += 1;
    emit(0);
}

fn emitLoadImmediate(rd: u5, val: u64) void {
    const v0: u16 = @intCast(val & 0xFFFF);
    const v1: u16 = @intCast((val >> 16) & 0xFFFF);
    const v2: u16 = @intCast((val >> 32) & 0xFFFF);
    const v3: u16 = @intCast((val >> 48) & 0xFFFF);
    emit(enc_movz(rd, v0, 0));
    if (v1 != 0 or v2 != 0 or v3 != 0) emit(enc_movk(rd, v1, 1));
    if (v2 != 0 or v3 != 0) emit(enc_movk(rd, v2, 2));
    if (v3 != 0) emit(enc_movk(rd, v3, 3));
}

fn elemShift(elem_size: usize) u6 {
    return switch (elem_size) {
        1 => 0,
        2 => 1,
        4 => 2,
        8 => 3,
        else => 0,
    };
}

fn lookupFunc(name: []const u8) ?usize {
    var i: usize = 0;
    while (i < functions_count) : (i += 1) {
        if (std.mem.eql(u8, functions[i].name, name)) return i;
    }
    return null;
}

fn lookupLocal(name: []const u8) ?usize {
    var i: usize = locals_count;
    while (i > 0) {
        i -= 1;
        if (std.mem.eql(u8, locals[i].name, name)) return locals[i].offset;
    }
    return null;
}

fn lookupLocalVar(name: []const u8) ?*LocalVar {
    var i: usize = locals_count;
    while (i > 0) {
        i -= 1;
        if (std.mem.eql(u8, locals[i].name, name)) return &locals[i];
    }
    return null;
}

fn registerForwardFunc(name: []const u8) !usize {
    if (lookupFunc(name)) |idx| return idx;
    if (functions_count >= functions.len) return error.TooManyFunctions;
    functions[functions_count] = Function{ .name = name, .address = 0, .param_count = 0 };
    const idx = functions_count;
    functions_count += 1;
    return idx;
}

// ---------------------------------------------------------------------------
// Parser
// ---------------------------------------------------------------------------
const Parser = struct {
    tokens: []const Token,
    idx: usize = 0,

    fn peek(self: *Parser) TokenKind {
        if (self.idx >= self.tokens.len) return .eof;
        return self.tokens[self.idx].kind;
    }

    fn currentToken(self: *Parser) Token {
        if (self.idx >= self.tokens.len) return Token{ .kind = .eof, .text = "", .line = 0 };
        return self.tokens[self.idx];
    }

    fn advance(self: *Parser) Token {
        const t = self.currentToken();
        self.idx += 1;
        return t;
    }

    fn expect(self: *Parser, kind: TokenKind) anyerror!Token {
        const t = self.currentToken();
        if (t.kind != kind) {
            print_err("unexpected token", t.line, t.text);
            return error.CompileError;
        }
        self.idx += 1;
        return t;
    }

    fn accept(self: *Parser, kind: TokenKind) bool {
        if (self.peek() == kind) {
            self.idx += 1;
            return true;
        }
        return false;
    }
};

fn countParams(tokens: []const Token, start_idx: usize) usize {
    var idx = start_idx;
    if (tokens[idx].kind == .r_paren) return 0;
    var commas: usize = 0;
    while (idx < tokens.len and tokens[idx].kind != .r_paren) : (idx += 1) {
        if (tokens[idx].kind == .comma) commas += 1;
    }
    return commas + 1;
}

fn compileExpr(p: *Parser) anyerror!void {
    try parseLogicalOr(p);
}

fn parseLogicalOr(p: *Parser) anyerror!void {
    try parseLogicalAnd(p);
    while (p.accept(.double_pipe)) {
        emit(enc_sub_imm(31, 31, 16));
        emit(enc_str(31, 0, 0));
        try parseLogicalAnd(p);
        emit(enc_ldr(31, 1, 0));
        emit(enc_add_imm(31, 31, 16));
        emit(enc_orr_reg(1, 0, 0));
    }
}

fn parseLogicalAnd(p: *Parser) anyerror!void {
    try parseBitwiseOr(p);
    while (p.accept(.double_ampersand)) {
        emit(enc_sub_imm(31, 31, 16));
        emit(enc_str(31, 0, 0));
        try parseBitwiseOr(p);
        emit(enc_ldr(31, 1, 0));
        emit(enc_add_imm(31, 31, 16));
        emit(enc_and_reg(1, 0, 0));
    }
}

fn parseBitwiseOr(p: *Parser) anyerror!void {
    try parseBitwiseXor(p);
    while (p.accept(.pipe)) {
        emit(enc_sub_imm(31, 31, 16));
        emit(enc_str(31, 0, 0));
        try parseBitwiseXor(p);
        emit(enc_ldr(31, 1, 0));
        emit(enc_add_imm(31, 31, 16));
        emit(enc_orr_reg(1, 0, 0));
    }
}

fn parseBitwiseXor(p: *Parser) anyerror!void {
    try parseBitwiseAnd(p);
    while (p.accept(.caret)) {
        emit(enc_sub_imm(31, 31, 16));
        emit(enc_str(31, 0, 0));
        try parseBitwiseAnd(p);
        emit(enc_ldr(31, 1, 0));
        emit(enc_add_imm(31, 31, 16));
        emit(enc_eor_reg(1, 0, 0));
    }
}

fn parseBitwiseAnd(p: *Parser) anyerror!void {
    try parseEquality(p);
    while (p.accept(.ampersand)) {
        emit(enc_sub_imm(31, 31, 16));
        emit(enc_str(31, 0, 0));
        try parseEquality(p);
        emit(enc_ldr(31, 1, 0));
        emit(enc_add_imm(31, 31, 16));
        emit(enc_and_reg(1, 0, 0));
    }
}

fn parseEquality(p: *Parser) anyerror!void {
    try parseRelational(p);
    while (true) {
        const is_eq = p.accept(.double_equal);
        const is_ne = !is_eq and p.accept(.excl_equal);
        if (!is_eq and !is_ne) break;
        emit(enc_sub_imm(31, 31, 16));
        emit(enc_str(31, 0, 0));
        try parseRelational(p);
        emit(enc_ldr(31, 1, 0));
        emit(enc_add_imm(31, 31, 16));
        emit(enc_cmp_reg(1, 0));
        if (is_eq) {
            emit(enc_b_cond(.eq, 12));
        } else {
            emit(enc_b_cond(.ne, 12));
        }
        emit(enc_movz(0, 0, 0));
        emit(enc_b(8));
        emit(enc_movz(0, 1, 0));
    }
}

fn parseRelational(p: *Parser) anyerror!void {
    try parseShift(p);
    while (true) {
        const is_lt = p.accept(.less);
        const is_le = !is_lt and p.accept(.less_equal);
        const is_gt = !is_lt and !is_le and p.accept(.greater);
        const is_ge = !is_lt and !is_le and !is_gt and p.accept(.greater_equal);
        if (!is_lt and !is_le and !is_gt and !is_ge) break;
        emit(enc_sub_imm(31, 31, 16));
        emit(enc_str(31, 0, 0));
        try parseShift(p);
        emit(enc_ldr(31, 1, 0));
        emit(enc_add_imm(31, 31, 16));
        emit(enc_cmp_reg(1, 0));
        if (is_lt) {
            emit(enc_b_cond(.lt, 12));
        } else if (is_le) {
            emit(enc_b_cond(.le, 12));
        } else if (is_gt) {
            emit(enc_b_cond(.gt, 12));
        } else {
            emit(enc_b_cond(.ge, 12));
        }
        emit(enc_movz(0, 0, 0));
        emit(enc_b(8));
        emit(enc_movz(0, 1, 0));
    }
}

fn parseShift(p: *Parser) anyerror!void {
    try parseAdditive(p);
    while (true) {
        const is_lsl = p.accept(.less_less);
        const is_lsr = !is_lsl and p.accept(.greater_greater);
        if (!is_lsl and !is_lsr) break;
        emit(enc_sub_imm(31, 31, 16));
        emit(enc_str(31, 0, 0));
        try parseAdditive(p);
        emit(enc_ldr(31, 1, 0));
        emit(enc_add_imm(31, 31, 16));
        if (is_lsl) {
            emit(enc_lsl_reg(1, 0, 0));
        } else {
            emit(enc_lsr_reg(1, 0, 0));
        }
    }
}

fn parseAdditive(p: *Parser) anyerror!void {
    try parseMultiplicative(p);
    while (true) {
        const is_add = p.accept(.plus);
        const is_sub = !is_add and p.accept(.minus);
        if (!is_add and !is_sub) break;
        emit(enc_sub_imm(31, 31, 16));
        emit(enc_str(31, 0, 0));
        try parseMultiplicative(p);
        emit(enc_ldr(31, 1, 0));
        emit(enc_add_imm(31, 31, 16));
        if (is_add) {
            emit(enc_add_reg(1, 0, 0));
        } else {
            emit(enc_sub_reg(1, 0, 0));
        }
    }
}

fn parseMultiplicative(p: *Parser) anyerror!void {
    try parseUnary(p);
    while (true) {
        const is_mul = p.accept(.star);
        const is_div = !is_mul and p.accept(.slash);
        if (!is_mul and !is_div) break;
        emit(enc_sub_imm(31, 31, 16));
        emit(enc_str(31, 0, 0));
        try parseUnary(p);
        emit(enc_ldr(31, 1, 0));
        emit(enc_add_imm(31, 31, 16));
        if (is_mul) {
            emit(enc_mul(1, 0, 0));
        } else {
            emit(enc_udiv(1, 0, 0));
        }
    }
}

fn parseUnary(p: *Parser) anyerror!void {
    if (p.accept(.minus)) {
        try parseUnary(p);
        emit(enc_sub_reg(31, 0, 0));
    } else if (p.accept(.excl)) {
        try parseUnary(p);
        emit(enc_cmp_imm(0, 0));
        emit(enc_b_cond(.eq, 12));
        emit(enc_movz(0, 0, 0));
        emit(enc_b(8));
        emit(enc_movz(0, 1, 0));
    } else {
        try parsePrimary(p);
    }
}

fn parsePrimary(p: *Parser) anyerror!void {
    const t = p.advance();
    switch (t.kind) {
        .number => {
            const val = std.fmt.parseInt(u64, t.text, 0) catch return error.CompileError;
            emitLoadImmediate(0, val);
        },
        .char_lit => {
            const val = t.text[1];
            emitLoadImmediate(0, val);
        },
        .string_lit => {
            const res = try addString(t.text);
            emitStringAdr(0, res.off);
            emit(enc_movz(1, @intCast(res.len), 0));
        },
        .ident => {
            if (p.accept(.dot)) {
                const member_tok = try p.expect(.ident);
                if (std.mem.eql(u8, t.text, "zc")) {
                    if (std.mem.eql(u8, member_tok.text, "print")) {
                        _ = try p.expect(.l_paren);
                        if (p.peek() == .string_lit) {
                            const str_tok = p.advance();
                            const res = try addString(str_tok.text);
                            emit(enc_movz(0, 1, 0)); // stdout fd = 1
                            emitStringAdr(1, res.off); // x1 = ptr
                            emit(enc_movz(2, @intCast(res.len), 0)); // x2 = len
                            emit(enc_movz(8, 1, 0)); // sys_write
                            emit(enc_svc(0));
                        } else {
                            try compileExpr(p);
                            emit(enc_mov_reg(2, 1));
                            emit(enc_mov_reg(1, 0));
                            emit(enc_movz(0, 1, 0));
                            emit(enc_movz(8, 1, 0));
                            emit(enc_svc(0));
                        }
                        _ = try p.expect(.r_paren);
                    } else if (std.mem.eql(u8, member_tok.text, "exit")) {
                        _ = try p.expect(.l_paren);
                        try compileExpr(p);
                        _ = try p.expect(.r_paren);
                        emit(enc_movz(8, 3, 0));
                        emit(enc_svc(0));
                    } else if (std.mem.eql(u8, member_tok.text, "write")) {
                        _ = try p.expect(.l_paren);
                        try compileExpr(p); // fd into x0
                        _ = try p.expect(.comma);
                        if (p.peek() == .string_lit) {
                            const str_tok = p.advance();
                            const res = try addString(str_tok.text);
                            emit(enc_sub_imm(31, 31, 16));
                            emit(enc_str(31, 0, 0)); // save fd
                            emitStringAdr(1, res.off); // ptr into x1
                            emit(enc_movz(2, @intCast(res.len), 0)); // len into x2
                            emit(enc_ldr(31, 0, 0)); // restore fd
                            emit(enc_add_imm(31, 31, 16));
                            emit(enc_movz(8, 1, 0)); // sys_write
                            emit(enc_svc(0));
                        } else {
                            emit(enc_sub_imm(31, 31, 16));
                            emit(enc_str(31, 0, 0)); // save fd on stack
                            try compileExpr(p); // evaluates 2nd arg into x0
                            if (p.accept(.comma)) {
                                emit(enc_sub_imm(31, 31, 16));
                                emit(enc_str(31, 0, 0)); // save 2nd arg on stack
                                try compileExpr(p); // evaluates 3rd arg into x0
                                emit(enc_mov_reg(2, 0)); // len -> x2
                                emit(enc_ldr(31, 1, 0)); // restore 2nd arg (ptr) -> x1
                                emit(enc_add_imm(31, 31, 16));
                                emit(enc_ldr(31, 0, 0)); // restore 1st arg (fd) -> x0
                                emit(enc_add_imm(31, 31, 16));
                            } else {
                                emit(enc_mov_reg(2, 1));
                                emit(enc_mov_reg(1, 0));
                                emit(enc_ldr(31, 0, 0));
                                emit(enc_add_imm(31, 31, 16));
                            }
                            emit(enc_movz(8, 1, 0));
                            emit(enc_svc(0));
                        }
                        _ = try p.expect(.r_paren);
                    } else if (std.mem.eql(u8, member_tok.text, "yield")) {
                        _ = try p.expect(.l_paren);
                        _ = try p.expect(.r_paren);
                        emit(enc_movz(8, 2, 0));
                        emit(enc_svc(0));
                    } else if (std.mem.eql(u8, member_tok.text, "sleep")) {
                        _ = try p.expect(.l_paren);
                        try compileExpr(p);
                        _ = try p.expect(.r_paren);
                        emit(enc_movz(8, 4, 0));
                        emit(enc_svc(0));
                    } else if (std.mem.eql(u8, member_tok.text, "file_open")) {
                        _ = try p.expect(.l_paren);
                        try compileExpr(p);
                        emit(enc_sub_imm(31, 31, 16));
                        emit(enc_str(31, 0, 0));
                        _ = try p.expect(.comma);
                        try compileExpr(p);
                        emit(enc_ldr(31, 1, 0));
                        emit(enc_add_imm(31, 31, 16));
                        _ = try p.expect(.r_paren);
                        emit(enc_movz(8, 23, 0));
                        emit(enc_svc(0));
                    } else if (std.mem.eql(u8, member_tok.text, "file_read")) {
                        _ = try p.expect(.l_paren);
                        var arg_count: usize = 0;
                        if (p.peek() != .r_paren) {
                            try compileExpr(p);
                            emit(enc_sub_imm(31, 31, 16));
                            emit(enc_str(31, 0, 0));
                            arg_count += 1;
                            while (p.accept(.comma)) {
                                try compileExpr(p);
                                emit(enc_sub_imm(31, 31, 16));
                                emit(enc_str(31, 0, 0));
                                arg_count += 1;
                            }
                        }
                        _ = try p.expect(.r_paren);
                        var i = arg_count;
                        while (i > 0) {
                            i -= 1;
                            emit(enc_ldr(31, @intCast(i), 0));
                            emit(enc_add_imm(31, 31, 16));
                        }
                        emit(enc_movz(8, 24, 0));
                        emit(enc_svc(0));
                    } else if (std.mem.eql(u8, member_tok.text, "file_write")) {
                        _ = try p.expect(.l_paren);
                        var arg_count: usize = 0;
                        if (p.peek() != .r_paren) {
                            try compileExpr(p);
                            emit(enc_sub_imm(31, 31, 16));
                            emit(enc_str(31, 0, 0));
                            arg_count += 1;
                            while (p.accept(.comma)) {
                                try compileExpr(p);
                                emit(enc_sub_imm(31, 31, 16));
                                emit(enc_str(31, 0, 0));
                                arg_count += 1;
                            }
                        }
                        _ = try p.expect(.r_paren);
                        var i = arg_count;
                        while (i > 0) {
                            i -= 1;
                            emit(enc_ldr(31, @intCast(i), 0));
                            emit(enc_add_imm(31, 31, 16));
                        }
                        emit(enc_movz(8, 25, 0));
                        emit(enc_svc(0));
                    } else if (std.mem.eql(u8, member_tok.text, "file_close")) {
                        _ = try p.expect(.l_paren);
                        try compileExpr(p);
                        _ = try p.expect(.r_paren);
                        emit(enc_movz(8, 26, 0));
                        emit(enc_svc(0));
                    } else if (std.mem.eql(u8, member_tok.text, "win_open")) {
                        _ = try p.expect(.l_paren);
                        var arg_count: usize = 0;
                        if (p.peek() != .r_paren) {
                            try compileExpr(p);
                            emit(enc_sub_imm(31, 31, 16));
                            emit(enc_str(31, 0, 0));
                            arg_count += 1;
                            while (p.accept(.comma)) {
                                try compileExpr(p);
                                emit(enc_sub_imm(31, 31, 16));
                                emit(enc_str(31, 0, 0));
                                arg_count += 1;
                            }
                        }
                        _ = try p.expect(.r_paren);
                        var i = arg_count;
                        while (i > 0) {
                            i -= 1;
                            emit(enc_ldr(31, @intCast(i), 0));
                            emit(enc_add_imm(31, 31, 16));
                        }
                        emit(enc_movz(8, 12, 0));
                        emit(enc_svc(0));
                    } else if (std.mem.eql(u8, member_tok.text, "win_fill")) {
                        _ = try p.expect(.l_paren);
                        var arg_count: usize = 0;
                        if (p.peek() != .r_paren) {
                            try compileExpr(p);
                            emit(enc_sub_imm(31, 31, 16));
                            emit(enc_str(31, 0, 0));
                            arg_count += 1;
                            while (p.accept(.comma)) {
                                try compileExpr(p);
                                emit(enc_sub_imm(31, 31, 16));
                                emit(enc_str(31, 0, 0));
                                arg_count += 1;
                            }
                        }
                        _ = try p.expect(.r_paren);
                        var i = arg_count;
                        while (i > 0) {
                            i -= 1;
                            emit(enc_ldr(31, @intCast(i), 0));
                            emit(enc_add_imm(31, 31, 16));
                        }
                        emit(enc_movz(8, 13, 0));
                        emit(enc_svc(0));
                    } else if (std.mem.eql(u8, member_tok.text, "win_present")) {
                        _ = try p.expect(.l_paren);
                        try compileExpr(p);
                        _ = try p.expect(.r_paren);
                        emit(enc_movz(8, 14, 0));
                        emit(enc_svc(0));
                    } else if (std.mem.eql(u8, member_tok.text, "win_close")) {
                        _ = try p.expect(.l_paren);
                        try compileExpr(p);
                        _ = try p.expect(.r_paren);
                        emit(enc_movz(8, 15, 0));
                        emit(enc_svc(0));
                    } else if (std.mem.eql(u8, member_tok.text, "svc")) {
                        _ = try p.expect(.l_paren);
                        const num_tok = try p.expect(.number);
                        const syscall_num = std.fmt.parseInt(u16, num_tok.text, 0) catch return error.CompileError;
                        var arg_count: usize = 0;
                        while (p.accept(.comma)) {
                            try compileExpr(p);
                            emit(enc_sub_imm(31, 31, 16));
                            emit(enc_str(31, 0, 0));
                            arg_count += 1;
                        }
                        _ = try p.expect(.r_paren);
                        var i = arg_count;
                        while (i > 0) {
                            i -= 1;
                            emit(enc_ldr(31, @intCast(i), 0));
                            emit(enc_add_imm(31, 31, 16));
                        }
                        emit(enc_movz(8, syscall_num, 0));
                        emit(enc_svc(0));
                    } else if (std.mem.eql(u8, member_tok.text, "print_array")) {
                        _ = try p.expect(.l_paren);
                        const arr_tok = try p.expect(.ident);
                        _ = try p.expect(.r_paren);
                        const var_ptr = lookupLocalVar(arr_tok.text) orelse {
                            print_err("undefined identifier", arr_tok.line, arr_tok.text);
                            return error.CompileError;
                        };
                        if (!var_ptr.is_array) {
                            print_err("not an array", arr_tok.line, arr_tok.text);
                            return error.CompileError;
                        }
                        emit(enc_movz(0, 1, 0));
                        emit(enc_add_imm(19, 1, @intCast(var_ptr.offset)));
                        emit(enc_movz(2, @intCast(var_ptr.array_len * var_ptr.elem_size), 0));
                        emit(enc_movz(8, 1, 0));
                        emit(enc_svc(0));
                    } else {
                        print_err("unknown zc function", member_tok.line, member_tok.text);
                        return error.CompileError;
                    }
                } else {
                    print_err("unknown module", t.line, t.text);
                    return error.CompileError;
                }
            } else if (p.peek() == .l_bracket) {
                const var_ptr = lookupLocalVar(t.text) orelse {
                    print_err("undefined identifier", t.line, t.text);
                    return error.CompileError;
                };
                if (!var_ptr.is_array) {
                    print_err("not an array", t.line, t.text);
                    return error.CompileError;
                }
                _ = p.advance(); // '['
                try compileExpr(p); // index -> x0
                _ = try p.expect(.r_bracket);
                const shift = elemShift(var_ptr.elem_size);
                if (shift != 0) emit(enc_lsl(0, 0, shift));
                emit(enc_add_imm(19, 1, @intCast(var_ptr.offset)));
                emit(enc_add_reg(1, 0, 1));
                if (var_ptr.elem_size == 1) {
                    emit(enc_ldrb(1, 0, 0));
                } else {
                    emit(enc_ldr(1, 0, 0));
                }
            } else if (std.mem.eql(u8, t.text, "read8")) {
                _ = try p.expect(.l_paren);
                try compileExpr(p);
                _ = try p.expect(.r_paren);
                emit(enc_ldrb(0, 0, 0));
            } else if (std.mem.eql(u8, t.text, "write8")) {
                _ = try p.expect(.l_paren);
                try compileExpr(p);
                emit(enc_sub_imm(31, 31, 16));
                emit(enc_str(31, 0, 0));
                _ = try p.expect(.comma);
                try compileExpr(p);
                emit(enc_ldr(31, 1, 0));
                emit(enc_add_imm(31, 31, 16));
                emit(enc_strb(1, 0, 0));
                emit(enc_movz(0, 0, 0));
                _ = try p.expect(.r_paren);
            } else if (std.mem.eql(u8, t.text, "read64")) {
                _ = try p.expect(.l_paren);
                try compileExpr(p);
                _ = try p.expect(.r_paren);
                emit(enc_ldr(0, 0, 0));
            } else if (std.mem.eql(u8, t.text, "write64")) {
                _ = try p.expect(.l_paren);
                try compileExpr(p);
                emit(enc_sub_imm(31, 31, 16));
                emit(enc_str(31, 0, 0));
                _ = try p.expect(.comma);
                try compileExpr(p);
                emit(enc_ldr(31, 1, 0));
                emit(enc_add_imm(31, 31, 16));
                emit(enc_str(1, 0, 0));
                emit(enc_movz(0, 0, 0));
                _ = try p.expect(.r_paren);
            } else if (p.peek() == .l_paren) {
                _ = p.advance();
                var arg_count: usize = 0;
                if (p.peek() != .r_paren) {
                    try compileExpr(p);
                    emit(enc_sub_imm(31, 31, 16));
                    emit(enc_str(31, 0, 0));
                    arg_count += 1;
                    while (p.accept(.comma)) {
                        try compileExpr(p);
                        emit(enc_sub_imm(31, 31, 16));
                        emit(enc_str(31, 0, 0));
                        arg_count += 1;
                    }
                }
                _ = try p.expect(.r_paren);
                var i = arg_count;
                while (i > 0) {
                    i -= 1;
                    emit(enc_ldr(31, @intCast(i), 0));
                    emit(enc_add_imm(31, 31, 16));
                }
                const func_idx = lookupFunc(t.text);
                if (func_idx) |idx| {
                    const target = functions[idx].address;
                    const rel = @as(i32, @intCast(target)) - @as(i32, @intCast(code_len));
                    emit(enc_bl(rel));
                } else {
                    const f_idx = try registerForwardFunc(t.text);
                    if (call_patches_count >= call_patches.len) return error.CompileError;
                    call_patches[call_patches_count] = CallPatch{ .caller_pc = @intCast(code_len), .target_func_idx = f_idx };
                    call_patches_count += 1;
                    emit(0);
                }
            } else {
                const offset = lookupLocal(t.text) orelse {
                    print_err("undefined identifier", t.line, t.text);
                    return error.CompileError;
                };
                emit(enc_ldr(19, 0, @intCast(offset)));
            }
        },
        .l_paren => {
            try compileExpr(p);
            _ = try p.expect(.r_paren);
        },
        else => return error.CompileError,
    }
}

// ---------------------------------------------------------------------------
// Statement Compiler
// ---------------------------------------------------------------------------
fn compileStatement(p: *Parser) anyerror!void {
    const k = p.peek();
    switch (k) {
        .keyword_let, .keyword_var, .keyword_const => {
            _ = p.advance();
            const name_tok = try p.expect(.ident);
            var is_array = false;
            var arr_len: usize = 0;
            var elem_size: usize = 8;
            if (p.accept(.colon)) {
                if (p.accept(.l_bracket)) {
                    const len_tok = try p.expect(.number);
                    arr_len = std.fmt.parseInt(usize, len_tok.text, 0) catch return error.CompileError;
                    _ = try p.expect(.r_bracket);
                    const elem_tok = try p.expect(.ident);
                    if (std.mem.eql(u8, elem_tok.text, "u8")) elem_size = 1 else if (std.mem.eql(u8, elem_tok.text, "u64")) elem_size = 8 else if (std.mem.eql(u8, elem_tok.text, "u32")) elem_size = 4 else if (std.mem.eql(u8, elem_tok.text, "u16")) elem_size = 2 else return error.CompileError;
                    is_array = true;
                } else {
                    _ = try p.expect(.ident);
                }
            }
            if (is_array) {
                const total = arr_len * elem_size;
                const aligned = (total + 7) & ~@as(usize, 7);
                if (frame_size + aligned > 512) return error.CompileError;
                const offset = frame_size;
                frame_size += aligned;
                if (p.accept(.equal)) {
                    if (p.peek() == .ident and std.mem.eql(u8, p.currentToken().text, "undefined")) {
                        _ = p.advance();
                    } else {
                        print_err("array init not supported", name_tok.line, name_tok.text);
                        return error.CompileError;
                    }
                }
                _ = try p.expect(.semicolon);
                if (locals_count >= locals.len) return error.CompileError;
                locals[locals_count] = LocalVar{ .name = name_tok.text, .offset = offset, .is_array = true, .array_len = arr_len, .elem_size = elem_size };
                locals_count += 1;
            } else {
                _ = try p.expect(.equal);
                if (p.peek() == .ident and std.mem.eql(u8, p.currentToken().text, "undefined")) {
                    _ = p.advance();
                    _ = try p.expect(.semicolon);
                    const offset = frame_size;
                    frame_size += 8;
                    if (locals_count >= locals.len) return error.CompileError;
                    locals[locals_count] = LocalVar{ .name = name_tok.text, .offset = offset };
                    locals_count += 1;
                } else {
                    try compileExpr(p);
                    _ = try p.expect(.semicolon);
                    const offset = frame_size;
                    frame_size += 8;
                    emit(enc_str(19, 0, @intCast(offset)));
                    if (locals_count >= locals.len) return error.CompileError;
                    locals[locals_count] = LocalVar{ .name = name_tok.text, .offset = offset };
                    locals_count += 1;
                }
            }
        },
        .keyword_if => {
            _ = p.advance();
            _ = try p.expect(.l_paren);
            try compileExpr(p);
            _ = try p.expect(.r_paren);
            emit(enc_cmp_imm(0, 0));
            const else_branch_idx = code_len;
            emit(0);
            _ = try p.expect(.l_brace);
            while (p.peek() != .r_brace and p.peek() != .eof) try compileStatement(p);
            _ = try p.expect(.r_brace);
            const end_branch_idx = code_len;
            emit(0);
            const else_pc = code_len;
            const else_offset_bytes = @as(i32, @intCast(else_pc - else_branch_idx));
            std.mem.writeInt(u32, code[else_branch_idx..][0..4], enc_b_cond(.eq, else_offset_bytes), .little);
            if (p.accept(.keyword_else)) {
                _ = try p.expect(.l_brace);
                while (p.peek() != .r_brace and p.peek() != .eof) try compileStatement(p);
                _ = try p.expect(.r_brace);
            }
            const end_pc = code_len;
            const end_offset_bytes = @as(i32, @intCast(end_pc - end_branch_idx));
            std.mem.writeInt(u32, code[end_branch_idx..][0..4], enc_b(end_offset_bytes), .little);
        },
        .keyword_while => {
            _ = p.advance();
            const start_pc = code_len;
            _ = try p.expect(.l_paren);
            try compileExpr(p);
            _ = try p.expect(.r_paren);
            emit(enc_cmp_imm(0, 0));
            const end_branch_idx = code_len;
            emit(0);
            _ = try p.expect(.l_brace);
            while (p.peek() != .r_brace and p.peek() != .eof) try compileStatement(p);
            _ = try p.expect(.r_brace);
            const jump_back_offset = @as(i32, @intCast(start_pc)) - @as(i32, @intCast(code_len));
            emit(enc_b(jump_back_offset));
            const end_pc = code_len;
            const end_offset_bytes = @as(i32, @intCast(end_pc - end_branch_idx));
            std.mem.writeInt(u32, code[end_branch_idx..][0..4], enc_b_cond(.eq, end_offset_bytes), .little);
        },
        .keyword_return => {
            _ = p.advance();
            if (p.peek() != .semicolon) try compileExpr(p);
            _ = try p.expect(.semicolon);
            emit(enc_add_imm(19, 31, 0));
            emit(enc_add_imm(31, 31, 512));
            emit(enc_ldr(31, 19, 0));
            emit(enc_add_imm(31, 31, 16));
            emit(enc_ldr(31, 30, 0));
            emit(enc_add_imm(31, 31, 16));
            emit(enc_ret(30));
        },
        else => {
            if (p.peek() == .ident and std.mem.eql(u8, p.currentToken().text, "_") and p.idx + 1 < p.tokens.len and p.tokens[p.idx + 1].kind == .equal) {
                _ = p.advance();
                _ = p.advance();
                try compileExpr(p);
                _ = try p.expect(.semicolon);
            } else if (p.peek() == .ident and p.idx + 1 < p.tokens.len and p.tokens[p.idx + 1].kind == .equal) {
                const name_tok = p.advance();
                _ = p.advance();
                try compileExpr(p);
                _ = try p.expect(.semicolon);
                const offset = lookupLocal(name_tok.text) orelse return error.CompileError;
                emit(enc_str(19, 0, @intCast(offset)));
            } else if (p.peek() == .ident and p.idx + 1 < p.tokens.len and p.tokens[p.idx + 1].kind == .l_bracket) {
                // possible array store: look for ']' then '='
                var found = false;
                var j = p.idx + 2;
                while (j < p.tokens.len) : (j += 1) {
                    if (p.tokens[j].kind == .r_bracket) {
                        if (j + 1 < p.tokens.len and p.tokens[j + 1].kind == .equal) found = true;
                        break;
                    }
                    if (p.tokens[j].kind == .semicolon or p.tokens[j].kind == .eof) break;
                }
                if (found) {
                    const arr_name = p.advance().text;
                    const var_ptr = lookupLocalVar(arr_name) orelse return error.CompileError;
                    if (!var_ptr.is_array) return error.CompileError;
                    _ = p.advance(); // '['
                    try compileExpr(p); // index -> x0
                    _ = try p.expect(.r_bracket);
                    _ = try p.expect(.equal);
                    emit(enc_sub_imm(31, 31, 16));
                    emit(enc_str(31, 0, 0)); // save idx
                    try compileExpr(p); // value -> x0
                    _ = try p.expect(.semicolon);
                    emit(enc_ldr(31, 1, 0));
                    emit(enc_add_imm(31, 31, 16));
                    const shift = elemShift(var_ptr.elem_size);
                    if (shift != 0) emit(enc_lsl(1, 1, shift));
                    emit(enc_add_imm(19, 2, @intCast(var_ptr.offset)));
                    emit(enc_add_reg(2, 1, 2));
                    if (var_ptr.elem_size == 1) {
                        emit(enc_strb(2, 0, 0));
                    } else {
                        emit(enc_str(2, 0, 0));
                    }
                } else {
                    try compileExpr(p);
                    _ = try p.expect(.semicolon);
                }
            } else {
                try compileExpr(p);
                _ = try p.expect(.semicolon);
            }
        },
    }
}

// ---------------------------------------------------------------------------
// Compiler Main Driver
// ---------------------------------------------------------------------------
fn compile(src: []const u8) !usize {
    var tokenizer = Tokenizer{ .src = src };
    tokens_count = 0;
    while (true) {
        const t = tokenizer.next();
        if (tokens_count >= tokens_buf.len) return error.TooManyTokens;
        tokens_buf[tokens_count] = t;
        tokens_count += 1;
        if (t.kind == .eof) break;
    }
    const tokens = tokens_buf[0..tokens_count];

    code_len = 0;
    functions_count = 0;
    call_patches_count = 0;
    locals_count = 0;
    frame_size = 0;
    data_len = 0;
    string_patches_count = 0;

    // Pass 1: Gather function declarations
    var p1 = Parser{ .tokens = tokens };
    while (p1.peek() != .eof) {
        _ = p1.accept(.keyword_pub);
        if (p1.peek() == .keyword_fn) {
            _ = p1.advance();
            const name_tok = try p1.expect(.ident);
            _ = try p1.expect(.l_paren);
            const param_count = countParams(tokens, p1.idx);
            while (p1.peek() != .r_paren and p1.peek() != .eof) _ = p1.advance();
            _ = try p1.expect(.r_paren);
            _ = try p1.expect(.ident); // return type
            _ = try p1.expect(.l_brace);
            var brace_depth: usize = 1;
            while (brace_depth > 0 and p1.peek() != .eof) {
                const k = p1.advance().kind;
                if (k == .l_brace) brace_depth += 1;
                if (k == .r_brace) brace_depth -= 1;
            }
            if (functions_count >= functions.len) return error.TooManyFunctions;
            functions[functions_count] = Function{ .name = name_tok.text, .address = 0, .param_count = param_count };
            functions_count += 1;
        } else if (p1.peek() == .keyword_const or p1.peek() == .keyword_var or p1.peek() == .keyword_let) {
            _ = p1.advance();
            while (p1.peek() != .semicolon and p1.peek() != .eof) _ = p1.advance();
            _ = p1.accept(.semicolon);
        } else {
            _ = p1.advance();
        }
    }

    // Emit startup entry: call main, then exit
    emit(0);
    emit(enc_movz(0, 0, 0));
    emit(enc_movz(8, 3, 0));
    emit(enc_svc(0));

    // Pass 2: Compile function bodies
    var p2 = Parser{ .tokens = tokens };
    while (p2.peek() != .eof) {
        _ = p2.accept(.keyword_pub);
        if (p2.peek() == .keyword_fn) {
            _ = p2.advance();
            const name_tok = try p2.expect(.ident);
            const f_idx = lookupFunc(name_tok.text).?;
            functions[f_idx].address = @intCast(code_len);

            _ = try p2.expect(.l_paren);
            locals_count = 0;
            frame_size = 0;

            // Load arguments
            if (p2.peek() != .r_paren) {
                const p_name = try p2.expect(.ident);
                _ = try p2.expect(.colon);
                _ = try p2.expect(.ident);
                locals[locals_count] = LocalVar{ .name = p_name.text, .offset = frame_size };
                locals_count += 1;
                frame_size += 8;
                while (p2.accept(.comma)) {
                    const next_p_name = try p2.expect(.ident);
                    _ = try p2.expect(.colon);
                    _ = try p2.expect(.ident);
                    locals[locals_count] = LocalVar{ .name = next_p_name.text, .offset = frame_size };
                    locals_count += 1;
                    frame_size += 8;
                }
            }
            _ = try p2.expect(.r_paren);
            _ = try p2.expect(.ident); // return type
            _ = try p2.expect(.l_brace);

            // Function prologue
            emit(enc_sub_imm(31, 31, 16));
            emit(enc_str(31, 30, 0));
            emit(enc_sub_imm(31, 31, 16));
            emit(enc_str(31, 19, 0));
            emit(enc_sub_imm(31, 31, 512));
            emit(enc_add_imm(31, 19, 0));

            var i: usize = 0;
            while (i < functions[f_idx].param_count) : (i += 1) {
                emit(enc_str(19, @intCast(i), @intCast(i * 8)));
            }

            while (p2.peek() != .r_brace and p2.peek() != .eof) try compileStatement(&p2);
            _ = try p2.expect(.r_brace);

            // Function epilogue
            emit(enc_add_imm(19, 31, 0));
            emit(enc_add_imm(31, 31, 512));
            emit(enc_ldr(31, 19, 0));
            emit(enc_add_imm(31, 31, 16));
            emit(enc_ldr(31, 30, 0));
            emit(enc_add_imm(31, 31, 16));
            emit(enc_ret(30));
        } else if (p2.peek() == .keyword_const or p2.peek() == .keyword_var or p2.peek() == .keyword_let) {
            _ = p2.advance();
            while (p2.peek() != .semicolon and p2.peek() != .eof) _ = p2.advance();
            _ = p2.accept(.semicolon);
        } else {
            _ = p2.advance();
        }
    }

    // Resolve patches
    for (call_patches[0..call_patches_count]) |patch| {
        const target_addr = functions[patch.target_func_idx].address;
        if (target_addr == 0) return error.CompileError;
        const rel = @as(i32, @intCast(target_addr)) - @as(i32, @intCast(patch.caller_pc));
        std.mem.writeInt(u32, code[patch.caller_pc..][0..4], enc_bl(rel), .little);
    }

    // Resolve string ADR patches
    for (string_patches[0..string_patches_count]) |patch| {
        const target_pc = code_len + patch.data_off;
        const rel_bytes = @as(i32, @intCast(target_pc)) - @as(i32, @intCast(patch.code_pc));
        std.mem.writeInt(u32, code[patch.code_pc..][0..4], enc_adr(patch.rd, rel_bytes), .little);
    }

    const main_idx = lookupFunc("main") orelse return error.CompileError;
    const main_addr = functions[main_idx].address;
    std.mem.writeInt(u32, code[0..4], enc_bl(@intCast(main_addr)), .little);

    return code_len;
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------
pub export fn _start(argc: usize, argv: ?[*]const [32]u8) callconv(.c) noreturn {
    var src_path_buf: [40]u8 = [_]u8{0} ** 40;
    @memcpy(src_path_buf[0..11], "/esp/MAIN.Z");
    var out_path_buf: [40]u8 = [_]u8{0} ** 40;
    @memcpy(out_path_buf[0..13], "/esp/MAIN.ELF");
    var src_len: usize = 11;
    var out_len: usize = 13;

    if (argc >= 1) {
        if (argv) |slots| copy_arg(&src_path_buf, &src_len, slots[0]);
    }
    if (argc >= 2) {
        if (argv) |slots| copy_arg(&out_path_buf, &out_len, slots[1]);
    }

    run(src_path_buf[0..src_len], out_path_buf[0..out_len]);
}

fn copy_arg(dst: *[40]u8, len: *usize, slot: [32]u8) void {
    const n = std.mem.indexOfScalar(u8, &slot, 0) orelse slot.len;
    const take = @min(n, dst.len);
    @memcpy(dst[0..take], slot[0..take]);
    len.* = take;
}

const source_cap: usize = 8192;
var source_buf: [source_cap]u8 = undefined;
var image_buf: [elf_code_offset + 32768]u8 = undefined;

fn run(src_path: []const u8, out_path: []const u8) noreturn {
    const fd = file_open(src_path, MODE_READ);
    if (fd < 0) {
        console_puts("zc: cannot open source\n");
        sys_exit(1);
    }
    const n = file_read(@intCast(fd), &source_buf);
    file_close(@intCast(fd));
    if (n <= 0) {
        console_puts("zc: empty or unreadable source\n");
        sys_exit(2);
    }

    const bytes = compile(source_buf[0..@intCast(n)]) catch {
        console_puts("zc: compile failed\n");
        sys_exit(3);
    };

    const total = build_elf32_with_data(code[0..bytes], data_buf[0..data_len], 0, &image_buf) catch {
        console_puts("zc: image generation failed\n");
        sys_exit(4);
    };

    const ofd = file_open(out_path, MODE_CREATE | MODE_WRITE);
    if (ofd < 0) {
        console_puts("zc: cannot create output\n");
        sys_exit(5);
    }
    _ = file_write(@intCast(ofd), image_buf[0..total]);
    file_close(@intCast(ofd));

    console_puts("zc: successfully compiled in-guest\n");
    sys_exit(0);
}

// ---------------------------------------------------------------------------
// Host Tests
// ---------------------------------------------------------------------------
const testing = std.testing;

test "zc: tokenizer handles keywords, identifiers, numbers, and symbols" {
    const src = "fn main() void { let x: u64 = 42; return x; }";
    var t = Tokenizer{ .src = src };
    try testing.expectEqual(TokenKind.keyword_fn, t.next().kind);
    try testing.expectEqual(TokenKind.ident, t.next().kind);
    try testing.expectEqual(TokenKind.l_paren, t.next().kind);
    try testing.expectEqual(TokenKind.r_paren, t.next().kind);
    try testing.expectEqual(TokenKind.ident, t.next().kind);
    try testing.expectEqual(TokenKind.l_brace, t.next().kind);
    try testing.expectEqual(TokenKind.keyword_let, t.next().kind);
    try testing.expectEqual(TokenKind.ident, t.next().kind);
    try testing.expectEqual(TokenKind.colon, t.next().kind);
    try testing.expectEqual(TokenKind.ident, t.next().kind);
    try testing.expectEqual(TokenKind.equal, t.next().kind);
    try testing.expectEqual(TokenKind.number, t.next().kind);
    try testing.expectEqual(TokenKind.semicolon, t.next().kind);
    try testing.expectEqual(TokenKind.keyword_return, t.next().kind);
}

test "zc: compiles trivial program to AArch64 machine code" {
    const src = "fn main() void { return; }";
    const bytes = try compile(src);
    try testing.expect(bytes > 20);
    // startup shim + prologue + epilogue
    try testing.expectEqual(@as(u32, enc_bl(16)), std.mem.readInt(u32, code[0..4], .little));
}

test "zc: compiles simple expression arithmetic" {
    const src = "fn main() void { let x = (3 + 4) * 5; return; }";
    const bytes = try compile(src);
    try testing.expect(bytes > 0);
}

test "zc: Z0.5 dialect contract with @import(\"zc\") and zc.exit" {
    const src =
        \\const zc = @import("zc");
        \\
        \\pub fn main() void {
        \\    zc.exit(72);
        \\}
    ;
    const bytes = try compile(src);
    try testing.expect(bytes > 0);
    // main is called from entry at byte 0
    try testing.expectEqual(@as(u32, enc_bl(16)), std.mem.readInt(u32, code[0..4], .little));
}

test "zc: Z0.5 zc builtins (write, yield, sleep, file ops)" {
    const src =
        \\const zc = @import("zc");
        \\
        \\pub fn main() void {
        \\    zc.yield();
        \\    zc.sleep(5);
        \\    _ = zc.write(1, 4096, 12);
        \\    let fd = zc.file_open(100, 1);
        \\    _ = zc.file_read(fd, 200, 50);
        \\    _ = zc.file_write(fd, 200, 50);
        \\    zc.file_close(fd);
        \\    zc.exit(0);
        \\}
    ;
    const bytes = try compile(src);
    try testing.expect(bytes > 0);
}

test "zc: tokenizer handles dot, at, string literals, and pub keyword" {
    const src = "const zc = @import(\"zc\"); pub fn main() void {}";
    var t = Tokenizer{ .src = src };
    try testing.expectEqual(TokenKind.keyword_const, t.next().kind);
    try testing.expectEqual(TokenKind.ident, t.next().kind);
    try testing.expectEqual(TokenKind.equal, t.next().kind);
    try testing.expectEqual(TokenKind.at, t.next().kind);
    try testing.expectEqual(TokenKind.ident, t.next().kind);
    try testing.expectEqual(TokenKind.l_paren, t.next().kind);
    try testing.expectEqual(TokenKind.string_lit, t.next().kind);
    try testing.expectEqual(TokenKind.r_paren, t.next().kind);
    try testing.expectEqual(TokenKind.semicolon, t.next().kind);
    try testing.expectEqual(TokenKind.keyword_pub, t.next().kind);
    try testing.expectEqual(TokenKind.keyword_fn, t.next().kind);
    try testing.expectEqual(TokenKind.ident, t.next().kind);
}

test "zc: VL6 GUI consumer builtins (win_open, win_fill, win_present, win_close)" {
    const src =
        \\const zc = @import("zc");
        \\
        \\pub fn main() void {
        \\    const wid: u64 = zc.win_open(64, 64, 256, 192);
        \\    _ = zc.win_fill(wid, 0, 0, 256, 192, 0x1a2b3c);
        \\    _ = zc.win_fill(wid, 8, 8, 48, 48, 0xff0000);
        \\    _ = zc.win_present(wid);
        \\    zc.win_close(wid);
        \\    zc.exit(72);
        \\}
    ;
    const bytes = try compile(src);
    try testing.expect(bytes > 0);
    // entry jumps to main
    try testing.expectEqual(@as(u32, enc_bl(16)), std.mem.readInt(u32, code[0..4], .little));
}

test "zc: Z1a string literal unescape and data segment emission" {
    const src =
        \\const zc = @import("zc");
        \\
        \\pub fn main() void {
        \\    zc.print("Hello, world!\n");
        \\    _ = zc.write(1, "Second line\n");
        \\    zc.exit(0);
        \\}
    ;
    const bytes = try compile(src);
    try testing.expect(bytes > 0);
    try testing.expect(data_len > 0);
    try testing.expectEqualStrings("Hello, world!\nSecond line\n", data_buf[0..data_len]);

    const total = try build_elf32_with_data(code[0..bytes], data_buf[0..data_len], 0, &image_buf);
    try testing.expect(total == elf_code_offset + bytes + data_len);
}

test "zc: Z1b array allocation, indexed store/load, and print_array" {
    const src =
        \\const zc = @import("zc");
        \\
        \\pub fn main() void {
        \\    var buf: [8]u8 = undefined;
        \\    var i: u64 = 0;
        \\    while (i < 8) {
        \\        buf[i] = 65 + i;
        \\        i = i + 1;
        \\    }
        \\    zc.print_array(buf);
        \\    var sum: u64 = 0;
        \\    i = 0;
        \\    while (i < 8) {
        \\        sum = sum + buf[i];
        \\        i = i + 1;
        \\    }
        \\    if (sum == 548) {
        \\        zc.exit(0);
        \\    } else {
        \\        zc.exit(1);
        \\    }
        \\}
    ;
    const bytes = try compile(src);
    try testing.expect(bytes > 0);
    const total = try build_elf32_with_data(code[0..bytes], data_buf[0..data_len], 0, &image_buf);
    try testing.expect(total == elf_code_offset + bytes + data_len);
}

test "zc: Z1b u64 array with scaled index" {
    const src =
        \\const zc = @import("zc");
        \\
        \\pub fn main() void {
        \\    var arr: [4]u64 = undefined;
        \\    arr[0] = 10;
        \\    arr[1] = 20;
        \\    arr[2] = 30;
        \\    arr[3] = 40;
        \\    var s: u64 = arr[0] + arr[1] + arr[2] + arr[3];
        \\    if (s == 100) {
        \\        zc.exit(0);
        \\    } else {
        \\        zc.exit(1);
        \\    }
        \\}
    ;
    const bytes = try compile(src);
    try testing.expect(bytes > 0);
}

test "zc: Z1b tokenizer handles brackets" {
    const src = "var buf: [8]u8 = undefined; buf[0] = 65;";
    var t = Tokenizer{ .src = src };
    try testing.expectEqual(TokenKind.keyword_var, t.next().kind);
    try testing.expectEqual(TokenKind.ident, t.next().kind);
    try testing.expectEqual(TokenKind.colon, t.next().kind);
    try testing.expectEqual(TokenKind.l_bracket, t.next().kind);
    try testing.expectEqual(TokenKind.number, t.next().kind);
    try testing.expectEqual(TokenKind.r_bracket, t.next().kind);
    try testing.expectEqual(TokenKind.ident, t.next().kind);
}
