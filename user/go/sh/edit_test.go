package main

import (
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
	if ev.Kind != evSubmit || ev.Line != "echo hi" {
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
	if ev.Kind != evCancel || !strings.Contains(string(out), "^C\r\n") {
		t.Fatalf("ctrl-c = (%q, %+v)", out, ev)
	}
	// Ctrl-D on an empty line is EOF; on a non-empty line it is ignored.
	_, ev = e.Feed([]byte("x\x04"))
	if ev.Kind != evNone {
		t.Fatalf("ctrl-d non-empty = %+v", ev)
	}
	_, ev = e.Feed([]byte("\x7f\x04"))
	if ev.Kind != evEOF {
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
	if ev.Kind != evSubmit || ev.Line != "two" {
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
