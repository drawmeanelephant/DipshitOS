package shlib

import (
	"testing"
)

func TestHelpSectionsOrder(t *testing.T) {
	want := []string{"shell", "files", "environment", "scripts", "jobs",
		"identity", "tools", "externals"}
	got := HelpSections()
	if len(got) != len(want) {
		t.Fatalf("HelpSections() = %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("HelpSections()[%d] = %q, want %q", i, got[i], want[i])
		}
	}
}

// TestHelpRowsSingleSourced pins the export against the map itself: every
// row exists exactly once with verbatim fields, so GOHELP.ELF can never
// show help text GOSH would not print (the M74c no-forked-copy rule).
func TestHelpRowsSingleSourced(t *testing.T) {
	rows := HelpRows()
	if len(rows) != len(helpCatalog) {
		t.Fatalf("HelpRows() has %d rows, helpCatalog has %d", len(rows), len(helpCatalog))
	}
	seen := make(map[string]bool, len(rows))
	for _, r := range rows {
		if seen[r.Name] {
			t.Errorf("duplicate row %q", r.Name)
		}
		seen[r.Name] = true
		e, ok := helpCatalog[r.Name]
		if !ok {
			t.Errorf("row %q is not in helpCatalog", r.Name)
			continue
		}
		if r.Group != e.group || r.Usage != e.usage || r.Blurb != e.blurb || r.Notes != e.notes {
			t.Errorf("row %q drifted from helpCatalog: got %+v, want group=%q usage=%q blurb=%q notes=%q",
				r.Name, r, e.group, e.usage, e.blurb, e.notes)
		}
	}
	for name := range helpCatalog {
		if !seen[name] {
			t.Errorf("helpCatalog %q missing from HelpRows()", name)
		}
	}
}

func TestHelpRowsSectionAndNameOrder(t *testing.T) {
	rows := HelpRows()
	secs := HelpSections()
	secIdx := map[string]int{}
	for i, s := range secs {
		secIdx[s] = i
	}
	last := -1
	lastName := ""
	for _, r := range rows {
		si, ok := secIdx[r.Group]
		if !ok {
			t.Fatalf("row %q has unknown group %q", r.Name, r.Group)
		}
		if si < last {
			t.Errorf("row %q went back to section %q", r.Name, r.Group)
		}
		if si != last {
			lastName = ""
		}
		if lastName != "" && r.Name < lastName {
			t.Errorf("row %q sorts before %q inside section %q", r.Name, lastName, r.Group)
		}
		lastName = r.Name
		last = si
	}
}

func TestHelpRowEchoExact(t *testing.T) {
	for _, r := range HelpRows() {
		if r.Name != "echo" {
			continue
		}
		if r.Group != "shell" || r.Usage != "echo [ARG...]" {
			t.Errorf("echo row = %+v, want group=shell usage=echo [ARG...]", r)
		}
		if r.Notes == "" {
			t.Errorf("echo row lost its notes line")
		}
		return
	}
	t.Fatalf("no echo row in HelpRows()")
}
