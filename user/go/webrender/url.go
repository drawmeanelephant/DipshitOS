// Package webrender is VirelaiOS's own HTML rendering library, written in Go
// for the in-guest browser (WEB.ELF). It parses a practical HTML subset,
// resolves a single compiled-in UA style table (no CSS cascade), lays out
// block + inline content, and paints through a caller-supplied Surface.
//
// Nothing here wraps an existing engine: the parser, the style table, the
// layout rules and the paint/span emission are this project's own code. The
// design follows the in-guest Zig renderer's rules (ADR 0028): no JavaScript,
// no cascade, unknown elements degrade to their text, static caps everywhere.
package webrender

import "strings"

// URL is a parsed HTTP URL (the only scheme the browser fetches).
type URL struct {
	Scheme string // "http" when parsed
	Host   string
	Port   uint16
	Path   string
	IPv4   [4]byte
	IsIP   bool
}

// IsHTTPURL reports whether s starts with http:// (case-insensitive).
func IsHTTPURL(s string) bool { return len(s) >= 7 && strings.EqualFold(s[:7], "http://") }

// IsExternalURL reports whether s is an absolute URL the browser cannot load
// from the local file channel.
func IsExternalURL(s string) bool {
	low := strings.ToLower(s)
	return strings.HasPrefix(low, "http://") || strings.HasPrefix(low, "https://") || strings.HasPrefix(low, "mailto:")
}

// ParseHTTPURL parses "http://host[:port][/path]". Port defaults to 80.
func ParseHTTPURL(raw string) (URL, bool) {
	if !IsHTTPURL(raw) {
		return URL{}, false
	}
	rest := raw[7:]
	if rest == "" {
		return URL{}, false
	}
	hostEnd := strings.IndexAny(rest, "/:")
	if hostEnd < 0 {
		hostEnd = len(rest)
	}
	if hostEnd == 0 {
		return URL{}, false
	}
	u := URL{Scheme: "http", Port: 80}
	u.Host = rest[:hostEnd]
	pathAt := hostEnd
	if hostEnd < len(rest) && rest[hostEnd] == ':' {
		i := hostEnd + 1
		var n uint32
		digits := 0
		for i < len(rest) && rest[i] >= '0' && rest[i] <= '9' {
			n = n*10 + uint32(rest[i]-'0')
			digits++
			if n > 65535 || digits > 5 {
				return URL{}, false
			}
			i++
		}
		if digits == 0 {
			return URL{}, false
		}
		u.Port = uint16(n)
		pathAt = i
	}
	if pathAt >= len(rest) {
		u.Path = "/"
	} else {
		u.Path = rest[pathAt:]
	}
	if u.Path == "" {
		u.Path = "/"
	}
	if ip, ok := ParseIPv4(u.Host); ok {
		u.IPv4 = ip
		u.IsIP = true
	}
	return u, true
}

// ParseIPv4 parses a dotted quad. Rejects anything that is not exactly four
// 0..255 decimal octets.
func ParseIPv4(text string) ([4]byte, bool) {
	var out [4]byte
	part := 0
	cur := 0
	digits := 0
	for i := 0; i < len(text); i++ {
		c := text[i]
		switch {
		case c >= '0' && c <= '9':
			cur = cur*10 + int(c-'0')
			if cur > 255 {
				return out, false
			}
			digits++
			if digits > 3 {
				return out, false
			}
		case c == '.':
			if digits == 0 || part >= 3 {
				return out, false
			}
			out[part] = byte(cur)
			part++
			cur = 0
			digits = 0
		default:
			return out, false
		}
	}
	if digits == 0 || part != 3 {
		return out, false
	}
	out[3] = byte(cur)
	return out, true
}

// IPv4ToU32 packs an IPv4 address the way sys_tcp_connect expects it
// (ip[0]<<24 | ip[1]<<16 | ip[2]<<8 | ip[3] — see user/src/lib/html/url.zig).
func IPv4ToU32(ip [4]byte) uint32 {
	return uint32(ip[0])<<24 | uint32(ip[1])<<16 | uint32(ip[2])<<8 | uint32(ip[3])
}

// DirName returns the directory part of a document path ("/host/PAGE.HTML"
// -> "/host"); a bare name yields ".".
func DirName(path string) string {
	if path == "" {
		return "."
	}
	i := strings.LastIndexByte(path, '/')
	if i < 0 {
		return "."
	}
	if i == 0 {
		return "/"
	}
	return path[:i]
}

