package appkit

import (
	"testing"

	"virelai/vi"
)

func key(usage, symbol uint32) vi.Event {
	return vi.Event{Kind: vi.EvKeyDown, Arg0: usage, Arg1: symbol}
}

func TestDialogCancelAndConfirm(t *testing.T) {
	d := NewConfirm("Save?", "Overwrite the file?")
	if !d.Open || d.Focus != 1 {
		t.Fatalf("new confirm = %+v", d)
	}
	if _, done := d.HandleKey(key(0x28, '\r')); !done || d.Open || d.Result != "No" {
		t.Fatalf("default confirm result = %+v", d)
	}

	d = NewConfirm("Save?", "Overwrite the file?")
	if changed, done := d.HandleKey(key(0x2b, '\t')); !changed || done {
		t.Fatalf("tab: changed=%v done=%v", changed, done)
	}
	if d.Focus != 0 {
		t.Fatalf("focus = %d, want 0", d.Focus)
	}
	if _, done := d.HandleKey(key(0x28, '\r')); !done || d.Open || d.Result != "Yes" {
		t.Fatalf("confirm result = %+v", d)
	}

	d = NewMessage("Notice", "Saved")
	if _, done := d.HandleKey(key(0x29, 0x1b)); !done || d.Open || d.Result != "cancel" {
		t.Fatalf("escape result = %+v", d)
	}
}

func TestDialogPromptEditsAndSelects(t *testing.T) {
	d := NewPrompt("Path", "Enter a file")
	for _, ch := range []uint32{'a', 'b', 'c'} {
		if changed, done := d.HandleKey(key(0, ch)); !changed || done {
			t.Fatalf("printable %c: changed=%v done=%v", ch, changed, done)
		}
	}
	if d.Input != "abc" {
		t.Fatalf("input = %q, want abc", d.Input)
	}
	if changed, done := d.HandleKey(key(0x2a, 0)); !changed || done {
		t.Fatalf("backspace: changed=%v done=%v", changed, done)
	}
	if d.Input != "ab" || !d.Open {
		t.Fatalf("after backspace = %+v", d)
	}
	if _, done := d.HandleKey(key(0x28, '\r')); !done || d.Open || d.Result != "ab" {
		t.Fatalf("prompt result = %+v", d)
	}
}

func TestDialogMouseChoosesHitButton(t *testing.T) {
	d := NewConfirm("Save?", "Overwrite?")
	button := d.Buttons[1]
	if _, done := d.HandleMouse(button.R.X+1, button.R.Y+1, true); !done {
		t.Fatal("button click did not complete dialog")
	}
	if d.Result != "No" || d.Open {
		t.Fatalf("mouse result = %+v", d)
	}
}
