// Integer calculator engine: the calculator path people actually hit.
//
// Checked 64-bit add/sub/mul/div, left-to-right pending-op chaining, repeat
// last op on a bare '=', overflow and divide-by-zero → ERROR (never a silent
// wrap). Not programmer mode, not the expression parser, not units.
package main

const (
	maxI64 = int64(^uint64(0) >> 1)
	minI64 = -maxI64 - 1
)

// Engine is the 64-bit integer calculator core.
type Engine struct {
	accum    int64
	cur      int64
	pending  byte // 0 = none; otherwise '+', '-', '*', '/'
	lastOp   byte
	lastArg  int64
	entering bool
	hasErr   bool
}

func add64(a, b int64) (int64, bool) {
	c := a + b
	if (b > 0 && c < a) || (b < 0 && c > a) {
		return 0, false
	}
	return c, true
}

func sub64(a, b int64) (int64, bool) {
	c := a - b
	if (b > 0 && c > a) || (b < 0 && c < a) {
		return 0, false
	}
	return c, true
}

func mul64(a, b int64) (int64, bool) {
	if a == 0 || b == 0 {
		return 0, true
	}
	c := a * b
	if c/a != b {
		return 0, false
	}
	return c, true
}

func (e *Engine) fail() {
	e.hasErr = true
	e.accum = 0
	e.cur = 0
	e.pending = 0
	e.lastOp = 0
	e.lastArg = 0
	e.entering = false
}

// InputDigit appends d (0–9) onto the number being entered. A digit that
// would overflow i64 is refused (the current value stays put).
func (e *Engine) InputDigit(d uint8) {
	if d > 9 {
		return
	}
	e.hasErr = false
	if !e.entering {
		e.cur = int64(d)
		e.entering = true
		return
	}
	grown, ok := mul64(e.cur, 10)
	if !ok {
		return
	}
	var next int64
	if e.cur >= 0 {
		next, ok = add64(grown, int64(d))
	} else {
		next, ok = sub64(grown, int64(d))
	}
	if !ok {
		return
	}
	e.cur = next
}

// Backspace drops the last entered digit.
func (e *Engine) Backspace() {
	if !e.entering {
		return
	}
	e.cur = e.cur / 10
	if e.cur == 0 {
		e.entering = false
	}
}

// SetOp commits the pending op if a value is being entered, then arms op.
func (e *Engine) SetOp(op byte) {
	if e.hasErr {
		return
	}
	switch op {
	case '+', '-', '*', '/':
	default:
		return
	}
	if e.entering {
		e.Evaluate()
		if e.hasErr {
			return
		}
	}
	e.accum = e.cur
	e.pending = op
	e.entering = false
}

// Evaluate applies the pending binary op, or repeats the last one on a
// bare '=' (`5 + 3 = =` → 8, then 11).
func (e *Engine) Evaluate() {
	if e.hasErr {
		return
	}
	if e.pending != 0 {
		e.evalBinary(e.pending, e.accum, e.cur)
		return
	}
	if e.lastOp != 0 {
		e.evalBinary(e.lastOp, e.cur, e.lastArg)
	}
}

func (e *Engine) evalBinary(op byte, a, b int64) {
	var res int64
	ok := true
	switch op {
	case '+':
		res, ok = add64(a, b)
	case '-':
		res, ok = sub64(a, b)
	case '*':
		res, ok = mul64(a, b)
	case '/':
		if b == 0 || (a == minI64 && b == -1) {
			ok = false
		} else {
			res = a / b
		}
	default:
		res = b
	}
	if !ok {
		e.fail()
		return
	}
	e.cur = res
	e.accum = res
	if e.pending != 0 {
		e.lastOp = op
		e.lastArg = b
	}
	e.pending = 0
	e.entering = false
}

// Clear resets everything, including ERROR.
func (e *Engine) Clear() {
	*e = Engine{}
}

// Display is the screen string: "ERROR" or the current value.
func (e *Engine) Display() string {
	if e.hasErr {
		return "ERROR"
	}
	return formatI64(e.cur)
}

func formatI64(v int64) string {
	if v == 0 {
		return "0"
	}
	var buf [20]byte
	i := len(buf)
	neg := v < 0
	u := uint64(v)
	if neg {
		u = uint64(^v) + 1
	}
	for u > 0 {
		i--
		buf[i] = byte('0' + u%10)
		u /= 10
	}
	if neg {
		i--
		buf[i] = '-'
	}
	return string(buf[i:])
}
