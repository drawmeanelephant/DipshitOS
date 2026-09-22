package shlib

import (
	"fmt"
	"strings"
	"testing"
)

// feedE pushes bytes through a fresh editor and returns the tty output.
func feedE(e *Editor, s string) string {
	out, _ := e.Feed([]byte(s))
	return string(out)
}

// TestEditorTyping pins insert, backspace and the repaint protocol: every
// keystroke repaints `\r` + prompt + line (spaces over the old tail) and
// repositions the cursor with `\r` + prompt + prefix.
func TestEditorTyping(t *testing.T) {
	e := NewEditor("gosh> ", &History{})
	out := feedE(e, "ec")
	// Every keystroke repaints; the final paint is the current state.
	if !strings.HasSuffix(out, "\rgosh> ec") {
		t.Fatalf("insert repaint = %q", out)
	}
	out = feedE(e, "\x7f")
	// One space overwrites the erased tail, then the cursor repositions.
	if !strings.HasSuffix(out, "\rgosh> e \rgosh> e") {
		t.Fatalf("backspace repaint = %q", out)
	}
	out = feedE(e, "ho")
	if !strings.HasSuffix(out, "gosh> eho") {
		t.Fatalf("mid insert = %q", out)
	}
	// Ctrl-A, Ctrl-E move within the line.
	out = feedE(e, "\x01x")
	if !strings.Contains(out, "\rgosh> xeho") {
		t.Fatalf("ctrl-a insert = %q", out)
	}
	out = feedE(e, "\x05!")
	if !strings.Contains(out, "xeho!") {
		t.Fatalf("ctrl-e append = %q", out)
	}
}

// TestEditorSubmit pins the submit protocol: \r\n, the pushed history, the
// next prompt in the same write, and Ctrl-C / Ctrl-D.
func TestEditorSubmit(t *testing.T) {
	h := &History{}
	e := NewEditor("gosh> ", h)
	out, ev := e.Feed([]byte("echo hi\r"))
	if ev.Kind != EvSubmit || ev.Line != "echo hi" {
		t.Fatalf("submit event = %+v", ev)
	}
	if !strings.Contains(string(out), "\r\n\rgosh> ") {
		t.Fatalf("submit repaint = %q", out)
	}
	if len(h.Entries()) != 1 || h.Entries()[0] != "echo hi" {
		t.Fatalf("history = %v", h.Entries())
	}
	// Ctrl-C abandons the line with ^C and a fresh prompt.
	out, ev = e.Feed([]byte("junk\x03"))
	if ev.Kind != EvCancel || !strings.Contains(string(out), "^C\r\n") {
		t.Fatalf("ctrl-c = (%q, %+v)", out, ev)
	}
	// Ctrl-D on an empty line is EOF; on a non-empty line it is ignored.
	_, ev = e.Feed([]byte("x\x04"))
	if ev.Kind != evNone {
		t.Fatalf("ctrl-d non-empty = %+v", ev)
	}
	_, ev = e.Feed([]byte("\x7f\x04"))
	if ev.Kind != EvEOF {
		t.Fatalf("ctrl-d empty = %+v", ev)
	}
}

// TestEditorHistory pins Up/Down recall, the return to the live line, and
// dup-collapse.
func TestEditorHistory(t *testing.T) {
	h := &History{}
	e := NewEditor("gosh> ", h)
	feedE(e, "one\r")
	feedE(e, "two\r")
	feedE(e, "two\r") // dup of the last: collapsed
	if n := len(h.Entries()); n != 2 {
		t.Fatalf("history = %v", h.Entries())
	}
	out := feedE(e, "\x1b[A") // Up
	if !strings.Contains(out, "gosh> two") {
		t.Fatalf("Up = %q", out)
	}
	out = feedE(e, "\x1b[A")
	if !strings.Contains(out, "gosh> one") {
		t.Fatalf("Up Up = %q", out)
	}
	out = feedE(e, "\x1b[B") // Down
	if !strings.Contains(out, "gosh> two") {
		t.Fatalf("Down = %q", out)
	}
	out = feedE(e, "\x1b[B") // past the end: back to the live (empty) line
	if strings.Contains(out, "two") || !strings.Contains(out, "gosh> ") {
		t.Fatalf("Down past end = %q", out)
	}
	// The submitted recall is exact (the gate's history proof).
	_, ev := e.Feed([]byte("\x1b[A\r"))
	if ev.Kind != EvSubmit || ev.Line != "two" {
		t.Fatalf("recalled submit = %+v", ev)
	}
}

