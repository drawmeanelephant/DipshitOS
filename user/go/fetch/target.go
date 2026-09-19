// Target classification for the M67b Go HTTPS consumer (issue #1447).
//
// The load-bearing rule is pure and host-tested: an https URL never turns
// into a cleartext TCP GET. The only success path is an in-process TLS 1.3
// dial (virelai/tls over vi.Dial). DNS hostnames are a defined error, not
// a resolve-and-hope — the live target is the runner TLS responder at an
// IP literal. FETCHS.BIN is not referenced.
package main

import "strings"

const (
	// DefaultSNI matches the pinned fixture leaf the runner responder
	// serves (leaf.example.com, AutoClaw test CA).
	DefaultSNI = "leaf.example.com"
	// DefaultHTTPSPort is the TLS port when the URL omits one.
	DefaultHTTPSPort uint16 = 443
)

// Kind is what Classify decided. "https" is the only kind that may produce
// a dial plan; every other kind is a refuse, never a silent downgrade.
const (
	KindHTTPS = "https"
	KindHTTP  = "http"
	KindDNS   = "dns"
	KindURL   = "url"
)

// Target is a classified URL. IPv4 is filled only for KindHTTPS.
type Target struct {
	Kind Kind
	Raw  string
	Host string
	Port uint16
	Path string
	IPv4 [4]byte
	SNI  string
}

// Kind is a string so serial markers can print it without a table.
type Kind = string

// DialPlan is the in-process TLS dial: address, port, SNI, request-target.
// There is no helper-exec field on purpose: this consumer owns the socket.
type DialPlan struct {
	Addr string
	Port uint16
	SNI  string
	Path string
}

// Classify decides what raw is. It never rewrites https:// to http://.
func Classify(raw string) Target {
	t := Target{Raw: raw, Port: DefaultHTTPSPort, Path: "/", SNI: DefaultSNI}
	if raw == "" {
		t.Kind = KindURL
		return t
	}
	low := strings.ToLower(raw)
	switch {
	case strings.HasPrefix(low, "https://"):
		return parseHTTPS(t, raw[len("https://"):])
	case strings.HasPrefix(low, "http://"):
		t.Kind = KindHTTP
		return t
	default:
		t.Kind = KindURL
		return t
	}
}

func parseHTTPS(t Target, rest string) Target {
	if rest == "" {
		t.Kind = KindURL
		return t
	}
	hostport := rest
	if i := strings.IndexByte(rest, '/'); i >= 0 {
		hostport = rest[:i]
		t.Path = rest[i:]
		if t.Path == "" {
			t.Path = "/"
		}
	}
	if hostport == "" {
		t.Kind = KindURL
		return t
	}
	host := hostport
	if i := strings.IndexByte(hostport, ':'); i >= 0 {
		host = hostport[:i]
		p, ok := parsePort(hostport[i+1:])
		if !ok {
			t.Kind = KindURL
			return t
		}
		t.Port = p
	}
	if host == "" {
		t.Kind = KindURL
		return t
	}
	t.Host = host
	if ip, ok := parseIPv4(host); ok {
		t.IPv4 = ip
		t.Kind = KindHTTPS
		return t
	}
	t.Kind = KindDNS
	return t
}

// PlanDial returns the in-process TLS dial for an https IP-literal target.
// Any other kind yields ok=false — including http, so a caller that only
// dials when ok cannot send an https URL in the clear.
func PlanDial(t Target) (DialPlan, bool) {
	if t.Kind != KindHTTPS {
		return DialPlan{}, false
	}
	sni := t.SNI
	if sni == "" {
		sni = DefaultSNI
	}
	path := t.Path
	if path == "" {
		path = "/"
	}
	return DialPlan{Addr: t.Host, Port: t.Port, SNI: sni, Path: path}, true
}

// WouldSendCleartext is true only for a classified http:// URL. This
// consumer never opens a cleartext socket: http is refused, https goes
// through tls.Dial.
func WouldSendCleartext(t Target) bool {
	return t.Kind == KindHTTP
}

func parseIPv4(text string) ([4]byte, bool) {
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
	if p == 0 {
		return "0"
	}
	var buf [5]byte
	i := len(buf)
	for p > 0 {
		i--
		buf[i] = byte('0' + p%10)
		p /= 10
	}
	return string(buf[i:])
}
