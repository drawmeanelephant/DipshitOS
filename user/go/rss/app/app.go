// Package app is the reader's pure state machine: subscriptions, article list,
// article reader, selection, read state and the TUI's textual frame.
//
// It imports nothing but keys/store/feed, so the whole interaction contract —
// navigation, read toggling, the add-feed prompt, error text — is pinned by the
// host `go test ./rss/...` run. The Bubble Tea adapter (package ui) is a thin
// shell over this.
package app

import (
	"strconv"
	"strings"

	"virelai/rss/feed"
	"virelai/rss/keys"
	"virelai/rss/store"
)

// View is which pane is on screen.
type View int

const (
	ViewFeeds View = iota
	ViewArticles
	ViewArticle
)

// Model is the whole UI state.
type Model struct {
	Subs     []store.Subscription
	Articles []feed.Article
	Read     map[string]bool

	// FeedURL is the cache key and the value persisted as LastFeed.
	// FeedTitle is only the header text. A title is not a URL.
	FeedURL    string
	FeedTitle  string
	FeedCursor int
	ArtCursor  int
	Scroll     int

	View   View
	Width  int
	Height int

	Status    string
	ErrText   string
	InputMode bool
	Input     string

	Quit bool
}

// Effects is what the caller (main) must do after Apply: the state machine
// never performs IO itself.
type Effects struct {
	Quit      bool
	FetchURL  string              // fetch this feed and show its articles
	AddSub    *store.Subscription // add these subscriptions (import)
	SaveSubs  bool                // persist the subscription list
	SaveState bool                // persist read state
	OpenLink  string              // hand a link to the guest console
	Reload    bool                // re-read OPML from disk
}

// New builds an empty model with sane defaults.
func New(width, height int) *Model {
	if width <= 0 {
		width = 80
	}
	if height <= 0 {
		height = 24
	}
	return &Model{Read: map[string]bool{}, Width: width, Height: height}
}

// SetArticles installs a freshly fetched feed and moves to the article list.
// url is kept even when title differs: the cache and the next refresh both
// address the feed by URL.
func (m *Model) SetArticles(url, title string, arts []feed.Article) {
	if url != "" {
		m.FeedURL = url
	}
	if title != "" {
		m.FeedTitle = title
	} else if url != "" {
		m.FeedTitle = url
	}
	m.Articles = arts
	m.ArtCursor = 0
	m.Scroll = 0
	m.View = ViewArticles
	m.ErrText = ""
	if len(arts) == 0 {
		m.Status = "Feed has no entries."
	}
}

// SetError records a legible failure. Previous articles are deliberately left
// in place so a failed refresh degrades instead of blanking the screen.
func (m *Model) SetError(msg string) {
	m.ErrText = msg
	m.Status = "error"
}

// SetStatus sets the transient footer message.
func (m *Model) SetStatus(msg string) { m.Status = msg }

// Apply handles one key press and returns the effects the caller owes.
func (m *Model) Apply(ev keys.Event) Effects {
	if m.InputMode {
		return m.applyInput(ev)
	}
	switch m.View {
	case ViewFeeds:
		return m.applyFeeds(ev)
	case ViewArticles:
		return m.applyArticles(ev)
	default:
		return m.applyArticle(ev)
	}
}

func (m *Model) applyInput(ev keys.Event) Effects {
	switch ev.Key {
	case keys.KeyEsc:
		m.InputMode = false
		m.Input = ""
		m.Status = "Cancelled."
	case keys.KeyBackspace:
		if len(m.Input) > 0 {
			m.Input = m.Input[:len(m.Input)-1]
		}
	case keys.KeyEnter:
		url := strings.TrimSpace(m.Input)
		m.InputMode = false
		m.Input = ""
		if url == "" {
			m.Status = "Empty URL ignored."
			return Effects{}
		}
		if feed.Classify(url).Scheme == feed.SchemeInvalid {
			m.SetError("Feed URL needs http:// or https://")
			return Effects{}
		}
		sub := store.Subscription{Title: url, URL: url}
		m.Subs = append(m.Subs, sub)
		m.Status = "Added " + url
		return Effects{AddSub: &sub, SaveSubs: true, FetchURL: url}
	case keys.KeyRune:
		if len(m.Input) < 256 {
			m.Input += string(ev.Rune)
		}
	case keys.KeyCtrlC:
		m.Quit = true
	}
	return Effects{}
}

