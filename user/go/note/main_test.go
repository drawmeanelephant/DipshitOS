package main

import (
	"testing"

	"virelai/tabapp"
	"virelai/vi"
	"virelai/webrender/font"
)

func keyDown(arg0, arg1 uint32) vi.Event {
	return vi.Event{Kind: vi.EvKeyDown, Arg0: arg0, Arg1: arg1}
}

// The two paths the save test distinguishes, and the lengths a faked syscall
// sees. A path argument reaches the hook as (pointer, length); the length alone
// separates the sacrificial temp from the live file (they differ by ".tmp"), so
// the test needs no uintptr-to-pointer conversion -- virelai/vi's own tests do
// that with unsafe, and duplicating the pattern here would add a second
// `possible misuse of unsafe.Pointer` to `go vet` for no extra coverage.
const (
	livePathLen = uintptr(len(defaultPath))
	tmpPathLen  = uintptr(len(defaultPath) + len(".tmp"))
)

// The key path end to end, at the byte level: what arrives from the kernel
// (ADR 0009: HID usage in arg0, decoded symbol in arg1) and what the buffer
// holds afterwards. The arrows are the interesting half — they are read from
// arg0, and reading them from arg1 (where they are 0) is a silent no-op that
// only shows up on the VM.
func TestKeyPath(t *testing.T) {
	a := &app{buf: NewBuffer(), top: 1}
	a.buf.InsertText("ab\ncd")

	if !a.key(keyDown(0, 'x')) {
		t.Fatal("a printable symbol did not report a change")
	}
	if got := string(a.buf.Bytes()); got != "ab\ncdx" {
		t.Fatalf("after typing x: %q", got)
	}
	if !a.key(keyDown(0, codeReturn)) {
		t.Fatal("Return did not report a change")
	}
	if got := string(a.buf.Bytes()); got != "ab\ncdx\n" {
		t.Fatalf("after Return: %q", got)
	}

	// Arrows: arg0 carries the usage, arg1 is 0.
	a.buf.SetCursor(0)
	if !a.key(keyDown(hidRight, 0)) || a.buf.Cursor() != 1 {
		t.Fatalf("Right: cursor=%d want 1", a.buf.Cursor())
	}
	if !a.key(keyDown(hidDown, 0)) || a.buf.Line() != 2 {
		t.Fatalf("Down: line=%d want 2", a.buf.Line())
	}
	if !a.key(keyDown(hidUp, 0)) || a.buf.Line() != 1 {
		t.Fatalf("Up: line=%d want 1", a.buf.Line())
	}
	if !a.key(keyDown(hidLeft, 0)) || a.buf.Cursor() != 0 {
		t.Fatalf("Left: cursor=%d want 0", a.buf.Cursor())
	}
	if a.key(keyDown(hidLeft, 0)) {
		t.Fatal("Left at offset 0 reported a change")
	}

	// Delete takes the byte AT the caret; backspace takes the one before it.
	a.buf.SetCursor(1)
	if !a.key(keyDown(0, codeDelete)) {
		t.Fatal("Delete did not report a change")
	}
	if got := string(a.buf.Bytes()); got != "a\ncdx\n" {
		t.Fatalf("after Delete: %q", got)
	}
	if a.buf.Cursor() != 1 {
		t.Fatalf("Delete moved the caret to %d", a.buf.Cursor())
	}
	if !a.key(keyDown(0, codeBackspace)) {
		t.Fatal("Backspace did not report a change")
	}
	if got := string(a.buf.Bytes()); got != "\ncdx\n" {
		t.Fatalf("after Backspace: %q", got)
	}

	// A WM chord is not ours: it must change nothing and ask for no repaint.
	before := string(a.buf.Bytes())
	ev := vi.Event{Kind: vi.EvKeyDown, Flags: modCtrl, Arg1: 'c'}
	if a.key(ev) {
		t.Fatal("a Ctrl chord reported a change")
	}
	if got := string(a.buf.Bytes()); got != before {
		t.Fatalf("a Ctrl chord edited the buffer: %q", got)
	}
	// A non-key event (a resize, say) is not an edit either.
	if a.key(vi.Event{Kind: vi.EvWinResize, Arg0: 800, Arg1: 600}) {
		t.Fatal("a resize reported an edit")
	}
}