// TestEditorCSISplit pins CSI sequences arriving across two chunks (the
// kernel hands 64-byte reads; an escape can straddle the boundary).
func TestEditorCSISplit(t *testing.T) {
	e := NewEditor("gosh> ", &History{})
	feedE(e, "abc")
	out := feedE(e, "\x1b")
	if out != "" {
		t.Fatalf("lone ESC wrote %q", out)
	}
	out = feedE(e, "[D") // now the Left arrives
	if !strings.Contains(out, "\rgosh> ab") {
		t.Fatalf("split CSI = %q", out)
	}
	// The cursor sits between b and c: typing inserts mid-line.
	out = feedE(e, "X")
	if !strings.Contains(out, "abXc") {
		t.Fatalf("mid-line insert = %q", out)
	}
}

// TestEditorKeys pins Home/End/Delete/Ctrl-K/Ctrl-U/Ctrl-W/Ctrl-L.
func TestEditorKeys(t *testing.T) {
	e := NewEditor("gosh> ", &History{})
	feedE(e, "echo hello")
	out := feedE(e, "\x1b[Hx") // Home + insert
	if !strings.Contains(out, "xecho hello") {
		t.Fatalf("home insert = %q", out)
	}
	out = feedE(e, "\x7f\x7f") // delete the x (backspace)
	out = feedE(e, "\x1b[F!")  // End + append
	if !strings.Contains(out, "echo hello!") {
		t.Fatalf("end append = %q", out)
	}
	out = feedE(e, "\x1b[3~") // Delete key: no-op at the end
	if out != "" {
		t.Fatalf("delete at end wrote %q", out)
	}
	// Five Lefts from "echo hello!" put the cursor on hello's 'e'.
	out = feedE(e, "\x1b[D\x1b[D\x1b[D\x1b[D\x1b[D\x1b[3~")
	if !strings.Contains(out, "echo hllo!") {
		t.Fatalf("delete mid-line = %q", out)
	}
	out = feedE(e, "\x0b") // Ctrl-K at the end: nothing to kill
	_ = out
	out = feedE(e, "\x1b[D\x1b[D\x1b[D\x1b[D\x1b[D\x1b[D\x0b") // kill to end from 'h'
	if !strings.Contains(out, "echo h") {
		t.Fatalf("ctrl-k = %q", out)
	}
	out = feedE(e, "\x15") // Ctrl-U: kill to start (tail spaces clear the old text)
	if strings.Contains(out, "echo") || !strings.HasSuffix(out, "\rgosh> ") {
		t.Fatalf("ctrl-u = %q", out)
	}
	out = feedE(e, "echo two words\x17") // Ctrl-W kills "words"
	if !strings.Contains(out, "echo two ") {
		t.Fatalf("ctrl-w = %q", out)
	}
	out = feedE(e, "\x0c") // Ctrl-L clears and repaints
	if !strings.HasPrefix(out, "\x1b[2J\x1b[H") {
		t.Fatalf("ctrl-l = %q", out)
	}
}

// TestEditorCompletion pins Tab: single completes with a space, several
// complete to the common prefix, a second Tab lists, none is a no-op.
func TestEditorCompletion(t *testing.T) {
	e := NewEditor("gosh> ", &History{})
	listed := false
	e.Complete = func(word string, first bool) []string {
		switch word {
		case "ec":
			return []string{"echo "}
		case "c":
			return []string{"cat ", "cd ", "clear "}
		case "GO":
			return []string{"GOSH.ELF", "GONET.ELF"}
		}
		if word == "list" {
			listed = true
		}
		return nil
	}
	out := feedE(e, "ec\t")
	if !strings.Contains(out, "gosh> echo ") {
		t.Fatalf("single completion = %q", out)
	}
	// Several candidates: first Tab completes the common prefix ("c"),
	// second Tab lists them.
	feedE(e, "\r")
	out = feedE(e, "c\t")
	if !strings.Contains(out, "gosh> c") {
		t.Fatalf("common prefix = %q", out)
	}
	out = feedE(e, "\t")
	if !strings.Contains(out, "cat") || !strings.Contains(out, "cd") || !strings.Contains(out, "clear") {
		t.Fatalf("candidate list = %q", out)
	}
	if listed {
		t.Fatalf("the no-candidate branch fired early")
	}
	out = feedE(e, "\t") // a third Tab after the list: nothing new
	if strings.Count(out, "clear") != 0 {
		t.Fatalf("post-list Tab re-listed = %q", out)
	}
	// File candidates complete to the common prefix without a space.
	feedE(e, "\r")
	out = feedE(e, "GO\t")
	if !strings.Contains(out, "gosh> GO") {
		t.Fatalf("file prefix = %q", out)
	}
}

