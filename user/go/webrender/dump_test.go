package webrender

import (
	"os"
	"testing"
)

// TestDumpItems prints the laid-out primitives for a fixture. It is a
// debugging aid: it only does work when WEBRENDER_DUMP names a fixture.
func TestDumpItems(t *testing.T) {
	name := os.Getenv("WEBRENDER_DUMP")
	if name == "" {
		t.Skip("set WEBRENDER_DUMP=<fixture.html> to dump items")
	}
	doc := ParseHTML(mustReadTestdata(t, "testdata/"+name))
	l := LayoutDocument(doc, 470, nil)
	t.Logf("nodes=%d blocks=%d lines=%d height=%d items=%d links=%d truncated=%v",
		doc.Nodes, l.Blocks, l.Lines, l.Height, len(l.Items), len(l.Links), l.Truncated)
	var walk func(n *Node, depth int)
	walk = func(n *Node, depth int) {
		if n.Kind == KindElement {
			t.Logf("%*s<%s> children=%d", depth*2, "", n.Tag, len(n.Children))
		}
		for _, c := range n.Children {
			walk(c, depth+1)
		}
	}
	walk(doc.Root, 0)
	t.Logf("collectRows=%d", len(collectRows(doc.Root)))
	for i, it := range l.Items {
		t.Logf("%3d kind=%d xy=(%d,%d) wh=(%d,%d) color=%#06x bg=%#06x text=%q",
			i, it.Kind, it.X, it.Y, it.W, it.H, it.Color, it.Bg, it.Text)
	}
}
