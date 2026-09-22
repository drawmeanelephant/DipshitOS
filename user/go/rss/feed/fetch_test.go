package feed

import (
	"errors"
	"fmt"
	"strings"
	"testing"
)

// TestClassifyNeverDowngrades is the load-bearing security property: an https
// URL must classify as https (or invalid) — never as a cleartext request.
func TestClassifyNeverDowngrades(t *testing.T) {
	cases := []struct {
		raw    string
		scheme Scheme
		host   string
		port   uint16
		path   string
	}{
		{"https://example.com/feed.xml", SchemeHTTPS, "example.com", 443, "/feed.xml"},
		{"HTTPS://Example.COM/feed", SchemeHTTPS, "Example.COM", 443, "/feed"},
		{"https://10.0.0.2:8443/atom", SchemeHTTPS, "10.0.0.2", 8443, "/atom"},
		{"http://10.0.0.2/", SchemeHTTP, "10.0.0.2", 80, "/"},
		{"http://10.0.0.2:8080/rss.xml", SchemeHTTP, "10.0.0.2", 8080, "/rss.xml"},
		{"ftp://example.com/feed", SchemeInvalid, "", 0, ""},
		{"example.com/feed", SchemeInvalid, "", 0, ""},
		{"", SchemeInvalid, "", 0, ""},
		{"https://", SchemeInvalid, "", 0, ""},
		{"http://host:0/f", SchemeInvalid, "", 0, ""},
		{"http://host:99999/f", SchemeInvalid, "", 0, ""},
	}
	for _, c := range cases {
		u := Classify(c.raw)
		if u.Scheme != c.scheme {
			t.Errorf("Classify(%q).Scheme = %q, want %q", c.raw, u.Scheme, c.scheme)
			continue
		}
		if c.scheme == SchemeInvalid {
			continue
		}
		if u.Host != c.host || u.Port != c.port || u.Path != c.path {
			t.Errorf("Classify(%q) = %+v, want host=%q port=%d path=%q", c.raw, u, c.host, c.port, c.path)
		}
	}
}

func TestSplitResponse(t *testing.T) {
	resp := []byte("HTTP/1.1 200 OK\r\nContent-Type: application/rss+xml\r\n\r\n<rss/>")
	code, body, err := splitResponse(resp)
	if err != nil {
		t.Fatalf("splitResponse: %v", err)
	}
	if code != 200 || string(body) != "<rss/>" {
		t.Fatalf("code=%d body=%q", code, body)
	}

	code, _, err = splitResponse([]byte("HTTP/1.1 404 Not Found\r\n\r\nnope"))
	if err != nil || code != 404 {
		t.Fatalf("404: code=%d err=%v", code, err)
	}

	if _, _, err := splitResponse([]byte("garbage")); err == nil {
		t.Fatal("expected error for a response with no header terminator")
	}
	if _, _, err := splitResponse([]byte("NOTHTTP 200 OK\r\n\r\n")); err == nil {
		t.Fatal("expected error for a malformed status line")
	}
}

// TestFetchRejectsUnusableURL proves a bad URL is refused before any socket is
// opened: the dial seams are replaced with fail-on-call fakes.
func TestFetchRejectsUnusableURL(t *testing.T) {
	oldPlain, oldTLS := dialPlain, dialTLS
	defer func() { dialPlain, dialTLS = oldPlain, oldTLS }()
	dialPlain = func(string, uint16) (stream, error) {
		t.Fatal("dialPlain must not be called for an unusable URL")
		return nil, nil
	}
	dialTLS = func(string, uint16, string) (stream, error) {
		t.Fatal("dialTLS must not be called for an unusable URL")
		return nil, nil
	}
	if _, _, err := Fetch("ftp://example.com/feed"); err == nil {
		t.Fatal("expected an error for a non-http(s) URL")
	}
}

