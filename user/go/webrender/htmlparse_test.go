package webrender

import (
	"strings"
	"testing"
)

func TestParseStructure(t *testing.T) {
	doc := ParseHTML([]byte(`<html><body><h1>Title</h1><p>Hello <a href="next.html">link</a> world</p></body></html>`))
	if doc.Root == nil {
		t.Fatal("no root")
	}
	h1 := findTag(doc.Root, "h1")
	if h1 == nil || TextContent(h1) != "Title" {
		t.Fatalf("h1 = %v", h1)
	}
	a := findTag(doc.Root, "a")
	if a == nil || a.Attr("href") != "next.html" {
		t.Fatalf("a = %v", a)
	}
	if got := TextContent(doc.Root); !strings.Contains(got, "Hello link world") {
		t.Fatalf("text = %q", got)
	}
}

func TestParseVoidAndSkip(t *testing.T) {
	doc := ParseHTML([]byte(`<p>a<br>b</p><script>var x = 1;</script><style>p{}</style><!-- c -->`))
	if strings.Contains(TextContent(doc.Root), "var x") {
		t.Fatal("script text leaked into content")
	}
	if strings.Contains(TextContent(doc.Root), "p{}") {
		t.Fatal("style text leaked into content")
	}
	if !strings.Contains(TextContent(doc.Root), "a b") {
		t.Fatalf("text = %q", TextContent(doc.Root))
	}
}

func TestParseMalformedNeverDropsText(t *testing.T) {
	inputs := []string{
		"<p>ok <<<< <em>unclosed",
		"plain text with < and > and &",
		"<div><p>a<p>b</div>",
		"<ul><li>one<li>two</ul>",
		"<td>orphan cell",
		"<not a tag at all <b>bold",
		strings.Repeat("<div>", 400) + "deep",
		"<p>trunc",
	}
	for _, in := range inputs {
		doc := ParseHTML([]byte(in))
		got := TextContent(doc.Root)
		if !strings.Contains(got, "ok") && !strings.Contains(got, "plain") && !strings.Contains(got, "a") &&
			!strings.Contains(got, "one") && !strings.Contains(got, "orphan") && !strings.Contains(got, "bold") &&
			!strings.Contains(got, "deep") && !strings.Contains(got, "trunc") {
			t.Fatalf("input %q lost all text: %q", in, got)
		}
	}
}

func TestParseCapsAreVisibleNotFatal(t *testing.T) {
	var sb strings.Builder
	for i := 0; i < MaxNodes+500; i++ {
		sb.WriteString("<p>x</p>")
	}
	doc := ParseHTML([]byte(sb.String()))
	if !doc.Truncated {
		t.Fatal("expected Truncated for oversized input")
	}
	if doc.Nodes > MaxNodes+8 {
		t.Fatalf("node cap exceeded: %d", doc.Nodes)
	}
}

func TestDecodeEntities(t *testing.T) {
	got := DecodeEntities("a&amp;b &lt;tag&gt; &quot;q&quot; &#39;s&#39; &#x41; &nbsp; &unknown;")
	want := "a&b <tag> \"q\" 's' A \u00a0 &unknown;"
	if got != want {
		t.Fatalf("got %q want %q", got, want)
	}
}

func FuzzHTML(f *testing.F) {
	seeds := []string{
		`<html><body><p>hi</p></body></html>`,
		`<<<>>>&&&;;;`,
		`<a href="x">y</a>`,
		`<table><tr><td>1</td></tr></table>`,
		`<pre>  spaced  </pre>`,
	}
	for _, s := range seeds {
		f.Add([]byte(s))
	}
	f.Fuzz(func(t *testing.T, data []byte) {
		doc := ParseHTML(data)
		if doc == nil || doc.Root == nil {
			t.Fatal("nil document")
		}
		// Must not panic, must terminate, and must stay inside the caps.
		if doc.Nodes > MaxNodes+8 {
			t.Fatalf("node cap exceeded: %d", doc.Nodes)
		}
		_ = TextContent(doc.Root)
	})
}

func findTag(n *Node, tag string) *Node {
	if n.Kind == KindElement && n.Tag == tag {
		return n
	}
	for _, c := range n.Children {
		if got := findTag(c, tag); got != nil {
			return got
		}
	}
	return nil
}
