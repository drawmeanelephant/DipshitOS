// Package store persists the reader's subscriptions (OPML 2.0), read/unread
// state and a bounded article cache as flat files in the guest's host share.
//
// Every write goes through FileIO.Write, whose production implementation is
// vi.WriteFileSafe (temp file + sync + rename); a process killed mid-write can
// therefore never leave a half-written file behind, and a load is all-or-
// nothing. The IO is an interface so the host `go test` run can pin the whole
// persistence contract without a guest.
package store

import (
	"encoding/xml"
	"errors"
	"strings"

	"virelai/rss/feed"
)

// Storage location. The guest sees the macOS host share at /host
// (user/go/files/listing.go), so these are the documented persistence paths.
const (
	DefaultDir = "/host"
	SubsFile   = "RSS.OPML"
	StateFile  = "RSS.STATE"
	CacheFile  = "RSS.CACHE"

	// Bounds: the cache and subscription list may never grow without limit.
	MaxArticles  = 200
	MaxFeeds     = 64
	SummaryLimit = 2048
)

// ErrNoFile is returned by Load* when the file has not been written yet.
var ErrNoFile = errors.New("store: file not present")

// Subscription is one feed the user follows.
type Subscription struct {
	Title string
	URL   string
}

// State is the read/unread and selection memory.
// LastFeed is the feed URL, which is also the cache key. It is not the
// display title: a title cannot look an article list back up.
type State struct {
	Read     map[string]bool
	LastFeed string
}

// Cache is the last-known article list per feed URL, so a failed refresh still
// has something to show.
type Cache map[string][]feed.Article

// FileIO is the persistence seam. Production wraps virelai/vi; tests use a map.
type FileIO interface {
	Read(path string) ([]byte, error)
	Write(path string, b []byte) error
	Delete(path string) error
}

// Store is a directory of flat files.
type Store struct {
	dir string
	io  FileIO
}

// New builds a Store rooted at dir (defaults to /host).
func New(io FileIO, dir string) *Store {
	if dir == "" {
		dir = DefaultDir
	}
	return &Store{dir: dir, io: io}
}

// Paths returns the three absolute storage paths, for the docs and the UI.
func (s *Store) Paths() (subs, state, cache string) {
	return s.dir + "/" + SubsFile, s.dir + "/" + StateFile, s.dir + "/" + CacheFile
}

func (s *Store) path(name string) string { return s.dir + "/" + name }

// --- subscriptions (OPML 2.0) -------------------------------------------

// LoadSubs reads RSS.OPML. A missing file is not an error: it means the user
// has no subscriptions yet, and the caller shows the empty-state hint.
func (s *Store) LoadSubs() ([]Subscription, error) {
	b, err := s.io.Read(s.path(SubsFile))
	if err != nil {
		return nil, err
	}
	return DecodeOPML(b)
}

// SaveSubs writes RSS.OPML atomically, capping the list at MaxFeeds.
func (s *Store) SaveSubs(subs []Subscription) error {
	if len(subs) > MaxFeeds {
		subs = subs[:MaxFeeds]
	}
	return s.io.Write(s.path(SubsFile), EncodeOPML(subs))
}

// --- read/unread state ---------------------------------------------------

// LoadState reads RSS.STATE, returning an empty (never nil-map) state when the
// file does not exist yet.
func (s *Store) LoadState() (State, error) {
	b, err := s.io.Read(s.path(StateFile))
	if err != nil {
		return State{Read: map[string]bool{}}, err
	}
	var x stateXML
	if err := xml.Unmarshal(b, &x); err != nil {
		return State{Read: map[string]bool{}}, err
	}
	st := State{Read: map[string]bool{}, LastFeed: x.LastFeed}
	for _, r := range x.Read {
		if r.Key != "" {
			st.Read[r.Key] = true
		}
	}
	return st, nil
}

