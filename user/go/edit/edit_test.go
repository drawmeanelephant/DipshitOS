package main

import (
	"testing"

	"virelai/vi"
)

// The gate greps these exact strings; a drift is a host-test failure rather
// than a live run that silently asserts nothing.
func TestEditMarkerShapes(t *testing.T) {
	cases := []struct{ got, want string }{
		{markerOpen, "goedit: open id="},
		{markerDeclare, "goedit: declare accepted"},
		{markerRead, "goedit: read "},
		{markerPresent, "goedit: present"},
		{markerDirty, "goedit: dirty"},
		{markerSaved, "goedit: saved "},
		{markerSaveErr, "goedit: save error "},
		{markerClose, "goedit: close"},
		{markerOK, "goedit OK"},
	}
	for _, c := range cases {
		if c.got != c.want {
			t.Fatalf("marker = %q want %q", c.got, c.want)
		}
	}
}

// The kernel puts the Unicode codepoint in arg1, so the mapping from an event
// to an inserted byte is the contract the gate's typed characters ride.
func TestInsertionFor(t *testing.T) {
	down := func(arg1 uint32, flags uint16) vi.Event {
		return vi.Event{Kind: vi.EvKeyDown, Flags: flags, Arg1: arg1}
	}
	ok := []struct {
		ev   vi.Event
		want byte
	}{
		{down('a', 0), 'a'},
		{down('Z', 0), 'Z'},
		{down(' ', 0), ' '},
		{down('~', 0), '~'},
		{down(codeReturn, 0), '\n'},
	}
	for _, c := range ok {
		got, gotOK := insertionFor(c.ev)
		if !gotOK || got != c.want {
			t.Fatalf("insertionFor(%#x) = (%q,%v) want (%q,true)", c.ev.Arg1, got, gotOK, c.want)
		}
	}
	bad := []vi.Event{
		down(0x1b, 0),                         // escape
		down('a', modCtrl),                    // a chord, not text
		vi.Event{Kind: vi.EvKeyUp, Arg1: 'a'}, // key up
		vi.Event{Kind: 18, Arg1: 'a'},         // COMPOSITE_TICK
		down(0x7f, 0),                         // delete is not an insertion
	}
	for _, ev := range bad {
		if b, o := insertionFor(ev); o {
			t.Fatalf("insertionFor(%+v) = (%q,true) want not-insertable", ev, b)
		}
	}
}

func TestIsSave(t *testing.T) {
	if !isSave(vi.Event{Kind: vi.EvKeyDown, Flags: modCtrl, Arg1: keyS}) {
		t.Fatal("ctrl-s must be the save chord")
	}
	// kernel/src/input.zig puts the derived ASCII char in arg1; for a Ctrl
	// chord that is the control code, so the save chord must accept both.
	if !isSave(vi.Event{Kind: vi.EvKeyDown, Flags: modCtrl, Arg1: keyCtrlS}) {
		t.Fatal("ctrl-s must save whether arg1 carries 's' or 0x13")
	}
	if isSave(vi.Event{Kind: vi.EvKeyDown, Flags: 0, Arg1: keyS}) {
		t.Fatal("a bare s must not save")
	}
	if isSave(vi.Event{Kind: vi.EvKeyDown, Flags: modCtrl, Arg1: 'x'}) {
		t.Fatal("ctrl-x must not save")
	}
}

// insert/backspace own the buffer and the dirty flag.
func TestBufferEdits(t *testing.T) {
	e := &editor{}
	if !e.insert('h') || !e.insert('i') {
		t.Fatal("insert must report an edit")
	}
	if string(e.buf) != "hi" {
		t.Fatalf("buf = %q want \"hi\"", e.buf)
	}
	if !e.dirty {
		t.Fatal("an edit must set dirty")
	}
	if !e.backspace() {
		t.Fatal("backspace must report an edit")
	}
	if string(e.buf) != "h" {
		t.Fatalf("buf = %q want \"h\"", e.buf)
	}
	e.buf = e.buf[:0]
	if e.backspace() {
		t.Fatal("backspace on an empty buffer must be a no-op")
	}
}

// markDirty prints once: the dirty marker is an edge, not a per-keystroke spam.
func TestMarkDirtyIsAnEdge(t *testing.T) {
	e := &editor{}
	e.markDirty()
	if !e.dirty {
		t.Fatal("markDirty must set the flag")
	}
	e.markDirty()
	if !e.dirty {
		t.Fatal("markDirty must stay set")
	}
}
