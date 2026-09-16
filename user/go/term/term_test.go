package main

import "testing"

func TestTermMarkerShapes(t *testing.T) {
	cases := []struct{ got, want string }{
		{markerOpen, "goterm: open id="},
		{markerDeclare, "goterm: declare accepted"},
		{markerTty, "goterm: tty"},
		{markerAttach, "goterm: attached"},
		{markerPrompt, "goterm: prompt"},
		{markerLine, "goterm: line "},
		{markerClose, "goterm: close"},
		{markerOK, "goterm OK"},
		{ttyPath, "/dev/tty"},
		{prompt, "goterm> "},
	}
	for _, c := range cases {
		if c.got != c.want {
			t.Fatalf("marker = %q want %q", c.got, c.want)
		}
	}
}

func TestLineBufSubmit(t *testing.T) {
	var l lineBuf
	typed := "echo hi"
	for i := 0; i < len(typed); i++ {
		if s, ok := l.feed(typed[i]); ok {
			t.Fatalf("premature submit %q after %q", s, typed[:i+1])
		}
	}
	s, ok := l.feed('\n')
	if !ok || s != "echo hi" {
		t.Fatalf("submit = (%q,%v) want (\"echo hi\", true)", s, ok)
	}
	if l.n != 0 {
		t.Fatal("buffer must reset after submit")
	}
}

func TestLineBufCR(t *testing.T) {
	var l lineBuf
	l.feed('x')
	s, ok := l.feed('\r')
	if !ok || s != "x" {
		t.Fatalf("CR submit = (%q,%v) want (\"x\", true)", s, ok)
	}
}

func TestLineBufEmptyLine(t *testing.T) {
	var l lineBuf
	s, ok := l.feed('\n')
	if !ok || s != "" {
		t.Fatalf("empty submit = (%q,%v) want (\"\", true)", s, ok)
	}
}

func TestLineBufCapsAtMax(t *testing.T) {
	var l lineBuf
	for i := 0; i < len(l.buf)+8; i++ {
		if _, ok := l.feed('a'); ok {
			t.Fatal("overflow must not submit")
		}
	}
	if l.n != len(l.buf) {
		t.Fatalf("n = %d want %d", l.n, len(l.buf))
	}
}