// TestFetchHTTPErrorAndParse uses a fake stream so the whole request path runs
// without a guest.
func TestFetchHTTPErrorAndParse(t *testing.T) {
	oldPlain, oldTLS := dialPlain, dialTLS
	defer func() { dialPlain, dialTLS = oldPlain, oldTLS }()
	dialTLS = func(string, uint16, string) (stream, error) { return nil, errors.New("no tls here") }

	payload := read(t, "rss2.xml")
	resp := append([]byte("HTTP/1.1 200 OK\r\nContent-Type: application/rss+xml\r\n\r\n"), payload...)
	dialPlain = func(string, uint16) (stream, error) {
		return &fakeStream{data: resp}, nil
	}
	f, raw, err := Fetch("http://10.0.0.2/feed.xml")
	if err != nil {
		t.Fatalf("Fetch: %v", err)
	}
	if f.Title != "Virelai Test Feed" || len(f.Articles) != 2 {
		t.Fatalf("parsed = %+v", f)
	}
	if len(raw) != len(payload) {
		t.Fatalf("raw body = %d bytes, want %d", len(raw), len(payload))
	}

	dialPlain = func(string, uint16) (stream, error) {
		return &fakeStream{data: []byte("HTTP/1.1 503 Service Unavailable\r\n\r\nbusy")}, nil
	}
	_, _, err = Fetch("http://10.0.0.2/feed.xml")
	var he HTTPError
	if !errors.As(err, &he) || he.Status != 503 {
		t.Fatalf("err = %v, want HTTPError{503}", err)
	}
}

// fakeStream replays a fixed buffer and then reports EOF.
type fakeStream struct {
	data  []byte
	off   int
	wrote []byte
}

func (f *fakeStream) Write(p []byte) (int, error) {
	f.wrote = append(f.wrote, p...)
	return len(p), nil
}

func (f *fakeStream) Read(p []byte) (int, error) {
	if f.off >= len(f.data) {
		return 0, errors.New("eof")
	}
	n := copy(p, f.data[f.off:])
	f.off += n
	return n, nil
}

func (f *fakeStream) Close() error { return nil }

func TestHostHeaderKeepsNonDefaultPort(t *testing.T) {
	def := Classify("http://10.0.0.2/feed.xml")
	if !strings.Contains(formatRequest(def), "Host: 10.0.0.2\r\n") || strings.Contains(formatRequest(def), "Host: 10.0.0.2:") {
		t.Fatalf("default port must be omitted:\n%s", formatRequest(def))
	}
	alt := Classify("http://10.0.0.2:18099/feed.xml")
	if !strings.Contains(formatRequest(alt), "Host: 10.0.0.2:18099\r\n") {
		t.Fatalf("non-default port missing:\n%s", formatRequest(alt))
	}
	tls := Classify("https://example.com:8443/atom")
	if !strings.Contains(formatRequest(tls), "Host: example.com:8443\r\n") {
		t.Fatalf("https non-default port missing:\n%s", formatRequest(tls))
	}
}

