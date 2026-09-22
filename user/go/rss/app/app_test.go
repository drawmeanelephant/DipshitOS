package app

import (
	"strings"
	"testing"

	"virelai/rss/feed"
	"virelai/rss/keys"
	"virelai/rss/store"
)

func rune1(r rune) keys.Event                            { return keys.Event{Key: keys.KeyRune, Rune: r} }
func named(k keys.Key) keys.Event                        { return keys.Event{Key: k} }
func subs(ss ...store.Subscription) []store.Subscription { return ss }

func TestNavigateFeedsAndOpen(t *testing.T) {
	m := New(80, 24)
	m.Subs = subs(
		store.Subscription{Title: "A", URL: "http://10.0.0.2/a"},
		store.Subscription{Title: "B", URL: "http://10.0.0.2/b"},
	)
	m.Apply(named(keys.KeyUp))
	if m.FeedCursor != 0 {
		t.Fatalf("cursor = %d, want clamped at 0", m.FeedCursor)
	}
	m.Apply(named(keys.KeyDown))
	if m.FeedCursor != 1 {
		t.Fatalf("cursor = %d, want 1", m.FeedCursor)
	}
	m.Apply(named(keys.KeyDown))
	if m.FeedCursor != 1 {
		t.Fatalf("cursor = %d, want clamped at 1", m.FeedCursor)
	}
	ef := m.Apply(named(keys.KeyEnter))
	if ef.FetchURL != "http://10.0.0.2/b" {
		t.Fatalf("enter effect = %+v", ef)
	}
}

func TestEmptySubscriptionsIsSafe(t *testing.T) {
	m := New(80, 24)
	ef := m.Apply(named(keys.KeyEnter))
	if ef.FetchURL != "" {
		t.Fatalf("no fetch expected, got %+v", ef)
	}
	if !strings.Contains(m.Status, "No subscriptions") {
		t.Fatalf("status = %q", m.Status)
	}
	m.Apply(rune1('d')) // delete with an empty list must not panic
	if len(m.Subs) != 0 {
		t.Fatalf("subs = %d", len(m.Subs))
	}
}

func TestAddFeedPrompt(t *testing.T) {
	m := New(80, 24)
	m.Apply(rune1('a'))
	if !m.InputMode {
		t.Fatal("expected input mode")
	}
	for _, r := range "http://10.0.0.2/feed.xml" {
		m.Apply(rune1(r))
	}
	if m.Input != "http://10.0.0.2/feed.xml" {
		t.Fatalf("input = %q", m.Input)
	}
	ef := m.Apply(named(keys.KeyEnter))
	if !ef.SaveSubs || ef.FetchURL != "http://10.0.0.2/feed.xml" || ef.AddSub == nil {
		t.Fatalf("add effects = %+v", ef)
	}
	if len(m.Subs) != 1 || m.Subs[0].URL != "http://10.0.0.2/feed.xml" {
		t.Fatalf("subs = %+v", m.Subs)
	}
}

func TestAddFeedRejectsBadURL(t *testing.T) {
	m := New(80, 24)
	m.Apply(rune1('a'))
	for _, r := range "ftp://nope/feed" {
		m.Apply(rune1(r))
	}
	ef := m.Apply(named(keys.KeyEnter))
	if ef.FetchURL != "" || ef.SaveSubs {
		t.Fatalf("must not persist a bad URL: %+v", ef)
	}
	if !strings.Contains(m.ErrText, "http://") {
		t.Fatalf("err = %q", m.ErrText)
	}
}

func TestBackspaceEditsPrompt(t *testing.T) {
	m := New(80, 24)
	m.Apply(rune1('a'))
	for _, r := range "ab" {
		m.Apply(rune1(r))
	}
	m.Apply(named(keys.KeyBackspace))
	if m.Input != "a" {
		t.Fatalf("input = %q", m.Input)
	}
	m.Apply(named(keys.KeyEsc))
	if m.InputMode || m.Input != "" {
		t.Fatalf("esc must cancel: mode=%v input=%q", m.InputMode, m.Input)
	}
}

func TestArticleReadFlow(t *testing.T) {
	m := New(80, 24)
	m.SetArticles("http://10.0.0.2/feed.xml", "Test Feed", []feed.Article{
		{Title: "One", Link: "l1", GUID: "g1"},
		{Title: "Two", Link: "l2", GUID: "g2"},
	})
	if m.View != ViewArticles {
		t.Fatalf("view = %v", m.View)
	}
	ef := m.Apply(named(keys.KeyEnter))
	if m.View != ViewArticle || !ef.SaveState {
		t.Fatalf("open article: view=%v ef=%+v", m.View, ef)
	}
	if !m.Read["g1"] {
		t.Fatalf("reading an article must mark it read: %+v", m.Read)
	}
	m.Apply(rune1('m'))
	if m.Read["g1"] {
		t.Fatalf("m must toggle back to unread: %+v", m.Read)
	}
	ef = m.Apply(rune1('o'))
	if ef.OpenLink != "l1" {
		t.Fatalf("open link effect = %+v", ef)
	}
	m.Apply(named(keys.KeyEsc))
	if m.View != ViewArticles {
		t.Fatalf("esc must return to the list, got %v", m.View)
	}
}