func (m *Model) applyFeeds(ev keys.Event) Effects {
	switch ev.Key {
	case keys.KeyUp:
		if m.FeedCursor > 0 {
			m.FeedCursor--
		}
	case keys.KeyDown:
		if m.FeedCursor < len(m.Subs)-1 {
			m.FeedCursor++
		}
	case keys.KeyEnter:
		if len(m.Subs) > 0 {
			m.Status = "Loading " + m.Subs[m.FeedCursor].URL
			return Effects{FetchURL: m.Subs[m.FeedCursor].URL}
		}
		m.Status = "No subscriptions yet — press a to add one."
	case keys.KeyRune:
		switch ev.Rune {
		case 'a':
			m.InputMode = true
			m.Input = ""
			m.Status = "Feed URL (http:// or https://), Enter to add, Esc to cancel"
		case 'd':
			if len(m.Subs) > 0 {
				removed := m.Subs[m.FeedCursor]
				m.Subs = append(m.Subs[:m.FeedCursor], m.Subs[m.FeedCursor+1:]...)
				if m.FeedCursor >= len(m.Subs) && m.FeedCursor > 0 {
					m.FeedCursor--
				}
				m.Status = "Removed " + removed.URL
				return Effects{SaveSubs: true}
			}
		case 'r':
			if len(m.Subs) > 0 {
				return Effects{FetchURL: m.Subs[m.FeedCursor].URL}
			}
		case 'i':
			m.Status = "Reloading " + store.SubsFile
			return Effects{Reload: true}
		case 'q':
			m.Quit = true
			return Effects{Quit: true, SaveState: true}
		}
	case keys.KeyCtrlC:
		m.Quit = true
		return Effects{Quit: true, SaveState: true}
	}
	return Effects{}
}

func (m *Model) applyArticles(ev keys.Event) Effects {
	switch ev.Key {
	case keys.KeyUp:
		if m.ArtCursor > 0 {
			m.ArtCursor--
		}
	case keys.KeyDown:
		if m.ArtCursor < len(m.Articles)-1 {
			m.ArtCursor++
		}
	case keys.KeyEnter:
		if len(m.Articles) > 0 {
			m.View = ViewArticle
			m.Scroll = 0
			m.markRead(m.Articles[m.ArtCursor], true)
			return Effects{SaveState: true}
		}
	case keys.KeyEsc, keys.KeyLeft:
		m.View = ViewFeeds
	case keys.KeyRune:
		return m.articleRune(ev.Rune, true)
	case keys.KeyCtrlC:
		m.Quit = true
		return Effects{Quit: true, SaveState: true}
	}
	return Effects{}
}

func (m *Model) applyArticle(ev keys.Event) Effects {
	switch ev.Key {
	case keys.KeyDown:
		m.Scroll++
	case keys.KeyUp:
		if m.Scroll > 0 {
			m.Scroll--
		}
	case keys.KeyPageDown:
		m.Scroll += m.page()
	case keys.KeyPageUp:
		m.Scroll -= m.page()
		if m.Scroll < 0 {
			m.Scroll = 0
		}
	case keys.KeyEsc, keys.KeyLeft:
		m.View = ViewArticles
	case keys.KeyRune:
		return m.articleRune(ev.Rune, false)
	case keys.KeyCtrlC:
		m.Quit = true
		return Effects{Quit: true, SaveState: true}
	}
	return Effects{}
}

