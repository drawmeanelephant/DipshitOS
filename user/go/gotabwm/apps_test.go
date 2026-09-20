package main

import (
	"os"
	"testing"
)

func TestParseAppsTXTSkipsCommentsAndCaps(t *testing.T) {
	text := "# VirelaiOS app manifest\n" +
		"GOCALC.ELF | 64-bit Calc | c | dock=true\n" +
		"\n" +
		"NOTE.ELF | Text Editor | n | dock=true\n" +
		"TABWM.BIN | Tabbed Desktop | m\n" +
		"BADLINE\n" +
		" | no-bin | x\n"
	got := parseAppsTXT(text)
	if len(got) != 3 {
		t.Fatalf("parse n=%d want 3: %+v", len(got), got)
	}
	if got[0].Bin != "GOCALC.ELF" || got[0].Label != "64-bit Calc" || !got[0].Dock || got[0].Icon != 'c' {
		t.Fatalf("row0 %+v", got[0])
	}
	if got[2].Dock {
		t.Fatal("TABWM.BIN must not be docked in the fixture")
	}
}

func TestParseAppsTXTRefusesDeletedNamesInHonestFixture(t *testing.T) {
	// The honest image/apps.txt must not list these; this pins the parser
	// still seeing them if a test feeds a lie.
	text := "NOTEPAD.ELF | Editor | n\nCALC.BIN | Calc | c\n"
	got := parseAppsTXT(text)
	if len(got) != 2 {
		t.Fatalf("parser must still accept the bytes: n=%d", len(got))
	}
}

func TestHonestImageAppsTxt(t *testing.T) {
	b, err := os.ReadFile("../../../image/apps.txt")
	if err != nil {
		t.Fatalf("read image/apps.txt: %v", err)
	}
	got := parseAppsTXT(string(b))
	want := map[string]bool{
		"GOCALC.ELF": true, "NOTE.ELF": true, "GOEDIT.ELF": true,
		"GOFILES.ELF": true, "WEB.ELF": true,
	}
	seen := map[string]bool{}
	for _, e := range got {
		seen[e.Bin] = true
		switch e.Bin {
		case "NOTEPAD.ELF", "CALC.BIN", "CALC.ELF", "FILE.ELF", "DESKTOP.ELF":
			t.Fatalf("honest catalog still offers %s", e.Bin)
		}
		if e.Bin == "TABWM.BIN" && e.Dock {
			t.Fatal("TABWM.BIN must not be a default dock target")
		}
	}
	for name := range want {
		if !seen[name] {
			t.Fatalf("honest catalog missing %s", name)
		}
	}
	if !seen["GOSH.ELF"] && !seen["GOTERM.ELF"] {
		t.Fatal("honest catalog missing GOSH.ELF and GOTERM.ELF")
	}
}

func TestFilterAppsSubstring(t *testing.T) {
	cat := []AppEntry{
		{Bin: "GOCALC.ELF", Label: "64-bit Calc"},
		{Bin: "NOTE.ELF", Label: "Text Editor"},
		{Bin: "WEB.ELF", Label: "Web"},
	}
	idx := filterApps(cat, "calc")
	if len(idx) != 1 || cat[idx[0]].Bin != "GOCALC.ELF" {
		t.Fatalf("filter calc = %v", idx)
	}
	idx = filterApps(cat, "ELF")
	if len(idx) != 3 {
		t.Fatalf("filter ELF n=%d", len(idx))
	}
	idx = filterApps(cat, "nope")
	if len(idx) != 0 {
		t.Fatalf("filter nope = %v", idx)
	}
	if n := filterApps(cat, ""); len(n) != 3 {
		t.Fatal("empty query is the full catalog")
	}
	idx = filterApps(cat, "CALC")
	if len(idx) != 1 || cat[idx[0]].Bin != "GOCALC.ELF" {
		t.Fatalf("ASCII fold CALC = %v", idx)
	}
}
