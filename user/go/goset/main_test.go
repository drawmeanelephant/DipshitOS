package main

import (
	"testing"

	"virelai/settings"
)

// The panel's markers are gate grep targets: pin the exact shapes so a drift is
// a host-test failure instead of a silent live miss.
func TestPanelMarkerShapes(t *testing.T) {
	want := map[string]string{
		markerOpen:     "goset: open id=",
		markerDeclare:  "goset: declare accepted",
		markerBad:      "goset: settings bad",
		markerReady:    "goset: ready ",
		markerSet:      "goset: set ",
		markerDiscard:  "goset: discard ",
		markerSaved:    "goset: saved ",
		markerRefused:  "goset: save refused",
		markerSaveFail: "goset: save failed rc=",
		markerPresent:  "goset: present",
		markerClose:    "goset: close",
		markerOK:       "goset OK",
	}
	for got, expect := range want {
		if got != expect {
			t.Fatalf("marker %q, want %q", got, expect)
		}
	}
}

// A panel on a share with no settings file starts from the table IN FORCE: the
// compiled defaults, so `wm` is visible and settable (card D2) even though the
// file has never carried it.
func TestPanelStartsWithTheTableInForce(t *testing.T) {
	a := newPanel(nil)
	if a.file.State != settings.StateMissing {
		t.Fatalf("host decode state = %d, want StateMissing (no file on the host)", a.file.State)
	}
	if v, ok := settings.Get(a.disp, "wm"); !ok || v != "gotabwm" {
		t.Fatalf("wm = %q ok=%v, want the compiled default", v, ok)
	}
	if a.mode() != "rw" {
		t.Fatalf("mode = %q, want rw", a.mode())
	}
	if got := a.summary(); got != "keys=8 wm=gotabwm theme=dark" {
		t.Fatalf("summary = %q", got)
	}
	if len(a.labels()) != len(a.disp) {
		t.Fatalf("labels = %d, rows = %d", len(a.labels()), len(a.disp))
	}
}

// The typed line is the path the gate drives. Only a key the kernel table
// knows is applied; anything else is dropped and never reaches the table.
func TestPanelAppliesATypedRowOnlyForKnownKeys(t *testing.T) {
	a := newPanel(nil)
	a.input = "wm=tabwm"
	if !a.applyInput() {
		t.Fatal("applyInput reported no change")
	}
	if a.input != "" {
		t.Fatalf("input not consumed: %q", a.input)
	}
	if v, _ := settings.Get(a.disp, "wm"); v != "tabwm" {
		t.Fatalf("wm = %q, want tabwm", v)
	}
	if got := a.summary(); got != "keys=8 wm=tabwm theme=dark" {
		t.Fatalf("summary = %q", got)
	}

	// An unknown key: named and dropped, table untouched.
	before := len(a.disp)
	a.input = "not_a_key=1"
	a.applyInput()
	if len(a.disp) != before {
		t.Fatalf("unknown key was written: %+v", a.disp)
	}
	if _, ok := settings.Get(a.disp, "not_a_key"); ok {
		t.Fatal("unknown key landed in the table")
	}

	// A line with no '=' is dropped too, and the input is still consumed.
	a.input = "tabwm"
	a.applyInput()
	if v, _ := settings.Get(a.disp, "wm"); v != "tabwm" {
		t.Fatalf("a bare word changed wm to %q", v)
	}
	if a.input != "" {
		t.Fatalf("bare-word input not consumed: %q", a.input)
	}
}

// Left/Right cycle the vocabularies the kernel declares; a free-text key is
// left alone rather than guessed at.
func TestPanelCyclesOnlyKnownVocabularies(t *testing.T) {
	a := newPanel(nil)
	a.sel = rowOf(t, a, "wm")
	if !a.cycle(1) {
		t.Fatal("cycle(wm) reported no change")
	}
	if v, _ := settings.Get(a.disp, "wm"); v != "tabwm" {
		t.Fatalf("wm = %q after one step", v)
	}
	a.cycle(-1)
	if v, _ := settings.Get(a.disp, "wm"); v != "gotabwm" {
		t.Fatalf("wm = %q after the step back", v)
	}
	// The Zig panel offered `amber`; the Go seat's reader refuses it, so the
	// panel's theme cycle must never produce it.
	a.sel = rowOf(t, a, "theme")
	for i := 0; i < 4; i++ {
		a.cycle(1)
		if v, _ := settings.Get(a.disp, "theme"); v != "dark" && v != "light" {
			t.Fatalf("theme cycle produced %q", v)
		}
	}
	// hostname is free text: no vocabulary, no invented value.
	a.sel = rowOf(t, a, "hostname")
	before, _ := settings.Get(a.disp, "hostname")
	if !a.cycle(1) {
		t.Fatal("cycle(hostname) reported no change (the frame should repaint)")
	}
	if v, _ := settings.Get(a.disp, "hostname"); v != before {
		t.Fatalf("hostname changed to %q", v)
	}
}

// A corrupt file is refused wholesale: the panel names it, shows the compiled
// defaults that are therefore in force, and refuses every write.
func TestPanelRefusesCorruptWrites(t *testing.T) {
	a := &panel{
		file: settings.File{State: settings.StateCorrupt},
		disp: settings.File{State: settings.StateMissing}.Display(),
	}
	if a.mode() != "ro" {
		t.Fatalf("mode = %q, want ro", a.mode())
	}
	if a.set("wm", "tabwm") {
		t.Fatal("a corrupt file accepted an edit")
	}
	if v, _ := settings.Get(a.disp, "wm"); v != "gotabwm" {
		t.Fatalf("wm = %q after a refused edit", v)
	}
	// save() must take the refusal path: StateCorrupt makes the codec refuse
	// (settings.SaveRefused) so nothing is ever written.
	if rc := (settings.File{State: settings.StateCorrupt}).Save(); rc != settings.SaveRefused {
		t.Fatalf("codec rc = %d, want SaveRefused", rc)
	}
	a.save()
}

// rowOf is the display index of a key (the tests select rows by name, not by
// a hardcoded ordinal that a table reorder would silently invalidate).
func rowOf(t *testing.T, a *panel, key string) int {
	t.Helper()
	for i, s := range a.disp {
		if s.Key == key {
			return i
		}
	}
	t.Fatalf("no row for %q in %+v", key, a.disp)
	return -1
}
