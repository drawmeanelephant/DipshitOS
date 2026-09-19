// Server identity matching (RFC 6125 §6 / RFC 9525 §6), the Go mirror of
// user/src/lib/tls/identity.zig with the same tightened rules:
//   1. An IP-literal host compares ONLY against iPAddress SAN entries — the
//      CN is never consulted for an address.
//   2. Otherwise, if the certificate carries any SAN extension, only dNSName
//      entries are consulted; the CN is ignored even when SANs do not match.
//   3. Only a certificate with no SAN at all falls back to the CN — reported
//      as matchCNFallback and refused by ok().
//   4. Wildcards: `*` only as the entire left-most label of a `*.` pattern
//      with at least two more labels, matching exactly one label.
// Anything else fails closed.

package tls

type identityVerdict int

const (
	verdictMatchDNS identityVerdict = iota
	verdictMatchWildcard
	verdictMatchIP
	verdictMatchCNFallback // legacy path; deliberately excluded from ok()
	verdictNoMatch
	verdictAmbiguous
	verdictMalformedHost
	verdictNoIdentity
)

func (v identityVerdict) ok() bool {
	return v == verdictMatchDNS || v == verdictMatchWildcard || v == verdictMatchIP
}

// parseIPLiteral parses an IPv4 or IPv6 literal into the v4-mapped 16-byte
// form the iPAddress SANs use; ok is false when the text is not a literal.
func parseIPLiteral(host []byte) ([16]byte, bool) {
	for _, c := range host {
		if c == ':' {
			return parseIPv6Literal(host)
		}
	}
	return parseIPv4Literal(host)
}

func parseIPv4Literal(s []byte) ([16]byte, bool) {
	var out [16]byte
	var parts [4]byte
	n := 0
	i := 0
	for n < 4 {
		if i >= len(s) {
			return out, false
		}
		v := 0
		digits := 0
		for i < len(s) && s[i] != '.' {
			if s[i] < '0' || s[i] > '9' {
				return out, false
			}
			v = v*10 + int(s[i]-'0')
			if v > 255 {
				return out, false
			}
			digits++
			i++
			if digits > 3 {
				return out, false
			}
		}
		if digits == 0 {
			return out, false
		}
		if digits > 1 && s[i-digits] == '0' {
			return out, false // leading zeros are not a literal
		}
		parts[n] = byte(v)
		n++
		if i < len(s) {
			i++ // consume the dot
			if n == 4 {
				return out, false // a fifth group
			}
		}
	}
	if i != len(s) {
		return out, false
	}
	out[10] = 0xff
	out[11] = 0xff
	copy(out[12:], parts[:])
	return out, true
}

func hexDigitVal(c byte) int {
	switch {
	case c >= '0' && c <= '9':
		return int(c - '0')
	case c >= 'a' && c <= 'f':
		return int(c-'a') + 10
	case c >= 'A' && c <= 'F':
		return int(c-'A') + 10
	}
	return -1
}

// parseIPv6Literal handles "::" compression once, and v4-mapped tails.
func parseIPv6Literal(s []byte) ([16]byte, bool) {
	var out [16]byte
	var head [8]uint16
	var tail [8]uint16
	headLen, tailLen := 0, 0
	compressed := false
	headStr, tailStr := s, []byte(nil)

	for i := 0; i+1 < len(s); i++ {
		if s[i] == ':' && s[i+1] == ':' {
			compressed = true
			headStr = s[:i]
			tailStr = s[i+2:]
			if containsDoubleColon(tailStr) {
				return out, false
			}
			break
		}
	}
	hn, ok := parseV6Groups(&head, headStr)
	if !ok {
		return out, false
	}
	headLen = hn
	if tailStr != nil {
		tn, ok := parseV6Groups(&tail, tailStr)
		if !ok {
			return out, false
		}
		tailLen = tn
	}
	if !compressed && headLen != 8 {
		return out, false
	}
	if headLen+tailLen > 8 {
		return out, false
	}
	for k := 0; k < headLen; k++ {
		out[2*k] = byte(head[k] >> 8)
		out[2*k+1] = byte(head[k])
	}
	for k := 0; k < 8-headLen-tailLen; k++ {
		out[2*(headLen+k)] = 0
		out[2*(headLen+k)+1] = 0
	}
	for k := 0; k < tailLen; k++ {
		idx := headLen + (8 - headLen - tailLen) + k
		out[2*idx] = byte(tail[k] >> 8)
		out[2*idx+1] = byte(tail[k])
	}
	return out, true
}

func containsDoubleColon(s []byte) bool {
	for i := 0; i+1 < len(s); i++ {
		if s[i] == ':' && s[i+1] == ':' {
			return true
		}
	}
	return false
}

