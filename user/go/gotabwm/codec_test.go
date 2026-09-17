package main

import (
	"bytes"
	"errors"
	"testing"

	"virelai/tools/go/tabcodec"
)

func pinnedCalcNotepad(t *testing.T) TabStrip {
	t.Helper()
	var s TabStrip
	if !s.OpenTab(3, "Calc") {
		t.Fatal("OpenTab Calc")
	}
	if !s.OpenTab(4, "Notepad") {
		t.Fatal("OpenTab Notepad")
	}
	if !s.Reorder(0, 1) {
		t.Fatal("Reorder")
	}
	if !s.Pin(3) {
		t.Fatal("Pin Calc")
	}
	if !s.FocusTab(4) {
		t.Fatal("FocusTab Notepad")
	}
	return s
}

func stripToTabcodec(s TabStrip) tabcodec.State {
	st := tabcodec.State{Tabs: make([]tabcodec.Tab, s.Count())}
	if s.Count() > 0 && s.focus >= 0 && s.focus < s.Count() {
		a := s.focus
		st.Active = &a
	}
	for i := 0; i < s.Count(); i++ {
		t0 := s.At(i)
		st.Tabs[i] = tabcodec.Tab{
			Title: t0.Title,
			Flags: pinFlag(t0),
			Bin:   t0.Bin,
		}
	}
	return st
}

// M62d/e: the strip's pin bit is the same byte tabcodec persists. The
// guest encoder matches tabcodec.Encode for Prefs=0 and in-range focus
// (this fixture: Seq=1, Prefs=0).
func TestSessionRoundTripTabcodec(t *testing.T) {
	if FlagPinned != tabcodec.FlagPinned {
		t.Fatalf("FlagPinned = %#x tabcodec.FlagPinned = %#x", FlagPinned, tabcodec.FlagPinned)
	}
	s := pinnedCalcNotepad(t)
	st := stripToTabcodec(s)
	st.Seq = 1
	want, err := tabcodec.Encode(st)
	if err != nil {
		t.Fatalf("tabcodec.Encode: %v", err)
	}
	got, ok := s.encodeTabsV2(1)
	if !ok {
		t.Fatal("encodeTabsV2")
	}
	if !bytes.Equal(got, want) {
		t.Fatalf("guest bytes != tabcodec\n got %x\nwant %x", got, want)
	}
	decoded, err := tabcodec.Decode(got)
	if err != nil {
		t.Fatalf("Decode: %v", err)
	}
	if decoded.Count() != 2 {
		t.Fatalf("count = %d", decoded.Count())
	}
	if decoded.Tabs[0].Title != "Calc" || decoded.Tabs[0].Flags&tabcodec.FlagPinned == 0 {
		t.Fatalf("record 0 = %+v; Calc must be pinned at left", decoded.Tabs[0])
	}
	if decoded.Tabs[1].Title != "Notepad" || decoded.Tabs[1].Flags&tabcodec.FlagPinned != 0 {
		t.Fatalf("record 1 = %+v", decoded.Tabs[1])
	}
	if decoded.Tabs[0].Bin != "CALC.BIN" || decoded.Tabs[1].Bin != "NOTEPAD.BIN" {
		t.Fatalf("bins %q %q", decoded.Tabs[0].Bin, decoded.Tabs[1].Bin)
	}
	ai, aok := decoded.ActiveIndex()
	if !aok || ai != 1 {
		t.Fatalf("active = %d ok=%v want 1 (Notepad)", ai, aok)
	}
}

func TestApplyStateRestoresTitlesPinActive(t *testing.T) {
	s := pinnedCalcNotepad(t)
	raw, ok := s.encodeTabsV2(7)
	if !ok {
		t.Fatal("encodeTabsV2")
	}
	var restored TabStrip
	seq, ok := restored.applyTabsV2(raw)
	if !ok {
		t.Fatal("applyTabsV2")
	}
	if seq != 7 {
		t.Fatalf("seq = %d want 7", seq)
	}
	if restored.Count() != 2 {
		t.Fatalf("count = %d", restored.Count())
	}
	if restored.At(0).Title != "Calc" || !restored.At(0).Pinned || restored.At(0).Bin != "CALC.BIN" {
		t.Fatalf("tab 0 = %+v", restored.At(0))
	}
	if restored.At(1).Title != "Notepad" || restored.At(1).Pinned || restored.At(1).Bin != "NOTEPAD.BIN" {
		t.Fatalf("tab 1 = %+v", restored.At(1))
	}
	if restored.focus != 1 {
		t.Fatalf("focus index = %d want 1", restored.focus)
	}
	if restored.At(0).ID == 0 || restored.At(1).ID == 0 {
		t.Fatal("placeholder ids must not be 0")
	}
	if line := MarkerSessionTitles + sessionTitlesLine(&restored); line != "gotabwm: session titles=Calc,Notepad pin=1,0 active=1" {
		t.Fatalf("titles line = %q", line)
	}
}

func TestApplyPreservesEmptyBin(t *testing.T) {
	st := tabcodec.State{Tabs: []tabcodec.Tab{{Title: "Calc"}}}
	raw, err := tabcodec.Encode(st)
	if err != nil {
		t.Fatalf("Encode: %v", err)
	}
	var s TabStrip
	if _, ok := s.applyTabsV2(raw); !ok {
		t.Fatal("applyTabsV2")
	}
	if s.At(0).Bin != "" {
		t.Fatalf("empty bin became %q (must not guessBin on restore)", s.At(0).Bin)
	}
	out, ok := s.encodeTabsV2(0)
	if !ok {
		t.Fatal("encodeTabsV2")
	}
	got, err := tabcodec.Decode(out)
	if err != nil {
		t.Fatalf("Decode: %v", err)
	}
	if got.Tabs[0].Bin != "" {
		t.Fatalf("re-encode bin = %q want empty", got.Tabs[0].Bin)
	}
}

func TestCorruptSessionFailsClosed(t *testing.T) {
	cases := [][]byte{
		{},
		{2},
		{2, 1, 2, 0, 0, 0}, // header claims 2 records, no body
		{1, 1, 0, 0, 0, 0}, // version 1
	}
	for i, raw := range cases {
		_, err := tabcodec.Decode(raw)
		if err == nil {
			t.Fatalf("case %d: tabcodec.Decode accepted corrupt bytes", i)
		}
		if !errors.Is(err, tabcodec.ErrCorrupt) {
			t.Fatalf("case %d: Decode %v, want ErrCorrupt", i, err)
		}
		_, _, _, _, ok := decodeTabsV2(raw)
		if ok {
			t.Fatalf("case %d: guest decode accepted corrupt bytes", i)
		}
		var s TabStrip
		if _, ok := s.applyTabsV2(raw); ok {
			t.Fatalf("case %d: applyTabsV2 accepted corrupt bytes", i)
		}
		if s.Count() != 0 {
			t.Fatalf("case %d: fail-closed left count = %d", i, s.Count())
		}
	}
}
