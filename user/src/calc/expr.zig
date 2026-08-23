//! calc/expr.zig — M24 K9 expression editor for CALC.BIN.
//!
//! Recursive-descent parser/evaluator over checked i64 arithmetic. BODMAS
//! precedence, left-associative, tokens: numbers, + - * / %, parentheses,
//! unary minus. No heap, no libm; all errors are typed, never silent wraps.

const std = @import("std");

pub const ExprError = error{
    Syntax,
    DivideByZero,
    Overflow,
};

/// Evaluate a full expression string.
pub fn evaluate(src: []const u8) ExprError!i64 {
    var p = Parser{ .s = src, .i = 0 };
    const v = try p.expr();
    p.skipWs();
    if (p.i != p.s.len) return error.Syntax;
    return v;
}

/// Is this character part of an expression the editor should accept?
pub fn is_expr_char(c: u8) bool {
    return (c >= '0' and c <= '9') or c == '+' or c == '-' or c == '*' or
        c == '/' or c == '%' or c == '(' or c == ')' or c == ' ';
}

/// K15: identifier characters for definition names.
fn is_name_char(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or (c >= '0' and c <= '9');
}

/// K15: resolve a definition name to a value; null = unknown name.
pub const Resolver = *const fn (name: []const u8) ?f64;

/// K15: float evaluation with named definitions — used when an expression
/// contains identifiers (`2 * pi`). Same grammar as the integer parser;
/// division is true division and % keeps its remainder semantics.
pub fn evaluate_f64(src: []const u8, resolver: Resolver) ExprError!f64 {
    var p = ParserF{ .s = src, .i = 0, .resolve = resolver };
    const v = try p.expr();
    p.skipWs();
    if (p.i != p.s.len) return error.Syntax;
    return v;
}

const ParserF = struct {
    s: []const u8,
    i: usize,
    resolve: Resolver,

    fn skipWs(p: *ParserF) void {
        while (p.i < p.s.len and p.s[p.i] == ' ') p.i += 1;
    }

    fn peek(p: *ParserF) ?u8 {
        p.skipWs();
        if (p.i >= p.s.len) return null;
        return p.s[p.i];
    }

    fn expr(p: *ParserF) ExprError!f64 {
        var v = try p.term();
        while (true) {
            const c = p.peek() orelse break;
            if (c != '+' and c != '-') break;
            p.i += 1;
            const r = try p.term();
            v = if (c == '+') v + r else v - r;
        }
        return v;
    }

    fn term(p: *ParserF) ExprError!f64 {
        var v = try p.factor();
        while (true) {
            const c = p.peek() orelse break;
            if (c != '*' and c != '/' and c != '%') break;
            p.i += 1;
            const r = try p.factor();
            switch (c) {
                '*' => v = v * r,
                '/' => {
                    if (r == 0) return error.DivideByZero;
                    v = v / r;
                },
                else => {
                    if (r == 0) return error.DivideByZero;
                    v = @rem(v, r);
                },
            }
        }
        return v;
    }

    fn factor(p: *ParserF) ExprError!f64 {
        const c = p.peek() orelse return error.Syntax;
        if (c == '(') {
            p.i += 1;
            const v = try p.expr();
            if ((p.peek() orelse return error.Syntax) != ')') return error.Syntax;
            p.i += 1;
            return v;
        }
        if (c == '-') {
            p.i += 1;
            return -(try p.factor());
        }
        if (c == '+') {
            p.i += 1;
            return p.factor();
        }
        // Identifier?
        if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_') {
            p.skipWs();
            const start = p.i;
            while (p.i < p.s.len and is_name_char(p.s[p.i])) p.i += 1;
            const name = p.s[start..p.i];
            if (p.resolve(name)) |val| return val;
            return error.Syntax; // unknown name
        }
        return p.number();
    }

    fn number(p: *ParserF) ExprError!f64 {
        p.skipWs();
        var v: f64 = 0;
        var n: usize = 0;
        var saw_dot = false;
        var frac_scale: f64 = 1;
        while (p.i < p.s.len) {
            const ch = p.s[p.i];
            if (ch >= '0' and ch <= '9') {
                v = v * 10 + @as(f64, @floatFromInt(ch - '0'));
                if (saw_dot) frac_scale *= 10;
                p.i += 1;
                n += 1;
            } else if (ch == '.' and !saw_dot) {
                saw_dot = true;
                p.i += 1;
            } else break;
        }
        if (n == 0) return error.Syntax;
        return v / frac_scale;
    }
};

