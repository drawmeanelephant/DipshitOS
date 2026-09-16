package main

// HTTPS helper plan for GOTGIT. Same rule as GOFETCH (M58d / #1308): an
// https URL never becomes a cleartext TCP GET. FETCHS.BIN owns the socket
// and the handshake. Extra argv slots carry method + share paths for the
// request-target, response, and POST body (31-byte argv cap).

const (
	helperName   = "FETCHS.BIN"
	defaultSNI   = "leaf.example.com"
	defaultHTTPS = uint16(443)
	kindHTTPS    = "https"
	kindHTTP     = "http"
	kindDNS      = "dns"
	kindURL      = "url"
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

type helperPlan struct {
	Name string
	Args []string
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

func planHelper(t target, method, pathFile, outFile, bodyFile string) (helperPlan, bool) {
	if t.Kind != kindHTTPS {
		return helperPlan{}, false
	}
	if method != "GET" && method != "POST" {
		return helperPlan{}, false
	}
	sni := t.SNI
	if sni == "" {
		sni = defaultSNI
	}
	args := []string{t.Host, portString(t.Port), sni, method, pathFile, outFile}
	if bodyFile != "" {
		args = append(args, bodyFile)
	}
	for _, a := range args {
		if len(a) > 31 {
			return helperPlan{}, false
		}
	}
	if len(args) > 8 {
		return helperPlan{}, false
	}
	return helperPlan{Name: helperName, Args: args}, true
}

func wouldSendCleartext(t target) bool {
	return t.Kind == kindHTTP
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