// TestHistoryBound pins the ring bound.
func TestHistoryBound(t *testing.T) {
	h := &History{}
	for i := 0; i < historyMax+10; i++ {
		h.Push(string(rune('a'+i%26)) + string(rune('0'+i/26)))
	}
	if len(h.Entries()) != historyMax {
		t.Fatalf("history bound = %d, want %d", len(h.Entries()), historyMax)
	}
}

// TestEditorBurstDrain pins the serial front-end's burst contract: one read
// can carry several whole lines (the class-B harness types its script in a
// single burst), Feed returns at most one event and holds the rest, so the
// session loop must feed with a nil chunk until Pending() is false. Without
// that drain every line after the first is typed but never run, which is
// exactly how the retargeted live-sh gate failed.
func TestEditorBurstDrain(t *testing.T) {
	e := NewEditor("gosh> ", &History{})
	burst := "echo abc\rcd /data\recho PWD=$PWD\rstatus43\r\x1b[A\r"
	out, ev := e.Feed([]byte(burst))
	if len(out) == 0 {
		t.Fatal("burst produced no tty output")
	}
	if ev.Kind != EvSubmit || ev.Line != "echo abc" {
		t.Fatalf("first event = kind %d line %q, want submit %q", ev.Kind, ev.Line, "echo abc")
	}
	if !e.Pending() {
		t.Fatal("editor dropped the rest of the burst instead of holding it")
	}
	var lines []string
	for e.Pending() {
		_, ev = e.Feed(nil)
		if ev.Kind != EvSubmit {
			t.Fatalf("drained event = kind %d, want submit", ev.Kind)
		}
		lines = append(lines, ev.Line)
	}
	want := []string{"cd /data", "echo PWD=$PWD", "status43", "status43"}
	if len(lines) != len(want) {
		t.Fatalf("drained %d lines %q, want %d", len(lines), lines, len(want))
	}
	for i := range want {
		if lines[i] != want[i] {
			t.Fatalf("drained line %d = %q, want %q", i, lines[i], want[i])
		}
	}
	// History took every *distinct* line in order, including the recall --
	// Push collapses a dup of the last entry, so the Up-recall of status43
	// does not add a fifth.
	if h := e.hist.Entries(); len(h) != 4 || h[3] != "status43" {
		t.Fatalf("history = %q, want four entries ending in status43", h)
	}
}

// TestEditorLineCap pins the interactive line bound: past maxLineBytes a
// keystroke answers with a bell instead of growing the buffer, and Tab
// completion cannot slip past the cap either.
func TestEditorLineCap(t *testing.T) {
	e := NewEditor("gosh> ", &History{})
	feedE(e, strings.Repeat("x", maxLineBytes))
	if len(e.buf) != maxLineBytes {
		t.Fatalf("line = %d bytes, want %d", len(e.buf), maxLineBytes)
	}
	out := feedE(e, "y")
	if len(e.buf) != maxLineBytes {
		t.Fatalf("line grew past the cap: %d bytes", len(e.buf))
	}
	if !strings.Contains(out, "\x07") {
		t.Fatalf("overflow keystroke = %q, want a bell", out)
	}
	// A completion that would pass the cap is refused the same way.
	e2 := NewEditor("gosh> ", &History{})
	e2.Complete = func(word string, first bool) []string { return []string{word + strings.Repeat("z", 64)} }
	feedE(e2, strings.Repeat("q", maxLineBytes))
	out = feedE(e2, "\t")
	if len(e2.buf) != maxLineBytes {
		t.Fatalf("completion grew past the cap: %d bytes", len(e2.buf))
	}
	if !strings.Contains(out, "\x07") {
		t.Fatalf("capped completion = %q, want a bell", out)
	}
}

