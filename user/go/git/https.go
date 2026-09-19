package main

import (
	"virelai/tls"
	"virelai/vi"
)

// HTTPS for GOTGIT (M67b / #1447). An https URL never becomes a cleartext
// TCP GET. The process dials in-process via tls.Dial over vi.Dial.
// FETCHS.BIN is not referenced. Sequential GET then POST: one TCP socket
// per process, so the first conn is Closed before the second Dial.

const (
	defaultSNI   = "leaf.example.com"
	defaultHTTPS = uint16(443)
	kindHTTPS    = "https"
	kindHTTP     = "http"
	kindDNS      = "dns"
	kindURL      = "url"

	tlsRecordBuf = 16384
	tlsBodyCap   = vi.MaxFileBytes
)

type target struct {
	Kind string
	Raw  string
	Host string
	Port uint16
	Path string
	IPv4 [4]byte
	SNI  string
}

func classify(raw string) target {
	t := target{Raw: raw, Port: defaultHTTPS, Path: "/", SNI: defaultSNI}
	if raw == "" {
		t.Kind = kindURL
		return t
	}
	low := lowerASCII(raw)
	switch {
	case hasPrefixStr(low, "https://"):
		return parseHTTPS(t, raw[len("https://"):])
	case hasPrefixStr(low, "http://"):
		t.Kind = kindHTTP
		return t
	default:
		t.Kind = kindURL
		return t
	}
}

func parseHTTPS(t target, rest string) target {
	if rest == "" {
		t.Kind = kindURL
		return t
	}
	hostport := rest
	if i := indexByteStr(rest, '/'); i >= 0 {
		hostport = rest[:i]
		t.Path = rest[i:]
		if t.Path == "" {
			t.Path = "/"
		}
	}
	if hostport == "" {
		t.Kind = kindURL
		return t
	}
	host := hostport
	if i := indexByteStr(hostport, ':'); i >= 0 {
		host = hostport[:i]
		p, ok := parsePort(hostport[i+1:])
		if !ok {
			t.Kind = kindURL
			return t
		}
		t.Port = p
	}
	if host == "" {
		t.Kind = kindURL
		return t
	}
	t.Host = host
	if ip, ok := parseIPv4(host); ok {
		t.IPv4 = ip
		t.Kind = kindHTTPS
		return t
	}
	t.Kind = kindDNS
	return t
}

func repoPath(t target) string {
	p := t.Path
	if p == "" {
		p = "/"
	}
	for len(p) > 1 && p[len(p)-1] == '/' {
		p = p[:len(p)-1]
	}
	return p
}

func wouldSendCleartext(t target) bool {
	return t.Kind == kindHTTP
}

func httpsRequest(t target, method, path string, body []byte) ([]byte, error) {
	sni := t.SNI
	if sni == "" {
		sni = defaultSNI
	}
	c, err := tls.Dial(t.Host, t.Port, sni)
	if err != nil {
		return nil, err
	}
	defer c.Close()
	req := method + " " + path + " HTTP/1.0\r\nHost: " + sni + "\r\n"
	if method == "POST" {
		req += "Content-Type: application/x-git-upload-pack-request\r\n"
		req += "Content-Length: " + uitoa(uint64(len(body))) + "\r\n"
	}
	req += "Connection: close\r\n\r\n"
	if _, err := c.Write([]byte(req)); err != nil {
		return nil, err
	}
	if len(body) > 0 {
		if _, err := c.Write(body); err != nil {
			return nil, err
		}
	}
	return readTLS(c, tlsBodyCap)
}

func readTLS(c *tls.TLSConn, capn int) ([]byte, error) {
	tmp := make([]byte, tlsRecordBuf)
	var out []byte
	for len(out) < capn {
		n, err := c.Read(tmp)
		if n > 0 {
			out = append(out, tmp[:n]...)
		}
		if err != nil || n == 0 {
			if len(out) > 0 {
				return out, nil
			}
			return out, err
		}
	}
	return out, nil
}

func lowerASCII(s string) string {
	b := []byte(s)
	for i, c := range b {
		if c >= 'A' && c <= 'Z' {
			b[i] = c - 'A' + 'a'
		}
	}
	return string(b)
}

func hasPrefixStr(s, p string) bool {
	return len(s) >= len(p) && s[:len(p)] == p
}

func indexByteStr(s string, c byte) int {
	for i := 0; i < len(s); i++ {
		if s[i] == c {
			return i
		}
	}
	return -1
}

func parseIPv4(text string) ([4]byte, bool) {
	var out [4]byte
	part, cur, digits := 0, 0, 0
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
	out[part] = byte(cur)
	return out, true
}

func parsePort(s string) (uint16, bool) {
	if s == "" || len(s) > 5 {
		return 0, false
	}
	var n uint32
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c < '0' || c > '9' {
			return 0, false
		}
		n = n*10 + uint32(c-'0')
		if n > 65535 {
			return 0, false
		}
	}
	if n == 0 {
		return 0, false
	}
	return uint16(n), true
}

func portString(p uint16) string {
	return uitoa(uint64(p))
}