func TestFetchDecodesChunkedAndFollowsRedirect(t *testing.T) {
	oldPlain, oldTLS := dialPlain, dialTLS
	defer func() { dialPlain, dialTLS = oldPlain, oldTLS }()
	payload := read(t, "rss2.xml")
	moved := []byte("HTTP/1.1 301 Moved Permanently\r\nLocation: /rss.xml\r\nContent-Length: 5\r\n\r\nmovedTRAIL")
	chunked := []byte("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n" + chunkBody(payload))
	var reqs []string
	n := 0
	dialPlain = func(string, uint16) (stream, error) {
		s := &fakeStream{}
		switch n {
		case 0:
			s.data = moved
		case 1:
			s.data = chunked
		default:
			return nil, errors.New("unexpected dial")
		}
		n++
		// Capture the request after Write, which Fetch does before Read.
		return &recordingStream{fakeStream: s, done: func(wrote []byte) { reqs = append(reqs, string(wrote)) }}, nil
	}
	dialTLS = func(string, uint16, string) (stream, error) {
		t.Fatal("plain redirect must not open TLS")
		return nil, nil
	}
	f, raw, err := Fetch("http://10.0.0.2:18099/feed.xml")
	if err != nil {
		t.Fatalf("Fetch: %v", err)
	}
	if f.Title != "Virelai Test Feed" || len(f.Articles) != 2 {
		t.Fatalf("parsed = %+v", f)
	}
	if string(raw) != string(payload) {
		t.Fatalf("decoded body = %d bytes, want %d", len(raw), len(payload))
	}
	if len(reqs) != 2 {
		t.Fatalf("requests = %d, want 2 (redirect then document)", len(reqs))
	}
	for _, req := range reqs {
		if !strings.Contains(req, "Host: 10.0.0.2:18099\r\n") {
			t.Fatalf("request omitted the port:\n%s", req)
		}
	}
	if !strings.Contains(reqs[1], "GET /rss.xml ") {
		t.Fatalf("second request = %q", reqs[1])
	}
}

// recordingStream reports the bytes written once the response has been read.
type recordingStream struct {
	*fakeStream
	done func([]byte)
}

func (r *recordingStream) Close() error {
	if r.done != nil {
		r.done(r.wrote)
	}
	return r.fakeStream.Close()
}

func TestFetchRefusesHTTPSDowngrade(t *testing.T) {
	oldPlain, oldTLS := dialPlain, dialTLS
	defer func() { dialPlain, dialTLS = oldPlain, oldTLS }()
	dialTLS = func(string, uint16, string) (stream, error) {
		return &fakeStream{data: []byte("HTTP/1.1 301 Moved Permanently\r\nLocation: http://10.0.0.2/feed.xml\r\n\r\n")}, nil
	}
	dialPlain = func(string, uint16) (stream, error) {
		t.Fatal("https redirect must not be retried in the clear")
		return nil, nil
	}
	_, _, err := Fetch("https://example.com/feed.xml")
	if err == nil || !strings.Contains(err.Error(), "clear") {
		t.Fatalf("err = %v, want a cleartext refusal", err)
	}
}

func TestFetchRedirectLoopAndRelative(t *testing.T) {
	next, err := resolveRedirect(Classify("http://10.0.0.2:18099/a/feed.xml"), "rss.xml")
	if err != nil || next.Path != "/a/rss.xml" || next.Port != 18099 {
		t.Fatalf("relative = %+v err=%v", next, err)
	}
	next, err = resolveRedirect(Classify("https://example.com/feed.xml"), "//cdn.example/rss.xml")
	if err != nil || next.Scheme != SchemeHTTPS || next.Host != "cdn.example" {
		t.Fatalf("protocol-relative = %+v err=%v", next, err)
	}
	oldPlain, oldTLS := dialPlain, dialTLS
	defer func() { dialPlain, dialTLS = oldPlain, oldTLS }()
	dialTLS = func(string, uint16, string) (stream, error) { return nil, errors.New("no tls") }
	dialPlain = func(string, uint16) (stream, error) {
		return &fakeStream{data: []byte("HTTP/1.1 302 Found\r\nLocation: /feed.xml\r\n\r\n")}, nil
	}
	_, _, err = Fetch("http://10.0.0.2/feed.xml")
	if err == nil || !strings.Contains(err.Error(), "redirect") {
		t.Fatalf("err = %v, want a redirect failure", err)
	}
}

func chunkBody(payload []byte) string {
	var b strings.Builder
	for i := 0; i < len(payload); i += 17 {
		j := i + 17
		if j > len(payload) {
			j = len(payload)
		}
		part := payload[i:j]
		fmt.Fprintf(&b, "%x\r\n%s\r\n", len(part), part)
	}
	b.WriteString("0\r\n\r\n")
	return b.String()
}