// A lone ESC must not eat the next character. Escape followed by anything but
// '[' is not a sequence this keymap consumes, so the ESC is dropped and the
// character is ground input -- otherwise pressing Escape and then typing
// silently loses the keystroke. The kernel's keymap emits ESC [ X for every
// arrow/Home/End, so nothing legitimate arrives in the lone-ESC shape.
func TestEditorLoneEscDoesNotEatTheNextByte(t *testing.T) {
	e := NewEditor("gosh> ", &History{})
	// ESC in its own chunk: the editor parks in the escape state.
	if _, ev := e.Feed([]byte{0x1b}); ev.Kind != evNone {
		t.Fatalf("bare ESC produced event %d", ev.Kind)
	}
	// The next byte must land in the line, not vanish.
	out, ev := e.Feed([]byte("x"))
	if ev.Kind != evNone {
		t.Fatalf("typing after ESC produced event %d", ev.Kind)
	}
	if string(e.buf) != "x" {
		t.Fatalf("buf = %q want \"x\": the byte after a lone ESC was dropped", e.buf)
	}
	if !strings.Contains(string(out), "x") {
		t.Fatalf("repaint = %q, want the character painted", out)
	}
	// ESC inside a chunk behaves the same way.
	e2 := NewEditor("gosh> ", &History{})
	feedE(e2, "ab")
	repaint := feedE(e2, "\x1bcd")
	if string(e2.buf) != "abcd" {
		t.Fatalf("buf = %q want \"abcd\"", e2.buf)
	}
	if !strings.Contains(repaint, "abcd") {
		t.Fatalf("repaint = %q, want abcd", repaint)
	}
	// And the real sequences still work: ESC [ D is one cursor-left.
	e3 := NewEditor("gosh> ", &History{})
	feedE(e3, "ab")
	feedE(e3, "\x1b[D")
	if e3.cur != 1 {
		t.Fatalf("cur = %d want 1 after ESC [ D", e3.cur)
	}
}

// --- reverse-i-search (M45 SH3), retargeted into GOSH by M68b (#1450) ------

// drainFeed feeds a chunk the way the session loop does -- one Feed, then
// Feed(nil) until the editor holds nothing -- and collects every submitted
// line. This is the contract the serial front-end needs (a burst can carry
// several lines), and it is the only way search acceptance can be observed.
func drainFeed(e *Editor, s string) (string, []string) {
	w, ev := e.Feed([]byte(s))
	out := string(w)
	var lines []string
	if ev.Kind == EvSubmit {
		lines = append(lines, ev.Line)
	}
	for e.Pending() {
		var next []byte
		next, ev = e.Feed(nil)
		out += string(next)
		if ev.Kind == EvSubmit {
			lines = append(lines, ev.Line)
		}
	}
	return out, lines
}

// TestSearchGateChoreography walks the exact byte sequence live-sh-complete
// stages: run a command, then Ctrl+R + "status" + Enter (accept) + Enter
// (submit), and asserts the recall-and-rerun the gate counts.
func TestSearchGateChoreography(t *testing.T) {
	e := NewEditor("gosh> ", &History{})
	e.Complete = func(word string, first bool) []string {
		if strings.HasPrefix("help", word) {
			return []string{"help "}
		}
		return nil
	}
	// The gate runs `status43`, completes `hel` -> `help` and runs it.
	drainFeed(e, "status43\r")
	drainFeed(e, "hel\t\r")

	out, lines := drainFeed(e, "\x12status\r\r")
	if !strings.Contains(out, "reverse-i-search") {
		t.Fatalf("paint = %q, want the reverse-i-search prompt", out)
	}
	if len(lines) != 1 || lines[0] != "status43" {
		t.Fatalf("submitted %q, want exactly one status43 recall", lines)
	}
	// The recalled line went through the engine again, so "status43" appears
	// twice in the ring -- which is the gate's whole point (it counts
	// `status43: alive` twice).
	if h := e.hist.Entries(); len(h) != 3 || h[0] != "status43" || h[1] != "help " || h[2] != "status43" {
		t.Fatalf("history = %q, want [status43 hel-p-completed status43]", h)
	}
}

