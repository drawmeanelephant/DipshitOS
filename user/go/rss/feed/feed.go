// Package feed parses RSS 2.0, RSS 1.0 (RDF) and Atom syndication documents
// into one article shape, and classifies feed URLs without ever downgrading a
// secure scheme.
//
// The parse and classify paths are pure, so the host `go test ./rss/...` run
// pins them with no guest. Only Fetch touches the network, and it does so
// through the guest's own seams (virelai/vi for plain TCP, virelai/tls for
// TLS 1.3) because the guest has no net/http — see tools/go/README.md and
// user/go/fetch/https.go for the same pattern.
package feed

import (
	"bytes"
	"encoding/xml"
	"errors"
	"strings"
)

// Kind is the detected syndication dialect.
type Kind string

const (
	KindRSS  Kind = "rss2"
	KindRDF  Kind = "rss1"
	KindAtom Kind = "atom"
)

// Article is one syndicated entry, normalised across dialects.
type Article struct {
	Title   string
	Link    string
	Date    string // exactly what the source published; never re-formatted here
	Summary string
	GUID    string
}

// Feed is a parsed document.
type Feed struct {
	Title    string
	Link     string
	Kind     Kind
	Articles []Article
}

// Sentinel errors. Callers test them with errors.Is so the UI can name the
// failure precisely instead of printing a generic "error".
var (
	ErrEmpty     = errors.New("feed: empty document")
	ErrMalformed = errors.New("feed: malformed XML")
	ErrNotFeed   = errors.New("feed: not an RSS or Atom document")
)

// Parse detects the root element and unmarshals accordingly. It never guesses:
// an unknown root is ErrNotFeed, and an unreadable document is ErrMalformed.
func Parse(data []byte) (*Feed, error) {
	if len(bytes.TrimSpace(data)) == 0 {
		return nil, ErrEmpty
	}
	root, err := rootElement(data)
	if err != nil {
		return nil, ErrMalformed
	}
	switch root {
	case "rss":
		return parseRSS(data)
	case "RDF":
		return parseRDF(data)
	case "feed":
		return parseAtom(data)
	default:
		return nil, ErrNotFeed
	}
}

// rootElement returns the local name of the first start element, ignoring
// declarations, comments and processing instructions.
func rootElement(data []byte) (string, error) {
	dec := xml.NewDecoder(bytes.NewReader(data))
	for {
		tok, err := dec.Token()
		if err != nil {
			return "", err
		}
		if se, ok := tok.(xml.StartElement); ok {
			return se.Name.Local, nil
		}
	}
}

type rssDoc struct {
	XMLName xml.Name `xml:"rss"`
	Channel struct {
		Title string `xml:"title"`
		Link  string `xml:"link"`
		Items []struct {
			Title   string `xml:"title"`
			Link    string `xml:"link"`
			Desc    string `xml:"description"`
			PubDate string `xml:"pubDate"`
			GUID    string `xml:"guid"`
			Encoded string `xml:"http://purl.org/rss/1.0/modules/content/ encoded"`
		} `xml:"item"`
	} `xml:"channel"`
}

func parseRSS(data []byte) (*Feed, error) {
	var doc rssDoc
	if err := xml.Unmarshal(data, &doc); err != nil {
		return nil, ErrMalformed
	}
	f := &Feed{Title: strings.TrimSpace(doc.Channel.Title), Link: strings.TrimSpace(doc.Channel.Link), Kind: KindRSS}
	for _, it := range doc.Channel.Items {
		a := Article{
			Title:   strings.TrimSpace(it.Title),
			Link:    strings.TrimSpace(it.Link),
			Date:    strings.TrimSpace(it.PubDate),
			Summary: strings.TrimSpace(it.Desc),
			GUID:    strings.TrimSpace(it.GUID),
		}
		if a.Summary == "" {
			a.Summary = strings.TrimSpace(it.Encoded)
		}
		if a.GUID == "" {
			a.GUID = a.Link
		}
		f.Articles = append(f.Articles, a)
	}
	return f, nil
}

// rdfDoc is RSS 1.0: items are siblings of channel, under the RDF root.
type rdfDoc struct {
	XMLName xml.Name `xml:"RDF"`
	Channel struct {
		Title string `xml:"title"`
		Link  string `xml:"link"`
	} `xml:"channel"`
	Items []struct {
		Title string `xml:"title"`
		Link  string `xml:"link"`
		Desc  string `xml:"description"`
		Date  string `xml:"http://purl.org/dc/elements/1.1/ date"`
		About string `xml:"about,attr"`
	} `xml:"item"`
}

func parseRDF(data []byte) (*Feed, error) {
	var doc rdfDoc
	if err := xml.Unmarshal(data, &doc); err != nil {
		return nil, ErrMalformed
	}
	f := &Feed{Title: strings.TrimSpace(doc.Channel.Title), Link: strings.TrimSpace(doc.Channel.Link), Kind: KindRDF}
	for _, it := range doc.Items {
		a := Article{
			Title:   strings.TrimSpace(it.Title),
			Link:    strings.TrimSpace(it.Link),
			Date:    strings.TrimSpace(it.Date),
			Summary: strings.TrimSpace(it.Desc),
			GUID:    strings.TrimSpace(it.About),
		}
		if a.GUID == "" {
			a.GUID = a.Link
		}
		f.Articles = append(f.Articles, a)
	}
	return f, nil
}

type atomDoc struct {
	XMLName xml.Name   `xml:"feed"`
	Title   string     `xml:"title"`
	Links   []atomLink `xml:"link"`
	Entries []struct {
		Title     string     `xml:"title"`
		Links     []atomLink `xml:"link"`
		ID        string     `xml:"id"`
		Updated   string     `xml:"updated"`
		Published string     `xml:"published"`
		Summary   string     `xml:"summary"`
		Content   string     `xml:"content"`
	} `xml:"entry"`
}

type atomLink struct {
	Href string `xml:"href,attr"`
	Rel  string `xml:"rel,attr"`
}

// bestLink prefers rel="alternate" (or an unlabelled link), which is the
// human-facing article/feed URL; self/next/etc. are ignored.
func bestLink(links []atomLink) string {
	var fallback string
	for _, l := range links {
		if l.Rel == "" || l.Rel == "alternate" {
			return strings.TrimSpace(l.Href)
		}
		if fallback == "" {
			fallback = strings.TrimSpace(l.Href)
		}
	}
	return fallback
}

func parseAtom(data []byte) (*Feed, error) {
	var doc atomDoc
	if err := xml.Unmarshal(data, &doc); err != nil {
		return nil, ErrMalformed
	}
	f := &Feed{Title: strings.TrimSpace(doc.Title), Link: bestLink(doc.Links), Kind: KindAtom}
	for _, e := range doc.Entries {
		date := strings.TrimSpace(e.Published)
		if date == "" {
			date = strings.TrimSpace(e.Updated)
		}
		summary := strings.TrimSpace(e.Summary)
		if summary == "" {
			summary = strings.TrimSpace(e.Content)
		}
		a := Article{
			Title:   strings.TrimSpace(e.Title),
			Link:    bestLink(e.Links),
			Date:    date,
			Summary: summary,
			GUID:    strings.TrimSpace(e.ID),
		}
		if a.GUID == "" {
			a.GUID = a.Link
		}
		f.Articles = append(f.Articles, a)
	}
	return f, nil
}