// articleRune holds the keys shared by the article list and the reader.
func (m *Model) articleRune(r rune, inList bool) Effects {
	switch r {
	case 'm':
		if len(m.Articles) > 0 {
			a := m.Articles[m.ArtCursor]
			m.markRead(a, !m.isRead(a))
			m.Status = "Toggled read"
			return Effects{SaveState: true}
		}
	case 'o':
		if len(m.Articles) > 0 {
			return Effects{OpenLink: m.Articles[m.ArtCursor].Link}
		}
	case 'q':
		m.Quit = true
		return Effects{Quit: true, SaveState: true}
	case 'r':
		if inList {
			return Effects{FetchURL: m.currentURL()}
		}
	}
	return Effects{}
}

func (m *Model) page() int {
	p := m.Height - 6
	if p < 1 {
		p = 1
	}
	return p
}

func (m *Model) currentURL() string {
	if m.FeedURL != "" {
		return m.FeedURL
	}
	for _, s := range m.Subs {
		if s.Title != "" && s.Title == m.FeedTitle {
			return s.URL
		}
	}
	if m.FeedCursor < len(m.Subs) {
		return m.Subs[m.FeedCursor].URL
	}
	return ""
}

// CacheKey resolves a persisted last-feed token to the URL the cache is
// keyed by. Tokens that are already a subscription URL pass through. A token
// that matches a subscription title is the older on-disk shape (the title
// was stored where the URL belongs) and resolves to that subscription's URL.
func CacheKey(token string, subs []store.Subscription) string {
	if token == "" {
		return ""
	}
	for _, s := range subs {
		if s.URL == token {
			return s.URL
		}
	}
	for _, s := range subs {
		if s.Title == token && s.URL != "" {
			return s.URL
		}
	}
	return token
}

// RestoreFeed installs the last-opened feed and, when arts is non-empty, the
// offline article list. Title is the matching subscription's title when one
// exists, otherwise the URL.
func (m *Model) RestoreFeed(url string, subs []store.Subscription, arts []feed.Article) {
	if url == "" {
		return
	}
	m.FeedURL = url
	m.FeedTitle = url
	for _, s := range subs {
		if s.URL == url && s.Title != "" {
			m.FeedTitle = s.Title
			break
		}
	}
	if len(arts) == 0 {
		return
	}
	m.Articles = arts
	m.ArtCursor = 0
	m.Scroll = 0
	m.View = ViewArticles
}

func (m *Model) isRead(a feed.Article) bool { return m.Read[store.ArticleKey(a)] }

func (m *Model) markRead(a feed.Article, v bool) {
	if m.Read == nil {
		m.Read = map[string]bool{}
	}
	if v {
		m.Read[store.ArticleKey(a)] = true
	} else {
		delete(m.Read, store.ArticleKey(a))
	}
}

// --- rendering -----------------------------------------------------------

// Render builds the whole frame as ANSI text for the bound tty. It is pure:
// the same state always produces the same bytes.
func (m *Model) Render() string {
	var b strings.Builder
	b.WriteString("\x1b[2J\x1b[H")
	b.WriteString("\x1b[1;96m Virelai RSS \x1b[0m")
	b.WriteString(" \x1b[90m")
	b.WriteString(viewName(m.View))
	b.WriteString("\x1b[0m\n")

	if m.ErrText != "" {
		b.WriteString("\x1b[1;91m ! ")
		b.WriteString(m.ErrText)
		b.WriteString("\x1b[0m\n")
	}

	switch m.View {
	case ViewFeeds:
		m.renderFeeds(&b)
	case ViewArticles:
		m.renderArticles(&b)
	default:
		m.renderArticle(&b)
	}

	if m.InputMode {
		b.WriteString("\n\x1b[93m")
		b.WriteString(store.SubsFile)
		b.WriteString("> ")
		b.WriteString(m.Input)
		b.WriteString("\x1b[0m")
	}

	b.WriteString("\n\x1b[90m")
	b.WriteString(m.hints())
	b.WriteString("\x1b[0m")
	if m.Status != "" {
		b.WriteString("  \x1b[1;97m")
		b.WriteString(m.Status)
		b.WriteString("\x1b[0m")
	}
	return b.String()
}

func viewName(v View) string {
	switch v {
	case ViewArticles:
		return "articles"
	case ViewArticle:
		return "reader"
	default:
		return "subscriptions"
	}
}

