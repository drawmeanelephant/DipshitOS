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
