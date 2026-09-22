package feed

import (
	"strconv"
	"strings"
)

// Scheme is the transport a feed URL asks for. The only load-bearing property
// is that nothing here can turn an https URL into a cleartext request.
type Scheme string

const (
	SchemeHTTP    Scheme = "http"
	SchemeHTTPS   Scheme = "https"
	SchemeInvalid Scheme = "invalid"
)

// URL is a classified feed address. Host is a hostname (resolved in-guest by
// vi.Dial) or an IPv4 literal; Path always begins with "/".
type URL struct {
	Scheme Scheme
	Raw    string
	Host   string
	Port   uint16
	Path   string
}

// DefaultPort returns the scheme's default port (0 for an invalid scheme).
func (u URL) DefaultPort() uint16 {
	switch u.Scheme {
	case SchemeHTTPS:
		return 443
	case SchemeHTTP:
		return 80
	}
	return 0
}

// Classify parses raw into a URL. It is deliberately strict: an unknown or
// absent scheme is SchemeInvalid and the caller must refuse it, never retry
// it as cleartext.
func Classify(raw string) URL {
	u := URL{Scheme: SchemeInvalid, Raw: raw}
	s := strings.TrimSpace(raw)
	if s == "" {
		return u
	}
	lower := strings.ToLower(s)
	switch {
	case strings.HasPrefix(lower, "https://"):
		u.Scheme = SchemeHTTPS
		s = s[len("https://"):]
	case strings.HasPrefix(lower, "http://"):
		u.Scheme = SchemeHTTP
		s = s[len("http://"):]
	default:
		return u
	}
	// Authority ends at the first "/", "?" or "#".
	if i := strings.IndexAny(s, "/?#"); i >= 0 {
		u.Path = s[i:]
		s = s[:i]
	}
	if u.Path == "" || u.Path[0] != '/' {
		u.Path = "/" + strings.TrimPrefix(u.Path, "")
	}
	host := s
	if i := strings.LastIndex(host, ":"); i >= 0 {
		p, err := strconv.Atoi(host[i+1:])
		if err != nil || p <= 0 || p > 65535 {
			return URL{Scheme: SchemeInvalid, Raw: raw}
		}
		u.Port = uint16(p)
		host = host[:i]
	} else {
		u.Port = u.DefaultPort()
	}
	host = strings.TrimSpace(host)
	if host == "" {
		return URL{Scheme: SchemeInvalid, Raw: raw}
	}
	u.Host = host
	return u
}
