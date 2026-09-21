package store

import (
	"bytes"
	"encoding/xml"
	"errors"
	"strings"
)

// OPML 2.0 encode/decode. OPML is the interoperable exchange format other
// readers accept, so import is deliberately lenient (real-world OPML in the
// wild is messy) while export is strict and stable.

// ErrNotOPML is returned when the document has no <opml> root.
var ErrNotOPML = errors.New("store: not an OPML document")

const opmlHeader = `<?xml version="1.0" encoding="UTF-8"?>` + "\n"

// EncodeOPML writes one <outline> per subscription. Attribute order and shape
// are fixed so the export is byte-stable across runs.
func EncodeOPML(subs []Subscription) []byte {
	var b bytes.Buffer
	b.WriteString(opmlHeader)
	b.WriteString(`<opml version="2.0">` + "\n")
	b.WriteString("  <head>\n    <title>Virelai RSS</title>\n  </head>\n")
	b.WriteString("  <body>\n")
	for _, s := range subs {
		b.WriteString(`    <outline type="rss" text="`)
		b.WriteString(xmlEscape(s.Title))
		b.WriteString(`" title="`)
		b.WriteString(xmlEscape(s.Title))
		b.WriteString(`" xmlUrl="`)
		b.WriteString(xmlEscape(s.URL))
		b.WriteString(`"/>` + "\n")
	}
	b.WriteString("  </body>\n</opml>\n")
	return b.Bytes()
}

// DecodeOPML walks every <outline> that carries an xmlUrl, at any depth, so
// nesting (folders) and mixed attribute casing both survive.
func DecodeOPML(data []byte) ([]Subscription, error) {
	dec := xml.NewDecoder(bytes.NewReader(data))
	rootSeen := false
	var subs []Subscription
	for {
		tok, err := dec.Token()
		if err != nil {
			break
		}
		se, ok := tok.(xml.StartElement)
		if !ok {
			continue
		}
		if !rootSeen {
			if se.Name.Local != "opml" {
				return nil, ErrNotOPML
			}
			rootSeen = true
			continue
		}
		if se.Name.Local != "outline" {
			continue
		}
		var url, title, text string
		for _, a := range se.Attr {
			switch strings.ToLower(a.Name.Local) {
			case "xmlurl":
				url = strings.TrimSpace(a.Value)
			case "title":
				title = strings.TrimSpace(a.Value)
			case "text":
				text = strings.TrimSpace(a.Value)
			}
		}
		if url == "" {
			continue
		}
		name := title
		if name == "" {
			name = text
		}
		if name == "" {
			name = url
		}
		subs = append(subs, Subscription{Title: name, URL: url})
	}
	if !rootSeen {
		return nil, ErrNotOPML
	}
	return subs, nil
}

// xmlEscape escapes the five predefined XML entities plus the attribute
// quotes, without pulling in a heavier dependency.
func xmlEscape(s string) string {
	var b strings.Builder
	for _, r := range s {
		switch r {
		case '&':
			b.WriteString("&amp;")
		case '<':
			b.WriteString("&lt;")
		case '>':
			b.WriteString("&gt;")
		case '"':
			b.WriteString("&quot;")
		case '\'':
			b.WriteString("&apos;")
		default:
			b.WriteRune(r)
		}
	}
	return b.String()
}
