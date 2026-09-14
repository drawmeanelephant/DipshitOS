package main

import (
	"os"
	"strings"
	"testing"

	"virelai/webrender"
)

// The hostile fixture must render as inert text: the script body is dropped by
// the parser (not executed, not printed), and no element can turn an
// attribute into a file read or a request.
func TestHostileFixtureRendersInertText(t *testing.T) {
	src, err := os.ReadFile("testdata/hostile.html")
	if err != nil {
		t.Fatalf("fixture: %v", err)
	}
	doc := webrender.ParseHTML(src)
	lay := webrender.LayoutDocument(doc, contentW, nil)

	var text strings.Builder
	images := 0
	for _, it := range lay.Items {
		if it.Kind == webrender.ItemText {
			text.WriteString(it.Text)
			text.WriteByte(' ')
		}
		if it.Kind == webrender.ItemImage {
			images++
		}
	}
	got := text.String()
	for _, want := range []string{"Hostile page fixture", "inert", "End of hostile fixture."} {
		if !strings.Contains(got, want) {
			t.Fatalf("hostile page lost %q; rendered text: %q", want, got)
		}
	}
	for _, banned := range []string{"fetch(", "while(true)", "grab(", "WEB-HISTORY", "WEB-COOKIES", "WEB-CACHE", "10.0.0.2"} {
		if strings.Contains(got, banned) {
			t.Fatalf("hostile page leaked %q into the rendered text: %q", banned, got)
		}
	}
	if images == 0 {
		t.Fatal("the img placeholder was not laid out")
	}
	if lay.Height <= 0 || len(lay.Items) == 0 {
		t.Fatal("hostile page produced no layout")
	}
	// Links are recorded with their raw targets; it is the click path that
	// refuses the schemes (TestSchemeShapedTargetsAreRefused).
	if len(lay.Links) == 0 {
		t.Fatal("no links recorded from the hostile fixture")
	}
}

// The budget line is a shape contract with the gate: these markers must exist
// and must be emitted together.
func TestBudgetMarkersPinned(t *testing.T) {
	if markerBudget != "web: budget " || markerOver != "web: budget over " {
		t.Fatalf("budget markers changed: %q / %q", markerBudget, markerOver)
	}
}