// SaveState writes RSS.STATE atomically.
func (s *Store) SaveState(st State) error {
	x := stateXML{Version: "1", LastFeed: st.LastFeed}
	for k, v := range st.Read {
		if v && k != "" {
			x.Read = append(x.Read, readXML{Key: k})
		}
	}
	sortRead(x.Read)
	b, err := xml.MarshalIndent(x, "", "  ")
	if err != nil {
		return err
	}
	return s.io.Write(s.path(StateFile), append([]byte(xml.Header), b...))
}

// --- bounded article cache ----------------------------------------------

// LoadCache reads RSS.CACHE (empty cache when absent).
func (s *Store) LoadCache() (Cache, error) {
	b, err := s.io.Read(s.path(CacheFile))
	if err != nil {
		return Cache{}, err
	}
	var x cacheXML
	if err := xml.Unmarshal(b, &x); err != nil {
		return Cache{}, err
	}
	c := Cache{}
	for _, f := range x.Feeds {
		var arts []feed.Article
		for _, a := range f.Articles {
			arts = append(arts, feed.Article{
				Title: a.Title, Link: a.Link, Date: a.Date, GUID: a.GUID, Summary: a.Summary,
			})
		}
		c[f.URL] = arts
	}
	return c, nil
}

// SaveCache writes RSS.CACHE atomically and trims it to MaxArticles total.
func (s *Store) SaveCache(c Cache) error {
	x := cacheXML{Version: "1"}
	total := 0
	for url, arts := range c {
		if total >= MaxArticles {
			break
		}
		f := feedXML{URL: url}
		for _, a := range arts {
			if total >= MaxArticles {
				break
			}
			summary := a.Summary
			if len(summary) > SummaryLimit {
				summary = summary[:SummaryLimit]
			}
			f.Articles = append(f.Articles, articleXML{
				Title: a.Title, Link: a.Link, Date: a.Date, GUID: a.GUID, Summary: summary,
			})
			total++
		}
		x.Feeds = append(x.Feeds, f)
	}
	sortFeeds(x.Feeds)
	b, err := xml.MarshalIndent(x, "", "  ")
	if err != nil {
		return err
	}
	return s.io.Write(s.path(CacheFile), append([]byte(xml.Header), b...))
}

// --- wire types ----------------------------------------------------------

type stateXML struct {
	XMLName  xml.Name  `xml:"state"`
	Version  string    `xml:"version,attr"`
	LastFeed string    `xml:"lastfeed,attr,omitempty"`
	Read     []readXML `xml:"read"`
}

type readXML struct {
	Key string `xml:"key,attr"`
}

type cacheXML struct {
	XMLName xml.Name  `xml:"cache"`
	Version string    `xml:"version,attr"`
	Feeds   []feedXML `xml:"feed"`
}

type feedXML struct {
	URL      string       `xml:"url,attr"`
	Articles []articleXML `xml:"article"`
}

type articleXML struct {
	Title   string `xml:"title"`
	Link    string `xml:"link"`
	Date    string `xml:"date"`
	GUID    string `xml:"guid"`
	Summary string `xml:"summary"`
}

// ArticleKey is the stable identity used for read state: the GUID when the
// feed supplies one, else the link. Kept next to the wire types so the UI and
// the store can never disagree about what "read" refers to.
func ArticleKey(a feed.Article) string {
	if a.GUID != "" {
		return a.GUID
	}
	return a.Link
}

func sortRead(rs []readXML) {
	for i := 1; i < len(rs); i++ {
		for j := i; j > 0 && strings.Compare(rs[j].Key, rs[j-1].Key) < 0; j-- {
			rs[j], rs[j-1] = rs[j-1], rs[j]
		}
	}
}

func sortFeeds(fs []feedXML) {
	for i := 1; i < len(fs); i++ {
		for j := i; j > 0 && strings.Compare(fs[j].URL, fs[j-1].URL) < 0; j-- {
			fs[j], fs[j-1] = fs[j-1], fs[j]
		}
	}
}
