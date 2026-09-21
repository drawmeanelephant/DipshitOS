package feed

import (
	"errors"
	"strconv"
	"strings"

	"virelai/tls"
	"virelai/vi"
)

// Fetch-layer limits, all bounded on purpose: the guest is a modest 2-vCPU VM
// and vi.MaxFileBytes caps a single file load at 256 KiB.
const (
	// MaxBodyBytes bounds one feed document. Feeds larger than this are
	// truncated rather than allowed to grow the heap without limit.
	MaxBodyBytes = 256 * 1024
	// readChunk is the per-read buffer; TCPPayloadMax is 192, so a larger
	// buffer simply amortises the calls without changing the wire shape.
	readChunk = 8192
)

// Errors the UI can name.
var (
	ErrNetwork = errors.New("feed: network error")
	ErrTLS     = errors.New("feed: TLS validation failed")
	ErrStatus  = errors.New("feed: HTTP status error")
	ErrTooBig  = errors.New("feed: response too large")
)

// HTTPError carries the status code so the UI can say "HTTP 404" precisely.
type HTTPError struct{ Status int }

func (e HTTPError) Error() string { return "feed: HTTP " + strconv.Itoa(e.Status) }

// stream is the common read/write shape of a plain and a TLS connection, so
// the request path below is written once.
type stream interface {
	Write(p []byte) (int, error)
	Read(p []byte) (int, error)
	Close() error
}

// connStream adapts vi.Conn's Send/Recv onto the io-style shape.
type connStream struct{ c *vi.Conn }

func (s connStream) Write(p []byte) (int, error) { return s.c.Send(p) }

func (s connStream) Read(p []byte) (int, error) {
	n, err := s.c.Recv(p)
	if err != nil {
		return n, err
	}
	return n, nil
}

func (s connStream) Close() error { return s.c.Close() }

// Dial seams. They are package variables so a host test can substitute a fake
// transport and exercise the request/response split without a guest.
var (
	dialPlain = func(host string, port uint16) (stream, error) {
		c, err := vi.Dial(host, port)
		if err != nil {
			return nil, err
		}
		return connStream{c: c}, nil
	}
	dialTLS = func(host string, port uint16, sni string) (stream, error) {
		return tls.Dial(host, port, sni)
	}
)

// Fetch classifies raw, retrieves it over the correct transport, and parses
// the body. It returns the raw document alongside the parsed feed so a caller
// (or a test) can compare parsed fields against the original bytes.
func Fetch(raw string) (*Feed, []byte, error) {
	u := Classify(raw)
	if u.Scheme == SchemeInvalid {
		return nil, nil, errors.New("feed: unusable URL (need http:// or https://)")
	}
	body, err := get(u, MaxBodyBytes)
	if err != nil {
		return nil, nil, err
	}
	status, doc, err := splitResponse(body)
	if err != nil {
		return nil, nil, err
	}
	if status < 200 || status > 299 {
		return nil, nil, HTTPError{Status: status}
	}
	f, err := Parse(doc)
	if err != nil {
		return nil, doc, err
	}
	return f, doc, nil
}

// get dials, sends one HTTP/1.1 GET, and reads the whole response up to max
// bytes. A TLS handshake failure is reported as ErrTLS, never retried in the
// clear.
func get(u URL, max int) ([]byte, error) {
	var (
		s   stream
		err error
	)
	if u.Scheme == SchemeHTTPS {
		s, err = dialTLS(u.Host, u.Port, u.Host)
		if err != nil {
			return nil, wrapTLSErr(err)
		}
	} else {
		s, err = dialPlain(u.Host, u.Port)
		if err != nil {
			return nil, wrapNetErr(err)
		}
	}
	defer s.Close()

	req := "GET " + u.Path + " HTTP/1.1\r\n" +
		"Host: " + u.Host + "\r\n" +
		"User-Agent: VirelaiRSS/1.0\r\n" +
		"Accept: application/rss+xml, application/atom+xml, application/xml, text/xml, */*\r\n" +
		"Connection: close\r\n\r\n"
	if _, err := s.Write([]byte(req)); err != nil {
		return nil, wrapNetErr(err)
	}
	return readAll(s, max)
}

// readAll drains s up to max bytes. Hitting the cap is not an error: it is a
// deliberate bound, and the caller parses what arrived.
func readAll(s stream, max int) ([]byte, error) {
	buf := make([]byte, readChunk)
	out := make([]byte, 0, readChunk)
	for len(out) < max {
		n, err := s.Read(buf)
		if n > 0 {
			room := max - len(out)
			if n > room {
				n = room
			}
			out = append(out, buf[:n]...)
		}
		if err != nil || n == 0 {
			if len(out) > 0 {
				return out, nil
			}
			return out, wrapNetErr(err)
		}
	}
	return out, nil
}

// splitResponse separates status line and headers from the body. It is a pure
// helper so a host test can pin the split against a captured response without
// a socket. An empty body after the header block is legal.
func splitResponse(resp []byte) (int, []byte, error) {
	i := strings.Index(string(resp), "\r\n\r\n")
	sep := 4
	if i < 0 {
		i = strings.Index(string(resp), "\n\n")
		sep = 2
		if i < 0 {
			return 0, nil, errors.New("feed: response has no header terminator")
		}
	}
	head := string(resp[:i])
	body := resp[i+sep:]
	line := head
	if nl := strings.IndexAny(head, "\r\n"); nl >= 0 {
		line = head[:nl]
	}
	parts := strings.SplitN(strings.TrimSpace(line), " ", 3)
	if len(parts) < 2 || !strings.HasPrefix(parts[0], "HTTP/") {
		return 0, nil, errors.New("feed: malformed status line")
	}
	code, err := strconv.Atoi(parts[1])
	if err != nil {
		return 0, nil, errors.New("feed: malformed status line")
	}
	return code, body, nil
}

func wrapNetErr(err error) error {
	if err == nil {
		return nil
	}
	return errJoined(ErrNetwork, err)
}

func wrapTLSErr(err error) error {
	if err == nil {
		return nil
	}
	return errJoined(ErrTLS, err)
}

// errJoined keeps errors.Is working for both the sentinel and the cause while
// rendering as one readable line in the TUI.
type joined struct{ a, b error }

func (e joined) Error() string { return e.a.Error() + ": " + e.b.Error() }
func (e joined) Unwrap() []error {
	return []error{e.a, e.b}
}

func errJoined(a, b error) error { return joined{a: a, b: b} }
