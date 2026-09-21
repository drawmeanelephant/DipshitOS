// Command httpd is GOHTTPD.ELF — the M71l (#1571) Go replacement for the Zig
// HTTPD.BIN: an in-guest HTTP/1.1 publisher that passively opens one port so a
// host on the NAT bridge can fetch this share.
//
// It listens on one TCP port (default 8080) via slot 30 ip-0, accepts ONE
// connection (the kernel TCP machine), answers it, closes, and exits. The
// class-B probe is the passive open itself -- the monitor shows `tcp=listen`
// while the server lives -- which is exactly what the Zig gate proved.
//
// Not on the boot path.
package main

import (
	"errors"

	"virelai/vi"
)

const (
	appName     = "GOHTTPD.ELF"
	defaultPort = 8080
)

const (
	markerStarting  = "httpd: starting"
	markerListening = "httpd: listening on port "
	markerRequest   = "httpd: request "
	markerServed    = "httpd: served"
	markerBye       = "httpd: bye"
	markerFailed    = "httpd: listen failed"
	markerErr       = "httpd: error "
)

// maxPinnedBytes caps the published file. The share is the host's, so the
// server does not trust it to be small.
const maxPinnedBytes = 256 * 1024

// argvEnvpGuard keeps the writable segment's bss end far enough from the page
// boundary for the kernel's packed argv+envp (see GOSSHD.ELF / GOSH.ELF). The
// size is chosen so this binary's writable segment leaves well over the 0x908
// bytes of page slack the kernel's first mmap needs; the build script verifies
// it and says so by name if a future edit moves the segment end.
var argvEnvpGuard [0x1ae0]byte

func init() {
	argvEnvpGuard[len(argvEnvpGuard)-1] = byte(len(argvEnvpGuard) & 0xff)
}

var errRequestTooLong = errors.New("httpd: request exceeds maxRequestBytes")

func main() {
	port := listenPort(vi.Args())
	vi.ConsoleLine(markerStarting)

	ln, err := vi.Listen(port)
	if err != nil {
		vi.ConsoleLine(markerFailed)
		vi.Exit(1)
	}
	vi.ConsoleLine(markerListening + vi.Itoa64(int64(port)))

	// One connection at a time (the kernel TCP machine), as GOSSHD does.
	if err := ln.Accept(); err != nil {
		_ = ln.Close()
		vi.ConsoleLine(markerErr + "accept")
		vi.Exit(1)
	}

	raw, err := readRequest(ln)
	if err != nil {
		_ = ln.Close()
		vi.ConsoleLine(markerErr + "recv")
		vi.Exit(1)
	}
	req, ok := parseRequest(raw)
	if !ok {
		_ = ln.Close()
		vi.ConsoleLine(markerErr + "parse")
		vi.Exit(1)
	}
	vi.ConsoleLine(markerRequest + req.Target)

	pinned := readWholeFile(sharePath, maxPinnedBytes)
	resp := route(req, pinned, pinned != nil)

	if _, err := ln.Send(formatResponse(resp, req.Method == "HEAD")); err != nil {
		_ = ln.Close()
		vi.ConsoleLine(markerErr + "send")
		vi.Exit(1)
	}
	_ = ln.Close()
	vi.ConsoleLine(markerServed)
	vi.ConsoleLine(markerBye)
	vi.Exit(0)
}

// readRequest buffers until the headers are complete, the bound is reached, or
// the peer stops sending.
func readRequest(ln *vi.Conn) ([]byte, error) {
	buf := make([]byte, 0, maxRequestBytes)
	chunk := make([]byte, vi.TCPPayloadMax)
	for len(buf) < maxRequestBytes {
		n, err := ln.Recv(chunk)
		if err != nil {
			return nil, err
		}
		if n <= 0 {
			continue
		}
		buf = append(buf, chunk[:n]...)
		if hasHeaderEnd(buf) {
			return buf, nil
		}
	}
	return nil, errRequestTooLong
}

// readWholeFile reads up to max bytes of a share file, or nil if it cannot be
// opened. Same shape as the browser's reader (see user/go/browser/text.go).
func readWholeFile(path string, max int) []byte {
	h, rc := vi.FileOpen(path, vi.ModeRead)
	if rc < 0 || h < 0 {
		return nil
	}
	defer vi.FileClose(uint32(h))
	out := make([]byte, 0, 4096)
	buf := make([]byte, 16*1024)
	for len(out) < max {
		n, rr := vi.FileRead(uint32(h), buf)
		if rr < 0 || n <= 0 {
			break
		}
		take := n
		if len(out)+take > max {
			take = max - len(out)
		}
		out = append(out, buf[:take]...)
		if take < n {
			break
		}
	}
	return out
}

// listenPort takes the first argv entry that parses as a port, else the default.
func listenPort(args []string) uint16 {
	for _, a := range args {
		if p, ok := atoiPort(a); ok {
			return p
		}
	}
	return defaultPort
}

func atoiPort(s string) (uint16, bool) {
	if s == "" || len(s) > 5 {
		return 0, false
	}
	var n int
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c < '0' || c > '9' {
			return 0, false
		}
		n = n*10 + int(c-'0')
		if n > 65535 {
			return 0, false
		}
	}
	if n == 0 {
		return 0, false
	}
	return uint16(n), true
}