func TestInsertionFor(t *testing.T) {
	cases := []struct {
		name string
		ev   vi.Event
		want byte
		ok   bool
	}{
		{"space", keyDown(0, 0x20), ' ', true},
		{"tilde", keyDown(0, 0x7e), '~', true},
		{"enter", keyDown(0x28, codeReturn), '\n', true},
		{"newline", keyDown(0, codeNewline), '\n', true},
		{"control code", keyDown(0, 0x01), 0, false},
		{"delete", keyDown(0, codeDelete), 0, false},
		{"non-ascii", keyDown(0, 0x80), 0, false},
		{"arrow", keyDown(hidRight, 0), 0, false},
		{"chord", vi.Event{Kind: vi.EvKeyDown, Flags: modCtrl, Arg1: 'a'}, 0, false},
		{"key up", vi.Event{Kind: vi.EvKeyUp, Arg1: 'a'}, 0, false},
	}
	for _, c := range cases {
		got, ok := insertionFor(c.ev)
		if got != c.want || ok != c.ok {
			t.Fatalf("%s: insertionFor = %q,%v want %q,%v", c.name, got, ok, c.want, c.ok)
		}
	}
}

func TestIsSave(t *testing.T) {
	if !isSave(vi.Event{Kind: vi.EvKeyDown, Flags: modCtrl, Arg1: keyCtrlS}) {
		t.Fatal("Ctrl-S (control code) was not recognised")
	}
	if !isSave(vi.Event{Kind: vi.EvKeyDown, Flags: modCtrl, Arg1: keyS}) {
		t.Fatal("Ctrl-S (letter) was not recognised")
	}
	if isSave(keyDown(0, keyS)) {
		t.Fatal("a plain 's' was mistaken for the save chord")
	}
	if isSave(vi.Event{Kind: vi.EvKeyUp, Flags: modCtrl, Arg1: keyS}) {
		t.Fatal("a key-UP edge was mistaken for the save chord")
	}
}

// The frame geometry: how many rows and columns a canvas holds, and the clamps
// that keep a tiny canvas drawable. A zero canvas falls back to the native size
// rather than dividing by it.
func TestGeometry(t *testing.T) {
	a := &app{buf: NewBuffer(), ta: &tabapp.TabApp{W: natW, H: natH}}
	wantRows := (natH - chromeH - statusH) / lineH
	if got := a.rowsIn(); got != wantRows {
		t.Fatalf("rowsIn = %d want %d", got, wantRows)
	}
	if got, want := a.colsIn(), (natW-2*textOrigin)/font.Advance(1); got != want {
		t.Fatalf("colsIn = %d want %d", got, want)
	}
	// A canvas smaller than a row still holds one row: the caret must not
	// disappear on a drag-resize.
	a.ta.H = 10
	a.ta.W = 4
	if got := a.rowsIn(); got != 1 {
		t.Fatalf("rowsIn on a tiny canvas = %d want 1", got)
	}
	if got := a.colsIn(); got != 1 {
		t.Fatalf("colsIn on a tiny canvas = %d want 1", got)
	}
	// No window at all: the geometry must still answer.
	empty := &app{buf: NewBuffer()}
	if empty.rowsIn() != 1 || empty.colsIn() < 1 {
		t.Fatal("geometry with no window must fall back, not divide by zero")
	}
}