// ResolveHref resolves href against the directory of basePath. Fragments are
// stripped; external URLs pass through unchanged; a leading '/' is rooted at
// "/". Returns ("", false) when the href is empty after fragment stripping.
func ResolveHref(basePath, href string) (string, bool) {
	target := href
	if h := strings.IndexByte(target, '#'); h >= 0 {
		target = target[:h]
	}
	if target == "" {
		return "", false
	}
	if IsExternalURL(target) {
		return target, true
	}
	if target[0] == '/' {
		return target, true
	}
	dir := DirName(basePath)
	rest := target
	for strings.HasPrefix(rest, "./") {
		rest = rest[2:]
	}
	for strings.HasPrefix(rest, "../") {
		dir = DirName(dir)
		rest = rest[3:]
	}
	if rest == "" {
		return dir, true
	}
	if dir == "." {
		return rest, true
	}
	if strings.HasSuffix(dir, "/") {
		return dir + rest, true
	}
	return dir + "/" + rest, true
}

// FormatGetRequest builds the HTTP/1.0 request the browser sends (the same
// shape the Zig DOC.BIN fetch path uses, so the host test responder and the
// gate's --net-tcp-respond see a byte-identical request line).
func FormatGetRequest(host, path string) string {
	p := path
	if p == "" {
		p = "/"
	}
	return "GET " + p + " HTTP/1.0\r\nHost: " + host + "\r\nUser-Agent: VirelaiOS/1.0\r\n\r\n"
}

// HTTPStatus extracts the status code from an HTTP/1.x response head.
// Returns 0 when the head does not start with a valid status line.
func HTTPStatus(head string) int {
	nl := strings.IndexByte(head, '\n')
	line := head
	if nl >= 0 {
		line = head[:nl]
	}
	line = strings.TrimSpace(line)
	if !strings.HasPrefix(line, "HTTP/") {
		return 0
	}
	sp := strings.IndexByte(line, ' ')
	if sp < 0 {
		return 0
	}
	rest := strings.TrimSpace(line[sp+1:])
	code := 0
	digits := 0
	for i := 0; i < len(rest); i++ {
		if rest[i] < '0' || rest[i] > '9' {
			break
		}
		code = code*10 + int(rest[i]-'0')
		digits++
	}
	if digits != 3 {
		return 0
	}
	return code
}

// SplitHTTPResponse splits a raw HTTP/1.x response into head and body,
// handling the optional Content-Length framing. The in-guest responder
// closes the connection after the body, so a missing length is tolerated.
func SplitHTTPResponse(raw []byte) (head string, body []byte, ok bool) {
	i := indexHeaderEnd(raw)
	if i < 0 {
		return "", nil, false
	}
	head = string(raw[:i])
	body = raw[i:]
	// The header terminator itself is \r\n\r\n (or \n\n); indexHeaderEnd
	// returns the offset of the body.
	return head, body, true
}

func indexHeaderEnd(raw []byte) int {
	for i := 0; i+1 < len(raw); i++ {
		if raw[i] == '\n' && raw[i+1] == '\n' {
			return i + 2
		}
		if i+3 < len(raw) && raw[i] == '\r' && raw[i+1] == '\n' && raw[i+2] == '\r' && raw[i+3] == '\n' {
			return i + 4
		}
	}
	return -1
}

// LocationHeader extracts the Location header value from a response head
// ("" when absent). The comparison is case-insensitive on the field name.
func LocationHeader(head string) string {
	lines := strings.Split(head, "\n")
	for _, ln := range lines[1:] {
		ln = strings.TrimRight(ln, "\r")
		i := strings.IndexByte(ln, ':')
		if i <= 0 {
			continue
		}
		if strings.EqualFold(strings.TrimSpace(ln[:i]), "location") {
			return strings.TrimSpace(ln[i+1:])
		}
	}
	return ""
}

// ResolveRedirect resolves a Location value against the URL that produced it.
// A Location may be absolute (http://...), root-relative (/x), or relative
// (x, ../x). Returns ok=false when the result is not an http URL we can use.
func ResolveRedirect(from URL, location string) (URL, bool) {
	if location == "" {
		return URL{}, false
	}
	if IsHTTPURL(location) {
		return ParseHTTPURL(location)
	}
	if strings.HasPrefix(location, "//") {
		// Protocol-relative: keep the scheme we already have.
		return ParseHTTPURL("http:" + location)
	}
	base := "http://" + from.Host
	if from.Path != "" && from.Path != "/" {
		if i := strings.LastIndexByte(from.Path, '/'); i >= 0 {
			base += from.Path[:i+1]
		} else {
			base += "/"
		}
	} else {
		base += "/"
	}
	resolved, ok := ResolveHrefForRedirect(base, location)
	if !ok {
		return URL{}, false
	}
	return ParseHTTPURL(resolved)
}

// ResolveHrefForRedirect is ResolveHref specialised for absolute http bases.
func ResolveHrefForRedirect(base, href string) (string, bool) {
	if strings.HasPrefix(href, "/") {
		if u, ok := ParseHTTPURL(base); ok {
			return "http://" + u.Host + href, true
		}
		return "", false
	}
	return ResolveHref(base, href)
}

// RedirectStatus reports whether a status code is a redirect we follow.
func RedirectStatus(code int) bool { return code >= 300 && code < 400 }