func (m *Model) renderFeeds(b *strings.Builder) {
	if len(m.Subs) == 0 {
		b.WriteString("\n  \x1b[93mNo subscriptions. Press a to add a feed URL, or put an OPML file at /host/" + store.SubsFile + ".\x1b[0m\n")
		return
	}
	for i, s := range m.Subs {
		b.WriteString(cursor(i == m.FeedCursor))
		b.WriteString(trunc(s.Title, 48))
		b.WriteString("  \x1b[90m")
		b.WriteString(trunc(s.URL, 48))
		b.WriteString("\x1b[0m\n")
	}
}

func (m *Model) renderArticles(b *strings.Builder) {
	b.WriteString("\x1b[1;97m")
	b.WriteString(trunc(m.FeedTitle, 60))
	b.WriteString("\x1b[0m\n")
	if len(m.Articles) == 0 {
		b.WriteString("  \x1b[93mNo entries (fetch with r).\x1b[0m\n")
		return
	}
	for i, a := range m.Articles {
		b.WriteString(cursor(i == m.ArtCursor))
		mark := " "
		if m.isRead(a) {
			mark = "\x1b[90m·\x1b[0m"
		}
		b.WriteString(mark)
		b.WriteString(" ")
		b.WriteString(trunc(a.Title, 56))
		b.WriteString("  \x1b[90m")
		b.WriteString(trunc(a.Date, 24))
		b.WriteString("\x1b[0m\n")
	}
}

func (m *Model) renderArticle(b *strings.Builder) {
	if len(m.Articles) == 0 {
		return
	}
	a := m.Articles[m.ArtCursor]
	b.WriteString("\x1b[1;97m")
	b.WriteString(a.Title)
	b.WriteString("\x1b[0m\n\x1b[90m")
	b.WriteString(a.Link)
	b.WriteString("  ")
	b.WriteString(a.Date)
	b.WriteString("\x1b[0m\n\n")
	lines := wrap(stripTags(a.Summary), 76)
	for i := m.Scroll; i < len(lines) && i < m.Scroll+m.page(); i++ {
		b.WriteString(lines[i])
		b.WriteString("\n")
	}
}

func (m *Model) hints() string {
	switch m.View {
	case ViewFeeds:
		return "↑/↓ move · Enter open · a add · d delete · r refresh · i reload OPML · q quit"
	case ViewArticles:
		return "↑/↓ move · Enter read · Esc back · m read/unread · o open link · r refresh · q quit"
	default:
		return "↑/↓ scroll · PgUp/PgDn page · Esc back · m read/unread · o open link · q quit"
	}
}

func cursor(on bool) string {
	if on {
		return "\x1b[1;92m> \x1b[0m"
	}
	return "  "
}

func trunc(s string, n int) string {
	if len(s) <= n {
		return s
	}
	if n <= 1 {
		return s[:n]
	}
	return s[:n-1] + "…"
}

// stripTags removes angle-bracket markup so an HTML-ish summary stays legible
// in the reader (the guest has no HTML renderer wired for this view).
func stripTags(s string) string {
	var b strings.Builder
	depth := 0
	for _, r := range s {
		switch r {
		case '<':
			depth++
		case '>':
			if depth > 0 {
				depth--
			}
		default:
			if depth == 0 {
				b.WriteRune(r)
			}
		}
	}
	return b.String()
}

// wrap breaks text into lines of at most n columns on spaces.
func wrap(s string, n int) []string {
	words := strings.Fields(s)
	if len(words) == 0 {
		return []string{"(no content)"}
	}
	var lines []string
	cur := ""
	for _, w := range words {
		if cur == "" {
			cur = w
			continue
		}
		if len(cur)+1+len(w) <= n {
			cur += " " + w
			continue
		}
		lines = append(lines, cur)
		cur = w
	}
	lines = append(lines, cur)
	return lines
}

// Itoa is a tiny helper the main wiring uses for markers.
func Itoa(v int) string { return strconv.Itoa(v) }
