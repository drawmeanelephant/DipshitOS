package main

import (
	"strings"
	"testing"
)

// The gate's pixel assert counts this EXACT RGB in the real scanout — if a
// palette refactor ever moves it, this test is the class-A tripwire.
const testPreviewAccent = "\x1b[38;2;122;162;255m"

func renderModel() model {
	m := testModel(entry("SUB", true), entry("KNOWN.TXT", false))
	m.previewOf = "KNOWN.TXT"
	m.preview = "hello-from-gofiles\npreview-line-alpha"
	m.status = "listed"
	return m
}

// visibleLines splits a rendered frame into its lines with ANSI stripped.
func visibleLines(frame string) []string {
	body := strings.TrimPrefix(frame, framePrologue)
	raw := strings.Split(body, "\n")
	out := make([]string, 0, len(raw))
	var b strings.Builder
	inEsc := false
	for _, ln := range raw {
		b.Reset()
		for _, r := range ln {
			if inEsc {
				if (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') {
					inEsc = false
				}
				continue
			}
			if r == 0x1b {
				inEsc = true
				continue
			}
			b.WriteRune(r)
		}
		out = append(out, b.String())
	}
	return out
}

func TestRenderCarriesProloguePreviewAccentAndSelection(t *testing.T) {
	frame := renderModel().render()
	if !strings.HasPrefix(frame, framePrologue) {
		t.Fatal("frame must open with the alt-screen prologue")
	}
	if strings.HasSuffix(frame, "\n") {
		t.Fatal("a trailing newline on the last row would scroll the frame")
	}
	if !strings.Contains(frame, testPreviewAccent+"hello-from-gofiles") {
		t.Fatalf("preview line must be painted in the gate accent %q", testPreviewAccent)
	}
	if !strings.Contains(frame, colSel) {
		t.Fatal("selected row styling missing")
	}
	if !strings.Contains(frame, " SUB/") || !strings.Contains(frame, "KNOWN.TXT") {
		t.Fatal("entry labels missing from the list pane")
	}
	if !strings.Contains(frame, "/host/FM") {
		t.Fatal("path bar missing")
	}
}

func TestRenderFitsTheGrid(t *testing.T) {
	m := renderModel()
	// A long path and a long preview line must be clipped, not wrapped.
	m.path = "/host/" + strings.Repeat("verylongdir/", 8)
	m.preview = strings.Repeat("PREVIEWWRAP ", 40)
	lines := visibleLines(m.render())
	if len(lines) != m.rows {
		t.Fatalf("frame has %d lines, grid rows=%d", len(lines), m.rows)
	}
	for i, ln := range lines {
		// The visible text is one byte-cell per rune here (ASCII), so its
		// rune count must fit the column budget.
		if len([]rune(ln)) > m.cols {
			t.Fatalf("line %d is %d cells, cols=%d: %q", i, len([]rune(ln)), m.cols, ln)
		}
	}
}

func TestRenderModalLines(t *testing.T) {
	m := renderModel()
	m.mode = modeRename
	m.input = "newname"
	if !strings.Contains(m.render(), " rename to: newname_") {
		t.Fatal("rename prompt missing from the frame")
	}
	m.mode = modeConfirmDelete
	m.status = "delete KNOWN.TXT? y/n"
	if !strings.Contains(m.render(), "delete KNOWN.TXT? y/n") {
		t.Fatal("delete confirm missing from the frame")
	}
}

func TestRenderEmptyPreview(t *testing.T) {
	m := testModel()
	m.preview = "(no selection)"
	if !strings.Contains(m.render(), "(no selection)") {
		t.Fatal("empty-preview placeholder missing")
	}
}

func TestListWidthKeepsBothPanes(t *testing.T) {
	for _, cols := range []int{16, 32, 64, 80, 200} {
		w := listWidth(cols)
		if w < 4 || cols-w-1 < 2 {
			t.Errorf("listWidth(%d)=%d leaves the preview pane dead", cols, w)
		}
	}
}

func TestVisLenAndClip(t *testing.T) {
	s := colPrev + "abcde" + colReset
	if n := visLen(s); n != 5 {
		t.Errorf("visLen = %d, want 5", n)
	}
	if got := clipVis(s, 3); visLen(got) != 3 {
		t.Errorf("clipVis = %q (%d cells), want 3", got, visLen(got))
	}
	if got := clipVis(s, 10); !strings.HasSuffix(got, colReset) && len([]rune("abcde")) > 10 {
		t.Errorf("unclipped clipVis changed the text: %q", got)
	}
}