const Parser = struct {
    s: []const u8,
    i: usize,

    fn skipWs(p: *Parser) void {
        while (p.i < p.s.len and p.s[p.i] == ' ') p.i += 1;
    }

    fn peek(p: *Parser) ?u8 {
        p.skipWs();
        if (p.i >= p.s.len) return null;
        return p.s[p.i];
    }

    /// expr := term (('+' | '-') term)*   -- lowest precedence
    fn expr(p: *Parser) ExprError!i64 {
        var v = try p.term();
        while (true) {
            const c = p.peek() orelse break;
            if (c != '+' and c != '-') break;
            p.i += 1;
            const r = try p.term();
            v = switch (c) {
                '+' => std.math.add(i64, v, r) catch return error.Overflow,
                else => std.math.sub(i64, v, r) catch return error.Overflow,
            };
        }
        return v;
    }

    /// term := factor (('*' | '/' | '%') factor)*
    fn term(p: *Parser) ExprError!i64 {
        var v = try p.factor();
        while (true) {
            const c = p.peek() orelse break;
            if (c != '*' and c != '/' and c != '%') break;
            p.i += 1;
            const r = try p.factor();
            switch (c) {
                '*' => v = std.math.mul(i64, v, r) catch return error.Overflow,
                '/' => {
                    if (r == 0) return error.DivideByZero;
                    if (v == std.math.minInt(i64) and r == -1) return error.Overflow;
                    v = @divTrunc(v, r);
                },
                else => {
                    if (r == 0) return error.DivideByZero;
                    v = @rem(v, r);
                },
            }
        }
        return v;
    }

    /// factor := number | '(' expr ')' | ('-'|'+') factor
    fn factor(p: *Parser) ExprError!i64 {
        const c = p.peek() orelse return error.Syntax;
        if (c == '(') {
            p.i += 1;
            const v = try p.expr();
            if ((p.peek() orelse return error.Syntax) != ')') return error.Syntax;
            p.i += 1;
            return v;
        }
        if (c == '-') {
            p.i += 1;
            const v = try p.factor();
            return std.math.negate(v) catch return error.Overflow;
        }
        if (c == '+') {
            p.i += 1;
            return p.factor();
        }
        return p.number();
    }

    fn number(p: *Parser) ExprError!i64 {
        p.skipWs();
        var v: i64 = 0;
        var n: usize = 0;
        while (p.i < p.s.len and p.s[p.i] >= '0' and p.s[p.i] <= '9') : (n += 1) {
            v = std.math.mul(i64, v, 10) catch return error.Overflow;
            v = std.math.add(i64, v, p.s[p.i] - '0') catch return error.Overflow;
            p.i += 1;
        }
        if (n == 0) return error.Syntax;
        return v;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "expr: issue cases - BODMAS precedence and parens" {
    try std.testing.expectEqual(@as(i64, 14), try evaluate("2+3*4"));
    try std.testing.expectEqual(@as(i64, 20), try evaluate("(2+3)*4"));
    try std.testing.expectEqual(@as(i64, 8), try evaluate("10/2+3"));
}

test "expr: left-associativity" {
    try std.testing.expectEqual(@as(i64, 10), try evaluate("100/5/2"));
    try std.testing.expectEqual(@as(i64, 5), try evaluate("10-3-2"));
    try std.testing.expectEqual(@as(i64, 16), try evaluate("2*2*2*2"));
}

test "expr: nesting and unary minus" {
    try std.testing.expectEqual(@as(i64, 50), try evaluate("((2+3)*10)"));
    try std.testing.expectEqual(@as(i64, -2), try evaluate("-5+3"));
    try std.testing.expectEqual(@as(i64, 6), try evaluate("-(2-8)"));
    try std.testing.expectEqual(@as(i64, 9), try evaluate("-(1+2)*-3"));
}

test "expr: errors are typed" {
    try std.testing.expectError(error.DivideByZero, evaluate("5/0"));
    try std.testing.expectError(error.DivideByZero, evaluate("5%0"));
    try std.testing.expectError(error.Syntax, evaluate("(2+3"));
    try std.testing.expectError(error.Syntax, evaluate("2+"));
    try std.testing.expectError(error.Syntax, evaluate(""));
    try std.testing.expectError(error.Overflow, evaluate("99999999999999*99999999999999"));
}

test "expr: whitespace tolerated" {
    try std.testing.expectEqual(@as(i64, 14), try evaluate(" 2 + 3 * 4 "));
}

test "expr: float evaluation with definitions" {
    // Issue case: define PI=3.14, 2*PI = 6.28
    const r = struct {
        fn resolve(name: []const u8) ?f64 {
            if (std.mem.eql(u8, name, "pi")) return 3.14;
            if (std.mem.eql(u8, name, "tax_rate")) return 0.08;
            return null;
        }
    }.resolve;
    try std.testing.expectApproxEqAbs(@as(f64, 6.28), try evaluate_f64("2 * pi", r), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 8.0), try evaluate_f64("100 * tax_rate", r), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), try evaluate_f64("1/2", r), 1e-12); // true division
    try std.testing.expectError(error.Syntax, evaluate_f64("2 * nope", r)); // unknown name
    try std.testing.expectApproxEqAbs(@as(f64, 3.84), try evaluate_f64("(1+2)*tax_rate*16", r), 1e-9);
}

test "expr: name parsing respects boundaries" {
    const r = struct {
        fn resolve(name: []const u8) ?f64 {
            if (std.mem.eql(u8, name, "ab")) return 2;
            return null;
        }
    }.resolve;
    try std.testing.expectError(error.Syntax, evaluate_f64("abc", r)); // prefix must not match "ab"
}