// TestSearchPaintShowsTheMatch pins what the user sees: the query, the
// newest-first substring match, and the match loaded as the live line.
func TestSearchPaintShowsTheMatch(t *testing.T) {
	h := &History{}
	h.Push("alpha-one")
	h.Push("beta-two")
	h.Push("alpha-three") // newest containing "alpha"
	e := NewEditor("gosh> ", h)
	feedE(e, "draft")
	out := feedE(e, "\x12")
	if !strings.Contains(out, "(reverse-i-search)`_`: (no match)") {
		t.Fatalf("empty-query paint = %q", out)
	}
	out = feedE(e, "a")
	if !strings.Contains(out, "(reverse-i-search)`a`: alpha-three") {
		t.Fatalf("first-byte paint = %q", out)
	}
	if string(e.buf) != "alpha-three" {
		t.Fatalf("buf = %q, want the match loaded", e.buf)
	}
	out = feedE(e, "lpha")
	if !strings.Contains(out, "(reverse-i-search)`alpha`: alpha-three") {
		t.Fatalf("paint = %q", out)
	}
	// A query that matches nothing says so and leaves the line as it was.
	out = feedE(e, "zz")
	if !strings.Contains(out, "(no match)") {
		t.Fatalf("no-match paint = %q", out)
	}
	if string(e.buf) != "alpha-three" {
		t.Fatalf("buf = %q, want the previous match kept", e.buf)
	}
}

// TestSearchCancelRestoresTheDraft: Esc and Ctrl-C both put the line back the
// way it was before Ctrl+R, so a search can never lose work.
func TestSearchCancelRestoresTheDraft(t *testing.T) {
	h := &History{}
	h.Push("status43")
	for _, cancel := range []string{"\x1b", "\x03"} {
		e := NewEditor("gosh> ", h)
		feedE(e, "half-typed")
		drainFeed(e, "\x12status")
		if string(e.buf) != "status43" {
			t.Fatalf("mid-search buf = %q", e.buf)
		}
		out := feedE(e, cancel)
		if e.searching {
			t.Fatalf("cancel %q left search mode on", cancel)
		}
		if string(e.buf) != "half-typed" || e.cur != len("half-typed") {
			t.Fatalf("cancel %q restored %q (cur %d), want half-typed", cancel, e.buf, e.cur)
		}
		if !strings.Contains(out, "half-typed") {
			t.Fatalf("cancel %q paint = %q, want the draft repainted", cancel, out)
		}
	}
}

// TestSearchBackspaceTrimsTheQuery: Backspace edits the QUERY, not the line,
// and re-runs the match on the shorter query.
func TestSearchBackspaceTrimsTheQuery(t *testing.T) {
	h := &History{}
	h.Push("status43")
	h.Push("status99")
	e := NewEditor("gosh> ", h)
	drainFeed(e, "\x12status")
	if string(e.buf) != "status99" {
		t.Fatalf("buf = %q want the newest match", e.buf)
	}
	out := feedE(e, "\x7f")
	if !strings.Contains(out, "(reverse-i-search)`statu") {
		t.Fatalf("paint = %q, want the trimmed query", out)
	}
	for len(e.query) > 1 { // trim down to a single byte
		feedE(e, "\x7f")
	}
	out = feedE(e, "\x7f") // 1 -> 0: the query is empty and nothing matches
	if len(e.query) != 0 {
		t.Fatalf("query = %q want empty", e.query)
	}
	if !strings.Contains(out, "(reverse-i-search)`_`: (no match)") {
		t.Fatalf("paint at the empty query = %q", out)
	}
	// One backspace past empty is a no-op with NO repaint, exactly as SH.BIN's
	// search_handle does it (query_len 0 -> return without redraw).
	if got := feedE(e, "\x7f"); got != "" {
		t.Fatalf("backspace past empty painted %q, want nothing", got)
	}
	if len(e.query) != 0 {
		t.Fatalf("backspace past empty left query %q", e.query)
	}
}