func TestNoBusyScrollAndPage(t *testing.T) {
	m := New(80, 24)
	m.SetArticles("u", "t", []feed.Article{{Title: "One", Summary: "a b c"}})
	m.View = ViewArticle
	m.Apply(named(keys.KeyUp))
	if m.Scroll != 0 {
		t.Fatalf("scroll must clamp at 0, got %d", m.Scroll)
	}
	m.Apply(named(keys.KeyPageDown))
	if m.Scroll <= 0 {
		t.Fatalf("pgdown must advance, got %d", m.Scroll)
	}
}

func TestQuitEffectSavesState(t *testing.T) {
	m := New(80, 24)
	ef := m.Apply(rune1('q'))
	if !ef.Quit || !ef.SaveState {
		t.Fatalf("quit effects = %+v", ef)
	}
}

func TestRenderShowsState(t *testing.T) {
	m := New(80, 24)
	if !strings.Contains(m.Render(), "No subscriptions") {
		t.Fatalf("empty render = %q", m.Render())
	}
	m.Subs = subs(store.Subscription{Title: "My Feed", URL: "http://10.0.0.2/f"})
	out := m.Render()
	if !strings.Contains(out, "My Feed") || !strings.Contains(out, "subscriptions") {
		t.Fatalf("feeds render = %q", out)
	}
	m.SetArticles("http://10.0.0.2/f", "My Feed", []feed.Article{{Title: "Hello World", Link: "l", Date: "today"}})
	out = m.Render()
	if !strings.Contains(out, "Hello World") {
		t.Fatalf("articles render = %q", out)
	}
	m.SetError("HTTP 503")
	if !strings.Contains(m.Render(), "HTTP 503") {
		t.Fatalf("error must be visible: %q", m.Render())
	}
}

func TestReloadAndRefresh(t *testing.T) {
	m := New(80, 24)
	m.Subs = subs(store.Subscription{Title: "A", URL: "http://10.0.0.2/a"})
	if ef := m.Apply(rune1('i')); !ef.Reload {
		t.Fatalf("i must reload OPML: %+v", ef)
	}
	if ef := m.Apply(rune1('r')); ef.FetchURL != "http://10.0.0.2/a" {
		t.Fatalf("r must refresh: %+v", ef)
	}
	ef := m.Apply(rune1('d'))
	if !ef.SaveSubs || len(m.Subs) != 0 {
		t.Fatalf("d must delete and save: ef=%+v subs=%+v", ef, m.Subs)
	}
}

func TestCacheRestoresByURLNotTitle(t *testing.T) {
	url := "http://10.0.0.2:18099/feed.xml"
	title := "Virelai Test Feed"
	subs := subs(store.Subscription{Title: title, URL: url})
	if got := CacheKey(url, subs); got != url {
		t.Fatalf("CacheKey(url) = %q", got)
	}
	if got := CacheKey(title, subs); got != url {
		t.Fatalf("CacheKey(title) = %q, want the URL", got)
	}
	m := New(80, 24)
	m.Subs = subs
	arts := []feed.Article{{Title: "Cached One", Link: "https://example.com/posts/1", GUID: "urn:cached:1"}}
	m.RestoreFeed(CacheKey(title, subs), subs, arts)
	if m.FeedURL != url || m.FeedTitle != title {
		t.Fatalf("restored url=%q title=%q", m.FeedURL, m.FeedTitle)
	}
	if m.View != ViewArticles || len(m.Articles) != 1 || m.Articles[0].Title != "Cached One" {
		t.Fatalf("offline list = %+v view=%v", m.Articles, m.View)
	}
	if ef := m.Apply(rune1('r')); ef.FetchURL != url {
		t.Fatalf("refresh must use the URL, got %+v", ef)
	}
	m.SetArticles(url, title, arts)
	if m.FeedURL != url {
		t.Fatalf("SetArticles dropped the URL: %q", m.FeedURL)
	}
}

func TestReaderWrapsAndStripsTags(t *testing.T) {
	m := New(40, 24)
	m.SetArticles("u", "t", []feed.Article{{
		Title:   "T",
		Link:    "l",
		Summary: "<p>hello</p> <b>world</b>",
	}})
	m.View = ViewArticle
	out := m.Render()
	if strings.Contains(out, "<p>") {
		t.Fatalf("tags must be stripped: %q", out)
	}
	if !strings.Contains(out, "hello") || !strings.Contains(out, "world") {
		t.Fatalf("summary text must survive: %q", out)
	}
}