// The load/save decision path, exercised on the host where every syscall is
// -ENOSYS. That is a real outcome to pin: the app must report a refusal rather
// than panic, and the marker has to name what happened.
func TestLoadSaveOutcomesOnHost(t *testing.T) {
	a := &app{buf: NewBuffer(), path: defaultPath, top: 1}
	got := a.load()
	if len(got) < len(markerLoadErr) || got[:len(markerLoadErr)] != markerLoadErr {
		t.Fatalf("host load marker = %q want a %q prefix (the host file channel is -ENOSYS)", got, markerLoadErr)
	}
	if a.buf.Len() != 0 {
		t.Fatalf("a refused load left %d bytes in the buffer", a.buf.Len())
	}
	// The buffer is dirty first, because that is the state the close path acts
	// on: a refused save must NOT clear it, or a tab closed after a failed
	// Ctrl-S would behave as though the edit had been written.
	a.dirty = true
	got = a.save()
	if len(got) < len(markerSaveErr) || got[:len(markerSaveErr)] != markerSaveErr {
		t.Fatalf("host save marker = %q want a %q prefix", got, markerSaveErr)
	}
	if !a.dirty {
		t.Fatal("a failed save cleared the dirty bit: the close path would not retry it")
	}
}

// The success path of save(), pinned at the seam: the app must publish through
// vi.WriteFileSafe (temp -> fsync -> rename), not the open/write/truncate it
// shipped with, and it must report the bytes it published while clearing the
// dirty bit. M66b (#1444) pins that primitive's own wire in vi_test.go; what
// this pins is that the notepad is actually on it -- the swap was a choice, and
// a silent regression to in-place truncation would otherwise pass every test
// here (the host has no file channel, so the failure path is all this package
// could see before this test existed).
func TestSavePublishesThroughWriteFileSafe(t *testing.T) {
	var seq []uintptr
	prev := vi.SetSyscallHookForTest(func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
		seq = append(seq, num)
		switch num {
		case vi.SlotFileOpen:
			// The load-bearing one: opening the LIVE path means the app went
			// back to truncating in place.
			if a1 != tmpPathLen {
				t.Fatalf("open path length = %d, want %d (the temp); %d would be the live path",
					a1, tmpPathLen, livePathLen)
			}
			return 1
		case vi.SlotFileWrite:
			return int64(a2)
		case vi.SlotFileSync, vi.SlotFileClose, vi.SlotFileDelete:
			return 0
		case vi.SlotFileRename:
			if a1 != tmpPathLen {
				t.Fatalf("rename from length = %d, want %d (the temp)", a1, tmpPathLen)
			}
			if a3 != livePathLen {
				t.Fatalf("rename to length = %d, want %d (the live path)", a3, livePathLen)
			}
			return 0
		}
		t.Fatalf("unexpected slot %d", num)
		return 0
	})
	defer vi.SetSyscallHookForTest(prev)

	a := &app{buf: NewBuffer(), path: defaultPath, top: 1}
	a.buf.InsertText("alpha\nbeta\n")
	a.dirty = true

	if got, want := a.save(), markerSaved+"11"; got != want {
		t.Fatalf("save marker = %q want %q", got, want)
	}
	if a.dirty {
		t.Fatal("a successful save must clear the dirty bit, or the close path saves again")
	}
	for _, s := range seq {
		if s == vi.SlotFileTruncate {
			t.Fatal("save truncated the live path in place: the crash-safe writer never does")
		}
	}
	if len(seq) == 0 || seq[0] != vi.SlotFileOpen || seq[len(seq)-1] != vi.SlotFileRename {
		t.Fatalf("call sequence = %v, want open ... rename", seq)
	}
}

// The absent-file case is the ordinary first run: it must be distinguishable
// from an error, because the seat specs assert the difference.
func TestLoadMissMarker(t *testing.T) {
	if markerMiss == markerLoadErr || markerMiss == markerLoaded {
		t.Fatal("the three load outcomes must be distinguishable markers")
	}
	a := &app{buf: NewBuffer(), path: defaultPath}
	a.buf.Load([]byte("hello"))
	if got := a.cursorMarker(); got < markerCursor {
		t.Fatalf("cursor marker = %q", got)
	}
}
