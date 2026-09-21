package feed

import (
	"errors"
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
	data []byte
	off  int
}

func (f *fakeStream) Write(p []byte) (int, error) { return len(p), nil }

func (f *fakeStream) Read(p []byte) (int, error) {
	if f.off >= len(f.data) {
		return 0, errors.New("eof")
	}
	n := copy(p, f.data[f.off:])
	f.off += n
	return n, nil
}

func (f *fakeStream) Close() error { return nil }
