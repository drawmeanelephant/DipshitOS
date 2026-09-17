package main

import (
	"testing"

	"virelai/tools/go/tabcodec"
)

// M62d: the strip's pin bit is the same byte tabcodec persists. Encode
// then Decode on the host (no VZ) must keep order, titles, and FlagPinned.
func TestSessionRoundTripTabcodec(t *testing.T) {
	if FlagPinned != tabcodec.FlagPinned {
		t.Fatalf("FlagPinned = %#x tabcodec.FlagPinned = %#x", FlagPinned, tabcodec.FlagPinned)
	}
	var s TabStrip
	s.OpenTab(3, "Calc")
	s.tabs[0].Bin = "CALC.BIN"
	s.OpenTab(4, "Notepad")
	s.tabs[1].Bin = "NOTEPAD.BIN"
	if !s.Reorder(0, 1) {
		t.Fatal("Reorder")
	}
	if !s.Pin(3) {
		t.Fatal("Pin Calc")
	}
	_ = s.FocusTab(4)

	active := s.focus
	st := tabcodec.State{
		Active: &active,
		Seq:    1,
		Tabs:   make([]tabcodec.Tab, s.Count()),
	}
	for i := 0; i < s.Count(); i++ {
		t0 := s.At(i)
		st.Tabs[i] = tabcodec.Tab{
			Title: t0.Title,
			Flags: pinFlag(t0),
			Bin:   t0.Bin,
		}
	}
	raw, err := tabcodec.Encode(st)
	if err != nil {
		t.Fatalf("Encode: %v", err)
	}
	got, err := tabcodec.Decode(raw)
	if err != nil {
		t.Fatalf("Decode: %v", err)
	}
	if got.Count() != 2 {
		t.Fatalf("count = %d", got.Count())
	}
	if got.Tabs[0].Title != "Calc" || got.Tabs[0].Flags&tabcodec.FlagPinned == 0 {
		t.Fatalf("record 0 = %+v; Calc must be pinned at left", got.Tabs[0])
	}
	if got.Tabs[1].Title != "Notepad" || got.Tabs[1].Flags&tabcodec.FlagPinned != 0 {
		t.Fatalf("record 1 = %+v", got.Tabs[1])
	}
	if got.Tabs[0].Bin != "CALC.BIN" || got.Tabs[1].Bin != "NOTEPAD.BIN" {
		t.Fatalf("bins %q %q", got.Tabs[0].Bin, got.Tabs[1].Bin)
	}
	ai, ok := got.ActiveIndex()
	if !ok || ai != 1 {
		t.Fatalf("active = %d ok=%v want 1 (Notepad)", ai, ok)
	}
}

func pinFlag(t Tab) uint8 {
	if t.Pinned {
		return FlagPinned
	}
	return 0
}