// parseV6Groups parses colon-separated groups; an embedded IPv4 tail is
// accepted and occupies the last two groups.
func parseV6Groups(out *[8]uint16, str []byte) (int, bool) {
	if len(str) == 0 {
		return 0, true
	}
	n := 0
	i := 0
	for i <= len(str) {
		// Find the token end.
		j := i
		for j < len(str) && str[j] != ':' {
			j++
		}
		tok := str[i:j]
		if len(tok) == 0 {
			return 0, false
		}
		hasDot := false
		for _, c := range tok {
			if c == '.' {
				hasDot = true
				break
			}
		}
		if hasDot {
			v4, ok := parseIPv4Literal(tok)
			if !ok || n+2 > 8 {
				return 0, false
			}
			out[n] = uint16(v4[12])<<8 | uint16(v4[13])
			out[n+1] = uint16(v4[14])<<8 | uint16(v4[15])
			n += 2
			return n, true // the v4 tail is always last
		}
		if len(tok) > 4 || n >= 8 {
			return 0, false
		}
		v := 0
		for _, c := range tok {
			d := hexDigitVal(c)
			if d < 0 {
				return 0, false
			}
			v = v<<4 | d
		}
		out[n] = uint16(v)
		n++
		if j >= len(str) {
			break
		}
		i = j + 1
		if i > len(str) {
			return 0, false
		}
	}
	return n, true
}

// matchDNS reports whether a dNSName SAN entry matches host (case-insensitive;
// one left-most wildcard at most).
func matchDNS(pattern, host []byte) bool {
	if len(pattern) == 0 || len(host) == 0 {
		return false
	}
	hasStar := false
	for _, c := range pattern {
		if c == '*' {
			hasStar = true
			break
		}
	}
	if !hasStar {
		return eqlIgnoreCase(pattern, host)
	}
	return matchWildcard(pattern, host)
}

func matchWildcard(pattern, host []byte) bool {
	if len(pattern) < 4 || pattern[0] != '*' || pattern[1] != '.' {
		return false
	}
	suffix := pattern[2:]
	if len(suffix) == 0 {
		return false
	}
	for _, c := range suffix {
		if c == '*' {
			return false
		}
	}
	// Refuse `*.com`-style patterns (no public-suffix list locally).
	hasDot := false
	for _, c := range suffix {
		if c == '.' {
			hasDot = true
			break
		}
	}
	if !hasDot {
		return false
	}
	// The host must be suffix plus exactly one non-empty label.
	if len(host) <= len(suffix)+1 {
		return false
	}
	dot := len(host) - len(suffix) - 1
	if host[dot] != '.' {
		return false
	}
	if dot == 0 {
		return false
	}
	for _, c := range host[:dot] {
		if c == '.' {
			return false
		}
	}
	return eqlIgnoreCase(host[dot+1:], suffix)
}

func eqlIgnoreCase(a, b []byte) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		x, y := a[i], b[i]
		if x >= 'A' && x <= 'Z' {
			x += 'a' - 'A'
		}
		if y >= 'A' && y <= 'Z' {
			y += 'a' - 'A'
		}
		if x != y {
			return false
		}
	}
	return true
}

// hostIsSane rejects empty labels, trailing dots, and non-DNS characters.
func hostIsSane(host []byte) bool {
	if len(host) == 0 || len(host) > 253 {
		return false
	}
	if host[len(host)-1] == '.' || host[0] == '.' {
		return false
	}
	prevDot := false
	for _, c := range host {
		allowed := c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '-' || c == '_' || c == '.'
		if !allowed {
			return false
		}
		if c == '.' && prevDot {
			return false
		}
		prevDot = c == '.'
	}
	return true
}

// verifyIdentity matches host against the certificate's identities.
func verifyIdentity(c *cert, host []byte) identityVerdict {
	if len(host) == 0 {
		return verdictMalformedHost
	}
	if ip, ok := parseIPLiteral(host); ok {
		for i := 0; i < c.sanLen; i++ {
			g := c.san[i]
			if g.isIP && g.ip == ip {
				return verdictMatchIP
			}
		}
		return verdictNoMatch
	}
	if !hostIsSane(host) {
		return verdictMalformedHost
	}
	if c.hasSAN {
		sawExact := false
		wildcardHits := 0
		for i := 0; i < c.sanLen; i++ {
			g := c.san[i]
			if g.isIP {
				continue
			}
			hasStar := false
			for _, ch := range g.dns {
				if ch == '*' {
					hasStar = true
					break
				}
			}
			if hasStar {
				if matchWildcard(g.dns, host) {
					wildcardHits++
				}
			} else if eqlIgnoreCase(g.dns, host) {
				sawExact = true
			}
		}
		if sawExact {
			return verdictMatchDNS
		}
		if wildcardHits == 0 {
			return verdictNoMatch
		}
		if wildcardHits > 1 {
			return verdictAmbiguous
		}
		return verdictMatchWildcard
	}
	// Legacy CN fallback, refused by ok().
	if c.subjectCN != nil && eqlIgnoreCase(c.subjectCN, host) {
		return verdictMatchCNFallback
	}
	return verdictNoMatch
}
