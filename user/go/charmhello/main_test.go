//go:build virelai || charmhello

package main

import (
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"
)

func TestModelTogglesFromTeaKeyPress(t *testing.T) {
	next, _ := (model{}).Update(tea.KeyPressMsg(tea.Key{Text: " "}))
	got := next.(model)
	if !got.paused {
		t.Fatal("space did not toggle the Bubble Tea model")
	}
	if !strings.Contains(got.View().Content, "PAUSED") {
		t.Fatal("paused model view did not render the paused state")
	}
}

func TestModelQuitsFromTeaKeyPress(t *testing.T) {
	next, _ := (model{}).Update(tea.KeyPressMsg(tea.Key{Text: "q"}))
	if !next.(model).quit {
		t.Fatal("q did not request model shutdown")
	}
}

func TestViewCarriesBoundedAnsiSurface(t *testing.T) {
	view := (model{}).View().Content
	for _, want := range []string{"\x1b[?1049h", "\x1b[1;95m", "bound /dev/tty"} {
		if !strings.Contains(view, want) {
			t.Fatalf("view missing %q", want)
		}
	}
}