// TestSearchQueryIsBounded: the query buffer does not grow without limit.
func TestSearchQueryIsBounded(t *testing.T) {
	e := NewEditor("gosh> ", &History{})
	feedE(e, "\x12")
	feedE(e, strings.Repeat("q", maxSearchQuery))
	if len(e.query) != maxSearchQuery {
		t.Fatalf("query = %d bytes want %d", len(e.query), maxSearchQuery)
	}
	out := feedE(e, "q")
	if len(e.query) != maxSearchQuery {
		t.Fatalf("query grew past the cap: %d", len(e.query))
	}
	if !strings.Contains(out, "\x07") {
		t.Fatalf("overflow paint = %q, want a bell", out)
	}
}

// TestSearchAcceptedLineStillSubmits: after an accept, the NEXT return
// submits, and the editor is back in ground mode (typed characters land in
// the line again rather than feeding a query).
func TestSearchAcceptedLineStillSubmits(t *testing.T) {
	h := &History{}
	h.Push("echo hi")
	e := NewEditor("gosh> ", h)
	// Ctrl+R + query leaves the match loaded while search mode is still on.
	drainFeed(e, "\x12echo")
	if string(e.buf) != "echo hi" {
		t.Fatalf("buf = %q want the match loaded mid-search", e.buf)
	}
	if !e.searching {
		t.Fatal("query entry left search mode on by itself")
	}
	// The FIRST Return accepts the recall and must NOT also submit it.
	w, lines := drainFeed(e, "\r")
	if e.searching {
		t.Fatal("accept left search mode on")
	}
	if len(lines) != 0 {
		t.Fatalf("accept also submitted %q", lines)
	}
	if string(e.buf) != "echo hi" {
		t.Fatalf("buf = %q want the accepted recall", e.buf)
	}
	if !strings.Contains(w, "gosh> ") {
		t.Fatalf("accept paint = %q, want the prompt repainted", w)
	}
	// The SECOND Return submits the recalled line, like any accepted line.
	_, lines = drainFeed(e, "\r")
	if len(lines) != 1 || lines[0] != "echo hi" {
		t.Fatalf("after accept, Return submitted %q, want the recall", lines)
	}
	// Ground mode again: typing edits the fresh line.
	feedE(e, "X")
	if string(e.buf) != "X" {
		t.Fatalf("buf = %q, want post-search typing in a fresh line", e.buf)
	}
}

// TestSearchCancelRestoresMidLineCursor: cancel puts the draft back with the
// cursor where it sat, not only at end-of-line (TestSearchCancelRestoresTheDraft
// types to the end). A search must not lose a mid-line edit position.
func TestSearchCancelRestoresMidLineCursor(t *testing.T) {
	h := &History{}
	h.Push("status43")
	e := NewEditor("gosh> ", h)
	feedE(e, "abcdef")
	feedE(e, "\x1b[D\x1b[D\x1b[D") // cursor between c and d
	if e.cur != 3 {
		t.Fatalf("setup cur = %d want 3", e.cur)
	}
	drainFeed(e, "\x12status")
	out := feedE(e, "\x1b")
	if e.searching {
		t.Fatal("cancel left search mode on")
	}
	if string(e.buf) != "abcdef" || e.cur != 3 {
		t.Fatalf("cancel restored %q cur %d, want abcdef at 3", e.buf, e.cur)
	}
	if !strings.Contains(out, "abcdef") {
		t.Fatalf("cancel paint = %q, want the draft", out)
	}
}

