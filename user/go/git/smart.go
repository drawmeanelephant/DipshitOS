package main

import "virelai/git/gitread"

// Smart HTTP (git-http-protocol): GET info/refs?service=git-upload-pack
// then POST git-upload-pack with want/done. Push / receive-pack is out of
// scope (#1337).

type smartErr string

func (e smartErr) Error() string { return string(e) }

var (
	errNoRefs   = smartErr("smart: no refs")
	errHTTP     = smartErr("smart: bad http")
	errNoPack   = smartErr("smart: no packfile")
	errHTTPStat = smartErr("smart: http status")
)

type gitRef struct {
	Name string
	SHA  [20]byte
}

func splitHTTP(resp []byte) (status int, body []byte, err error) {
	sep := []byte("\r\n\r\n")
	i := indexBytes(resp, sep)
	hdrEnd := 0
	bodyOff := 0
	if i >= 0 {
		hdrEnd = i
		bodyOff = i + 4
	} else {
		sep = []byte("\n\n")
		i = indexBytes(resp, sep)
		if i < 0 {
			// Raw smart-HTTP body with no HTTP wrapper: a pkt-line
			// advertisement starts with 4 hex digits.
			if len(resp) >= 4 {
				if _, ok := parseHex4(resp[:4]); ok {
					return 200, resp, nil
				}
			}
			return 0, nil, errHTTP
		}
		hdrEnd = i
		bodyOff = i + 2
	}
	line := resp[:hdrEnd]
	if j := indexByte(line, '\n'); j >= 0 {
		line = line[:j]
	}
	if len(line) > 0 && line[len(line)-1] == '\r' {
		line = line[:len(line)-1]
	}
	status = httpStatus(line)
	if status == 0 {
		return 0, nil, errHTTP
	}
	if status < 200 || status > 299 {
		return status, resp[bodyOff:], errHTTPStat
	}
	return status, resp[bodyOff:], nil
}

func httpStatus(line []byte) int {
	// HTTP/1.0 200 OK  or  HTTP/1.1 200 OK
	sp := 0
	for sp < len(line) && line[sp] != ' ' {
		sp++
	}
	if sp >= len(line) {
		return 0
	}
	n, ok := atoi(line[sp+1:])
	if !ok {
		return 0
	}
	return n
}

func atoi(b []byte) (int, bool) {
	i := 0
	for i < len(b) && b[i] == ' ' {
		i++
	}
	if i >= len(b) || b[i] < '0' || b[i] > '9' {
		return 0, false
	}
	n := 0
	for i < len(b) && b[i] >= '0' && b[i] <= '9' {
		n = n*10 + int(b[i]-'0')
		if n > 999 {
			return 0, false
		}
		i++
	}
	return n, true
}

func indexByte(b []byte, c byte) int {
	for i, v := range b {
		if v == c {
			return i
		}
	}
	return -1
}

func indexBytes(b, sep []byte) int {
	if len(sep) == 0 {
		return 0
	}
	for i := 0; i+len(sep) <= len(b); i++ {
		ok := true
		for j := 0; j < len(sep); j++ {
			if b[i+j] != sep[j] {
				ok = false
				break
			}
		}
		if ok {
			return i
		}
	}
	return -1
}

// The byte-prefix helper moved to virelai/git/gitread (M74b #1645): the
// reader and the transport share one implementation.

func parseInfoRefs(body []byte) ([]gitRef, error) {
	var refs []gitRef
	b := body
	for len(b) >= 4 {
		p, rest, err := pktRead(b)
		if err != nil {
			break
		}
		b = rest
		if p.Flush || p.Delim || len(p.Data) == 0 {
			continue
		}
		if p.Data[0] == '#' {
			continue
		}
		if r, ok := parseRefLine(p.Data); ok {
			refs = append(refs, r)
		}
	}
	if len(refs) == 0 {
		return nil, errNoRefs
	}
	return refs, nil
}

func parseRefLine(data []byte) (gitRef, bool) {
	if len(data) > 0 && data[len(data)-1] == '\n' {
		data = data[:len(data)-1]
	}
	if len(data) < 41 || data[40] != ' ' {
		return gitRef{}, false
	}
	sha, ok := gitread.HexDecode(string(data[:40]))
	if !ok {
		return gitRef{}, false
	}
	name := data[41:]
	if i := indexByte(name, 0); i >= 0 {
		name = name[:i]
	}
	if len(name) == 0 {
		return gitRef{}, false
	}
	return gitRef{Name: string(name), SHA: sha}, true
}

func pickWant(refs []gitRef) (gitRef, bool) {
	var head gitRef
	var haveHead bool
	for _, r := range refs {
		if r.Name == "refs/heads/main" || r.Name == "refs/heads/master" {
			return r, true
		}
		if r.Name == "HEAD" {
			head = r
			haveHead = true
		}
	}
	if haveHead {
		return head, true
	}
	if len(refs) > 0 {
		return refs[0], true
	}
	return gitRef{}, false
}

func wantBody(sha [20]byte) []byte {
	line := "want " + gitread.HexEncode(sha[:]) + "\n"
	out := pktEncodeString(line)
	out = append(out, pktFlush()...)
	out = append(out, pktEncodeString("done\n")...)
	return out
}

func extractPack(body []byte) ([]byte, error) {
	var pack []byte
	b := body
	for len(b) >= 4 {
		if gitread.HasPrefix(b, "PACK") {
			return b, nil
		}
		p, rest, err := pktRead(b)
		if err != nil {
			if gitread.HasPrefix(b, "PACK") {
				return b, nil
			}
			if len(pack) >= 4 && gitread.HasPrefix(pack, "PACK") {
				return pack, nil
			}
			return nil, errNoPack
		}
		b = rest
		if p.Flush || p.Delim || len(p.Data) == 0 {
			continue
		}
		switch p.Data[0] {
		case 1:
			pack = append(pack, p.Data[1:]...)
		case 2:
			continue
		case 3:
			return nil, smartErr("smart: upload-pack error")
		default:
			if gitread.HasPrefix(p.Data, "NAK") || gitread.HasPrefix(p.Data, "ACK") {
				continue
			}
			if gitread.HasPrefix(p.Data, "PACK") {
				pack = append(pack, p.Data...)
				pack = append(pack, b...)
				return pack, nil
			}
		}
	}
	if gitread.HasPrefix(pack, "PACK") {
		return pack, nil
	}
	if gitread.HasPrefix(b, "PACK") {
		return b, nil
	}
	return nil, errNoPack
}

func infoRefsPath(repo string) string {
	return repo + "/info/refs?service=git-upload-pack"
}

func uploadPackPath(repo string) string {
	return repo + "/git-upload-pack"
}
