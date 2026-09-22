package store

import (
	"errors"
	"testing"

	"virelai/rss/feed"
)

// memIO is a fault-injectable in-memory FileIO: it models the guest share
// closely enough for the host test run (flat paths, whole-file writes).
type memIO struct {
	files map[string][]byte
	fail  error
}

func newMem() *memIO { return &memIO{files: map[string][]byte{}} }

func (m *memIO) Read(path string) ([]byte, error) {
	if m.fail != nil {
		return nil, m.fail
	}
	b, ok := m.files[path]
	if !ok {
		return nil, ErrNoFile
	}
	return b, nil
}

func (m *memIO) Write(path string, b []byte) error {
	if m.fail != nil {
		return m.fail
	}
	cp := make([]byte, len(b))
	copy(cp, b)
	m.files[path] = cp
	return nil
}

func (m *memIO) Delete(path string) error {
	if m.fail != nil {
		return m.fail
	}
	delete(m.files, path)
	return nil
}

func TestOPMLRoundTrip(t *testing.T) {
	in := []Subscription{
		{Title: "Test Feed", URL: "http://10.0.0.2/feed.xml"},
		{Title: "Atom & Friends", URL: "https://example.com/a?b=1&c=2"},
		{Title: "", URL: "http://10.0.0.2/third"},
	}
	out, err := DecodeOPML(EncodeOPML(in))
	if err != nil {
		t.Fatalf("DecodeOPML: %v", err)
	}
	if len(out) != len(in) {
		t.Fatalf("count = %d, want %d", len(out), len(in))
	}
	for i := range in {
		want := in[i]
		if want.Title == "" {
			want.Title = want.URL // encode empty title, decode falls back to URL
		}
		if out[i] != want {
			t.Errorf("entry %d = %+v, want %+v", i, out[i], want)
		}
	}
}

func TestDecodeOPMLTolerant(t *testing.T) {
	// Nested folders, mixed attribute case, and outlines without xmlUrl.
	doc := []byte(`<?xml version="1.0"?>
<opml version="1.0"><head><title>x</title></head><body>
  <outline text="Group">
    <outline text="Nested" type="rss" XMLURL="http://10.0.0.2/n"/>
    <outline text="Not a feed"/>
  </outline>
  <outline title="Second" xmlUrl="http://10.0.0.2/s"/>
</body></opml>`)
	subs, err := DecodeOPML(doc)
	if err != nil {
		t.Fatalf("DecodeOPML: %v", err)
	}
	if len(subs) != 2 {
		t.Fatalf("subs = %d, want 2: %+v", len(subs), subs)
	}
	if subs[0].URL != "http://10.0.0.2/n" || subs[0].Title != "Nested" {
		t.Errorf("nested = %+v", subs[0])
	}
	if _, err := DecodeOPML([]byte("<html></html>")); !errors.Is(err, ErrNotOPML) {
		t.Errorf("non-OPML err = %v, want ErrNotOPML", err)
	}
}

func TestSubsPersistenceAndMissingFile(t *testing.T) {
	io := newMem()
	s := New(io, "/host")
	if _, err := s.LoadSubs(); !errors.Is(err, ErrNoFile) {
		t.Fatalf("missing file err = %v, want ErrNoFile", err)
	}
	subs := []Subscription{{Title: "A", URL: "http://10.0.0.2/a"}}
	if err := s.SaveSubs(subs); err != nil {
		t.Fatalf("SaveSubs: %v", err)
	}
	subsPath, _, _ := s.Paths()
	if subsPath != "/host/RSS.OPML" {
		t.Fatalf("subs path = %q", subsPath)
	}
	got, err := s.LoadSubs()
	if err != nil || len(got) != 1 || got[0].URL != "http://10.0.0.2/a" {
		t.Fatalf("reload = %+v err=%v", got, err)
	}
}

func TestStateRoundTripAndAbsence(t *testing.T) {
	io := newMem()
	s := New(io, "/host")
	st, err := s.LoadState()
	if !errors.Is(err, ErrNoFile) {
		t.Fatalf("missing state err = %v, want ErrNoFile", err)
	}
	if st.Read == nil || len(st.Read) != 0 {
		t.Fatalf("empty state must have a non-nil empty map, got %+v", st.Read)
	}
	st.Read["urn:test:1"] = true
	st.Read["urn:test:2"] = false // false must not be persisted
	st.Read["urn:test:3"] = true
	st.LastFeed = "http://10.0.0.2/feed.xml"
	if err := s.SaveState(st); err != nil {
		t.Fatalf("SaveState: %v", err)
	}
	got, err := s.LoadState()
	if err != nil {
		t.Fatalf("LoadState: %v", err)
	}
	if !got.Read["urn:test:1"] || !got.Read["urn:test:3"] || got.Read["urn:test:2"] {
		t.Fatalf("read set = %+v", got.Read)
	}
	if got.LastFeed != "http://10.0.0.2/feed.xml" {
		t.Fatalf("lastfeed = %q", got.LastFeed)
	}
	// The on-disk state can be inspected to confirm a given article was read.
	statePath := "/host/RSS.STATE"
	if _, ok := io.files[statePath]; !ok {
		t.Fatalf("state file not written at %s", statePath)
	}
	if !contains(io.files[statePath], `key="urn:test:1"`) {
		t.Fatalf("state file does not record urn:test:1:\n%s", io.files[statePath])
	}
}

func TestCacheBounded(t *testing.T) {
	io := newMem()
	s := New(io, "/host")
	c := Cache{}
	for i := 0; i < 10; i++ {
		var arts []feed.Article
		for j := 0; j < 50; j++ {
			arts = append(arts, feed.Article{Title: "t", GUID: "g"})
		}
		c["feed-"+string(rune('a'+i))] = arts
	}
	if err := s.SaveCache(c); err != nil {
		t.Fatalf("SaveCache: %v", err)
	}
	got, err := s.LoadCache()
	if err != nil {
		t.Fatalf("LoadCache: %v", err)
	}
	total := 0
	for _, arts := range got {
		total += len(arts)
	}
	if total > MaxArticles {
		t.Fatalf("cache holds %d articles, want <= %d", total, MaxArticles)
	}
}

func TestArticleKeyPrefersGUID(t *testing.T) {
	if ArticleKey(feed.Article{GUID: "g", Link: "l"}) != "g" {
		t.Error("GUID must win")
	}
	if ArticleKey(feed.Article{Link: "l"}) != "l" {
		t.Error("link is the fallback")
	}
}

func contains(b []byte, s string) bool {
	return len(b) >= len(s) && string(b) != "" && indexOf(string(b), s) >= 0
}

func indexOf(hay, needle string) int {
	for i := 0; i+len(needle) <= len(hay); i++ {
		if hay[i:i+len(needle)] == needle {
			return i
		}
	}
	return -1
}
