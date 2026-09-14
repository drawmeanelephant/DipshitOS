package webrender

import (
	"strings"
	"testing"
)

func layoutFixture(t *testing.T, name string, width int) (*Document, *Layout) {
	t.Helper()
	src := mustReadTestdata(t, "testdata/"+name)
	doc := ParseHTML(src)
	return doc, LayoutDocument(doc, width, nil)
}

func TestLayoutHeadingSize(t *testing.T) {
	_, l := layoutFixture(t, "simple.html", 470)
	var h1 *Item
	for i := range l.Items {
		if l.Items[i].Kind == ItemText && strings.Contains(l.Items[i].Text, "VirelaiOS") {
			h1 = &l.Items[i]
			break
		}
	}
	if h1 == nil {
		t.Fatal("h1 text not laid out")
	}
	if h1.Size != 2 || !h1.Bold {
		t.Fatalf("h1 item = %+v", h1)
	}
	if h1.Y > 24 {
		t.Fatalf("h1 should sit near the top, y=%d", h1.Y)
	}
}

func TestLayoutWrapsParagraphs(t *testing.T) {
	_, l := layoutFixture(t, "simple.html", 200)
	rows := map[int]bool{}
	for _, it := range l.Items {
		if it.Kind == ItemText {
			rows[it.Y] = true
		}
	}
	if len(rows) < 6 {
		t.Fatalf("expected wrapping to produce many lines, got %d", len(rows))
	}
	for _, it := range l.Items {
		if it.Kind == ItemText && it.X+it.W > 200 {
			t.Fatalf("item overflows the content width: %+v", it)
		}
	}
}

func TestLayoutPrePreservesSpacing(t *testing.T) {
	_, l := layoutFixture(t, "simple.html", 470)
	found := false
	for _, it := range l.Items {
		if it.Kind == ItemText && it.Mono && strings.Contains(it.Text, "keeps   spacing") {
			found = true
		}
	}
	if !found {
		t.Fatal("pre text lost its spacing")
	}
}

func TestLayoutHrAndQuoteBar(t *testing.T) {
	_, l := layoutFixture(t, "simple.html", 470)
	rules, bars := 0, 0
	for _, it := range l.Items {
		if it.Kind == ItemRule && it.Color == ColorRule && it.W > 100 {
			rules++
		}
		if it.Kind == ItemRect && it.Bg == ColorAccent && it.H > 4 && it.W <= 4 {
			bars++
		}
	}
	if rules == 0 {
		t.Fatal("no <hr> rule emitted")
	}
	if bars == 0 {
		t.Fatal("no blockquote accent bar emitted")
	}
}

func TestLayoutListBullets(t *testing.T) {
	_, l := layoutFixture(t, "simple.html", 470)
	bullets := 0
	for _, it := range l.Items {
		if it.Kind == ItemText && it.Text == "*" {
			bullets++
		}
	}
	if bullets != 2 {
		t.Fatalf("bullets = %d want 2", bullets)
	}
}

func TestLayoutLinkHitTest(t *testing.T) {
	_, l := layoutFixture(t, "simple.html", 470)
	if len(l.Links) < 1 {
		t.Fatal("no link rectangles recorded")
	}
	k := l.Links[0]
	for _, lnk := range l.Links {
		if lnk.Target != "NEXT.HTML" {
			t.Fatalf("target = %q", lnk.Target)
		}
	}
	if k.Target != "NEXT.HTML" {
		t.Fatalf("target = %q", k.Target)
	}
	if got := HitTest(l, k.X+1, k.Y+1); got != "NEXT.HTML" {
		t.Fatalf("hit test = %q", got)
	}
	if got := HitTest(l, k.X-2, k.Y-2); got != "" {
		t.Fatalf("stray hit = %q", got)
	}
	underlined := false
	for _, it := range l.Items {
		if it.Kind == ItemRule && it.Color == ColorAccent {
			underlined = true
		}
	}
	if !underlined {
		t.Fatal("link underline missing")
	}
}

func TestLayoutTable(t *testing.T) {
	_, l := layoutFixture(t, "table.html", 470)
	cells := 0
	headerBold := false
	for _, it := range l.Items {
		if it.Kind == ItemText && strings.Contains(it.Text, "headings") {
			cells++
		}
		if it.Kind == ItemText && strings.Contains(it.Text, "Feature") && it.Bold {
			headerBold = true
		}
	}
	if cells < 1 {
		t.Fatalf("table cells laid out = %d", cells)
	}
	if !headerBold {
		t.Fatal("th should be bold")
	}
	if TextContent(mustParse(t, "table.html").Root) == "" {
		t.Fatal("empty text content")
	}
}

func TestLayoutBrokenStillReadable(t *testing.T) {
	_, l := layoutFixture(t, "broken.html", 470)
	var sb strings.Builder
	for _, it := range l.Items {
		if it.Kind == ItemText {
			sb.WriteString(it.Text)
			sb.WriteByte(' ')
		}
	}
	got := sb.String()
	for _, want := range []string{"ok", "bold text", "second", "orphan cell text"} {
		if !strings.Contains(got, want) {
			t.Fatalf("broken page lost %q; got %q", want, got)
		}
	}
	if l.Height <= 0 {
		t.Fatal("no height")
	}
}

func TestScrollMax(t *testing.T) {
	_, l := layoutFixture(t, "simple.html", 470)
	if ScrollMax(l, 10000) != 0 {
		t.Fatal("no scroll expected for a tall viewport")
	}
	if got := ScrollMax(l, 50); got != l.Height-50 {
		t.Fatalf("scroll max = %d want %d", got, l.Height-50)
	}
}

func TestLayoutTruncatesVisibly(t *testing.T) {
	var sb strings.Builder
	for i := 0; i < MaxItems; i++ {
		sb.WriteString("<p>line of text</p>")
	}
	doc := ParseHTML([]byte(sb.String()))
	l := LayoutDocument(doc, 300, nil)
	if !l.Truncated {
		t.Fatal("expected visible truncation flag")
	}
}

func mustParse(t *testing.T, name string) *Document {
	t.Helper()
	return ParseHTML(mustReadTestdata(t, "testdata/"+name))
}
