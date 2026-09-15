// Target classification for the M58d Go HTTPS consumer (issue #1308).
//
// The load-bearing rule is pure and host-tested: an https URL never turns
// into a cleartext TCP GET. The only success path is a helper plan that
// execs the in-tree Zig TLS client (FETCHS.BIN). DNS is not this card —
// a hostname is a defined error, not a resolve-and-hope.
package main

import "strings"

const (
	// HelperName is the Zig TLS 1.3 consumer already on main (ADR 0029).
	HelperName = "FETCHS.BIN"
	// DefaultSNI matches FETCHS.BIN / the pinned fixture leaf.
	DefaultSNI = "leaf.example.com"
	// DefaultHTTPSPort is the TLS port when the URL omits one.
	DefaultHTTPSPort uint16 = 443
)

// Kind is what Classify decided. "https" is the only kind that may produce
// a helper plan; every other kind is a refuse, never a silent downgrade.
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

// HelperPlan is what vi.Exec gets. There is no TCP field on purpose: a
// compile-time reminder that this consumer does not own a socket.
type HelperPlan struct {
	Name string
	Args []string
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

// PlanHelper returns the FETCHS.BIN argv for an https IP-literal target.
// Any other kind yields ok=false and a zero plan — including http, so a
// caller that only execs when ok cannot send an https URL in the clear.
func PlanHelper(t Target) (HelperPlan, bool) {
	if t.Kind != KindHTTPS {
		return HelperPlan{}, false
	}
	sni := t.SNI
	if sni == "" {
		sni = DefaultSNI
	}
	return HelperPlan{
		Name: HelperName,
		Args: []string{t.Host, portString(t.Port), sni},
	}, true
}

// WouldSendCleartext is the fail-closed pin: this consumer never opens a
// TCP socket of its own, so an https (or any) target cannot leave in the
// clear from Go. The Zig helper speaks TLS over TCP in its own process.
func WouldSendCleartext(t Target) bool {
	_ = t
	return false
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