// TestSearchCancelMidChunkDefersRemainder: an accept or cancel that ends
// search mid-chunk must hold the rest for the ground loop, the same path
// `Ctrl+R query CR CR` uses to accept then submit. Without the deferral the
// trailing bytes would vanish.
func TestSearchCancelMidChunkDefersRemainder(t *testing.T) {
	h := &History{}
	h.Push("status43")
	e := NewEditor("gosh> ", h)
	feedE(e, "half")
	_, ev := e.Feed([]byte("\x12st\x1bXYZ"))
	if ev.Kind != evNone {
		t.Fatalf("cancel chunk produced event %d", ev.Kind)
	}
	if !e.searching {
		t.Fatal("Ctrl+R did not enter search")
	}
	if !e.Pending() {
		t.Fatal("Ctrl+R dropped the rest of the chunk")
	}
	// Drain: query bytes, then Esc ends search and holds XYZ.
	for e.Pending() && e.searching {
		_, ev = e.Feed(nil)
		if ev.Kind != evNone {
			t.Fatalf("drain produced event %d", ev.Kind)
		}
	}
	if e.searching {
		t.Fatal("cancel left search mode on")
	}
	if string(e.buf) != "half" {
		t.Fatalf("buf after cancel = %q want the draft", e.buf)
	}
	if !e.Pending() {
		t.Fatal("cancel dropped the trailing ground bytes")
	}
	_, ev = e.Feed(nil)
	if ev.Kind != evNone {
		t.Fatalf("deferred typing produced event %d", ev.Kind)
	}
	if string(e.buf) != "halfXYZ" {
		t.Fatalf("deferred typing = %q want halfXYZ", e.buf)
	}
}

// TestSearchCtrlRMidChunkDefersQuery: Ctrl+R that arrives with query bytes
// in the same chunk must not insert those bytes into the line. The rest of
// the chunk is the query, consumed on the next Feed.
func TestSearchCtrlRMidChunkDefersQuery(t *testing.T) {
	h := &History{}
	h.Push("status43")
	e := NewEditor("gosh> ", h)
	feedE(e, "hello")
	_, ev := e.Feed([]byte("\x12status"))
	if ev.Kind != evNone {
		t.Fatalf("Ctrl+R chunk produced event %d", ev.Kind)
	}
	if !e.searching {
		t.Fatal("Ctrl+R did not enter search")
	}
	if string(e.buf) != "hello" {
		t.Fatalf("buf = %q, query bytes leaked into the line", e.buf)
	}
	if !e.Pending() {
		t.Fatal("Ctrl+R dropped the query bytes")
	}
	e.Feed(nil)
	if string(e.query) != "status" {
		t.Fatalf("query = %q want status", e.query)
	}
	if string(e.buf) != "status43" {
		t.Fatalf("buf = %q want the match loaded", e.buf)
	}
}

// --- M69f1 (#1537): the persistent-recall file shape ---------------------

// TestHistoryLoadReadsOldestFirst pins the format SaveHistory writes: UTF-8,
// LF, one command per line, oldest first.
func TestHistoryLoadReadsOldestFirst(t *testing.T) {
	var h History
	h.Load([]byte("one\ntwo\nthree\n"))
	if got, want := strings.Join(h.Entries(), ","), "one,two,three"; got != want {
		t.Fatalf("entries = %q want %q", got, want)
	}
}

// TestHistoryLoadSkipsTruncatedTail: a half-written append (no trailing LF)
// costs one line, never the whole file.
func TestHistoryLoadSkipsTruncatedTail(t *testing.T) {
	var h History
	h.Load([]byte("one\ntwo\npar"))
	if got, want := strings.Join(h.Entries(), ","), "one,two"; got != want {
		t.Fatalf("entries = %q want %q", got, want)
	}
}

// TestHistoryLoadTolerances: the empty file, a lone partial line, CRLF input
// and blank lines all reduce to the same ring the session would have built.
func TestHistoryLoadTolerances(t *testing.T) {
	var h History
	h.Load(nil)
	if got := h.Entries(); len(got) != 0 {
		t.Fatalf("empty load = %q want no entries", got)
	}
	h.Load([]byte("partial"))
	if got := h.Entries(); len(got) != 0 {
		t.Fatalf("partial-only load = %q want no entries", got)
	}
	h.Load([]byte("one\r\n\r\ntwo\r\n"))
	if got, want := strings.Join(h.Entries(), ","), "one,two"; got != want {
		t.Fatalf("crlf load = %q want %q", got, want)
	}
}

// TestHistoryLoadIsBounded: the file cannot grow the ring past historyMax.
func TestHistoryLoadIsBounded(t *testing.T) {
	var body []byte
	for i := 0; i < historyMax*2; i++ {
		body = append(body, []byte(fmt.Sprintf("line-%03d\n", i))...)
	}
	var h History
	h.Load(body)
	if got := len(h.Entries()); got != historyMax {
		t.Fatalf("ring after load = %d entries want %d", got, historyMax)
	}
}
