package feed

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func read(t *testing.T, name string) []byte {
	t.Helper()
	b, err := os.ReadFile(filepath.Join("testdata", name))
	if err != nil {
		t.Fatalf("read fixture %s: %v", name, err)
	}
	return b
}

// TestParseRSS2 checks each field of the parsed result against the raw fixture
// document, article by article.
func TestParseRSS2(t *testing.T) {
	f, err := Parse(read(t, "rss2.xml"))
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if f.Kind != KindRSS {
		t.Fatalf("kind = %q, want %q", f.Kind, KindRSS)
	}
	if f.Title != "Virelai Test Feed" {
		t.Errorf("title = %q", f.Title)
	}
	if f.Link != "http://10.0.0.2/" {
		t.Errorf("link = %q", f.Link)
	}
	if len(f.Articles) != 2 {
		t.Fatalf("articles = %d, want 2", len(f.Articles))
	}
	a := f.Articles[0]
	if a.Title != "First Post" || a.Link != "http://10.0.0.2/posts/1" {
		t.Errorf("article 0 = %+v", a)
	}
	if a.Date != "Mon, 21 Sep 2026 12:00:00 GMT" {
		t.Errorf("article 0 date = %q", a.Date)
	}
	if a.GUID != "urn:test:1" {
		t.Errorf("article 0 guid = %q", a.GUID)
	}
	// The second item has no <description>: content:encoded must fill summary.
	if got := f.Articles[1].Summary; got != "<p>Body of the second post.</p>" {
		t.Errorf("article 1 summary = %q", got)
	}
}

func TestParseAtom(t *testing.T) {
	f, err := Parse(read(t, "atom.xml"))
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if f.Kind != KindAtom {
		t.Fatalf("kind = %q, want %q", f.Kind, KindAtom)
	}
	if f.Title != "Virelai Atom Fixture" {
		t.Errorf("title = %q", f.Title)
	}
	// rel=alternate wins over rel=self for the feed link.
	if f.Link != "http://10.0.0.2/atom" {
		t.Errorf("feed link = %q", f.Link)
	}
	if len(f.Articles) != 2 {
		t.Fatalf("articles = %d, want 2", len(f.Articles))
	}
	if f.Articles[0].Title != "Atom One" || f.Articles[0].Link != "http://10.0.0.2/atom/1" {
		t.Errorf("article 0 = %+v", f.Articles[0])
	}
	if f.Articles[0].Date != "2026-09-21T08:00:00Z" {
		t.Errorf("article 0 date = %q (updated fallback)", f.Articles[0].Date)
	}
	if f.Articles[1].Date != "2026-09-22T10:00:00Z" {
		t.Errorf("article 1 date = %q (published preferred)", f.Articles[1].Date)
	}
	if f.Articles[1].GUID != "tag:virelai,2026:2" {
		t.Errorf("article 1 guid = %q", f.Articles[1].GUID)
	}
}

func TestParseRejectsNonFeed(t *testing.T) {
	_, err := Parse(read(t, "notfeed.html"))
	if !errors.Is(err, ErrNotFeed) {
		t.Fatalf("err = %v, want ErrNotFeed", err)
	}
}

func TestParseRejectsMalformed(t *testing.T) {
	_, err := Parse(read(t, "malformed.xml"))
	if !errors.Is(err, ErrMalformed) {
		t.Fatalf("err = %v, want ErrMalformed", err)
	}
}

func TestParseRejectsEmpty(t *testing.T) {
	if _, err := Parse([]byte("   \n")); !errors.Is(err, ErrEmpty) {
		t.Fatalf("err = %v, want ErrEmpty", err)
	}
}

func TestParseRDF(t *testing.T) {
	doc := []byte(`<?xml version="1.0"?>
<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
         xmlns="http://purl.org/rss/1.0/">
  <channel><title>RDF Feed</title><link>http://10.0.0.2/rdf</link></channel>
  <item rdf:about="http://10.0.0.2/rdf/1"><title>RDF One</title>
    <link>http://10.0.0.2/rdf/1</link></item>
</rdf:RDF>`)
	f, err := Parse(doc)
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if f.Kind != KindRDF || len(f.Articles) != 1 || f.Articles[0].Title != "RDF One" {
		t.Fatalf("rdf parse = %+v", f)
	}
}
