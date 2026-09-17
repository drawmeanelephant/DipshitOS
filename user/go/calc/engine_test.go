package main

import "testing"

func TestIntegerArithmetic(t *testing.T) {
	var e Engine
	e.InputDigit(1)
	e.InputDigit(2)
	e.SetOp('+')
	e.InputDigit(3)
	e.InputDigit(4)
	e.Evaluate()
	if e.cur != 46 {
		t.Fatalf("12+34 = %d want 46", e.cur)
	}

	e.SetOp('*')
	e.InputDigit(2)
	e.Evaluate()
	if e.cur != 92 {
		t.Fatalf("46*2 = %d want 92", e.cur)
	}

	e.SetOp('-')
	e.InputDigit(1)
	e.InputDigit(0)
	e.InputDigit(0)
	e.Evaluate()
	if e.cur != -8 {
		t.Fatalf("92-100 = %d want -8", e.cur)
	}

	e.SetOp('/')
	e.InputDigit(2)
	e.Evaluate()
	if e.cur != -4 {
		t.Fatalf("-8/2 = %d want -4", e.cur)
	}
}

func TestGateExpression(t *testing.T) {
	var e Engine
	e.InputDigit(1)
	e.InputDigit(2)
	e.SetOp('-')
	e.InputDigit(3)
	e.Evaluate()
	if e.Display() != "9" {
		t.Fatalf("12-3 display = %q want 9", e.Display())
	}
}

func TestDivideByZero(t *testing.T) {
	var e Engine
	e.InputDigit(5)
	e.SetOp('/')
	e.InputDigit(0)
	e.Evaluate()
	if !e.hasErr || e.Display() != "ERROR" {
		t.Fatalf("5/0 → err=%v display=%q", e.hasErr, e.Display())
	}
}

func TestTruncatingDiv(t *testing.T) {
	var e Engine
	e.InputDigit(8)
	e.SetOp('/')
	e.InputDigit(3)
	e.Evaluate()
	if e.cur != 2 {
		t.Fatalf("8/3 = %d want 2 (trunc toward zero)", e.cur)
	}
	e.Clear()
	e.SetOp('-')
	e.InputDigit(8)
	e.SetOp('/')
	e.InputDigit(3)
	e.Evaluate()
	if e.cur != -2 {
		t.Fatalf("-8/3 = %d want -2", e.cur)
	}
}

func TestBackspaceAndClear(t *testing.T) {
	var e Engine
	e.InputDigit(1)
	e.InputDigit(2)
	e.InputDigit(3)
	e.Backspace()
	if e.cur != 12 {
		t.Fatalf("backspace 123 → %d want 12", e.cur)
	}
	e.Clear()
	if e.cur != 0 || e.entering || e.hasErr || e.pending != 0 {
		t.Fatal("clear must reset")
	}
}

func TestOverflowShowsError(t *testing.T) {
	var e Engine
	e.accum = maxI64
	e.cur = 1
	e.entering = true
	e.pending = '+'
	e.Evaluate()
	if !e.hasErr {
		t.Fatal("max+1 must ERROR")
	}

	e.Clear()
	e.accum = minI64
	e.cur = 1
	e.entering = true
	e.pending = '-'
	e.Evaluate()
	if !e.hasErr {
		t.Fatal("min-1 must ERROR")
	}

	e.Clear()
	e.accum = 4_000_000_000
	e.cur = 4_000_000_000
	e.entering = true
	e.pending = '*'
	e.Evaluate()
	if !e.hasErr {
		t.Fatal("4e9*4e9 must ERROR")
	}

	e.Clear()
	e.accum = minI64
	e.cur = -1
	e.entering = true
	e.pending = '/'
	e.Evaluate()
	if !e.hasErr {
		t.Fatal("min/-1 must ERROR")
	}

	e.Clear()
	e.cur = maxI64
	e.entering = true
	e.InputDigit(9)
	if e.cur != maxI64 || e.hasErr {
		t.Fatalf("refusing an overflowing digit must keep %d, not wrap", maxI64)
	}
}

func TestRepeatLastOp(t *testing.T) {
	var e Engine
	e.InputDigit(5)
	e.SetOp('+')
	e.InputDigit(3)
	e.Evaluate()
	if e.cur != 8 {
		t.Fatalf("5+3 = %d want 8", e.cur)
	}
	e.Evaluate()
	if e.cur != 11 {
		t.Fatalf("repeat +3 = %d want 11", e.cur)
	}
	e.Evaluate()
	if e.cur != 14 {
		t.Fatalf("repeat +3 again = %d want 14", e.cur)
	}
}

func TestDigitAfterEquals(t *testing.T) {
	var e Engine
	e.InputDigit(5)
	e.SetOp('+')
	e.InputDigit(3)
	e.Evaluate()
	e.InputDigit(2)
	if e.cur != 2 {
		t.Fatalf("digit after = starts a new entry, got %d", e.cur)
	}
	e.Evaluate()
	if e.cur != 5 {
		t.Fatalf("2 + last-arg 3 = %d want 5", e.cur)
	}
}

func TestLeftToRightChain(t *testing.T) {
	var e Engine
	e.InputDigit(2)
	e.SetOp('*')
	e.InputDigit(3)
	e.SetOp('+')
	e.InputDigit(4)
	e.Evaluate()
	if e.cur != 10 {
		t.Fatalf("2*3+4 left-to-right = %d want 10", e.cur)
	}
}

func TestFormatMinInt(t *testing.T) {
	if got := formatI64(minI64); got != "-9223372036854775808" {
		t.Fatalf("minInt display = %q", got)
	}
	if got := formatI64(0); got != "0" {
		t.Fatalf("zero display = %q", got)
	}
}
