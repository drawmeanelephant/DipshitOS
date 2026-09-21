package main

import (
	"bytes"
	"strconv"
	"strings"
	"testing"
)

func TestParseRequestAcceptsGetAndHead(t *testing.T) {
	for _, raw := range []string{
		"GET / HTTP/1.1\r\nHost: x\r\n\r\n",
		"HEAD /healthz HTTP/1.1\r\n\r\n",
		"GET /file HTTP/1.0\n\n",
	} {
		req, ok := parseRequest([]byte(raw))
		if !ok {
			t.Fatalf("parseRequest(%q) refused a well-formed request", raw)
		}
		if !strings.HasPrefix(req.Target, "/") {
			t.Fatalf("parseRequest(%q) target = %q", raw, req.Target)
		}
	}
}

func TestParseRequestRefusals(t *testing.T) {
	cases := map[string]string{
		"unterminated headers":  "GET / HTTP/1.1\r\nHost: x\r\n",
		"no method":             " / HTTP/1.1\r\n\r\n",
		"no version":            "GET /\r\n\r\n",
		"http/2":                "GET / HTTP/2.0\r\n\r\n",
		"absolute-form target":  "GET http://example.com/ HTTP/1.1\r\n\r\n",
		"empty":                 "",
		"garbage":               "not a request at all\r\n\r\n",
		"missing space + ver":   "GET /\r\n\r\n",
		"version without slash": "GET / HTTP1.1\r\n\r\n",
	}
	for name, raw := range cases {
		if _, ok := parseRequest([]byte(raw)); ok {
			t.Errorf("%s: parseRequest(%q) accepted a bad request", name, raw)
		}
	}
}

func TestRouteSurfaces(t *testing.T) {
	pinned := []byte("pinned body\n")

	got := route(request{Method: "GET", Target: "/"}, nil, false)
	if got.Status != 200 || !strings.Contains(string(got.Body), "VirelaiOS") {
		t.Fatalf("index: status=%d body=%q", got.Status, got.Body)
	}

	got = route(request{Method: "GET", Target: "/healthz"}, nil, false)
	if got.Status != 200 || got.ContentType != "application/json" {
		t.Fatalf("healthz: status=%d type=%q", got.Status, got.ContentType)
	}
	if !bytes.Contains(got.Body, []byte("\"status\":\"ok\"")) {
		t.Fatalf("healthz body = %q", got.Body)
	}

	got = route(request{Method: "GET", Target: shareTarget}, pinned, true)
	if got.Status != 200 || !bytes.Equal(got.Body, pinned) {
		t.Fatalf("file present: status=%d body=%q", got.Status, got.Body)
	}
	if got.ContentType != "text/plain; charset=utf-8" {
		t.Fatalf("file mime = %q", got.ContentType)
	}

	got = route(request{Method: "GET", Target: shareTarget}, nil, false)
	if got.Status != 404 {
		t.Fatalf("file absent: status=%d", got.Status)
	}

	got = route(request{Method: "GET", Target: "/nope"}, nil, false)
	if got.Status != 404 {
		t.Fatalf("unknown target: status=%d", got.Status)
	}

	got = route(request{Method: "POST", Target: "/"}, nil, false)
	if got.Status != 405 {
		t.Fatalf("non-GET/HEAD: status=%d", got.Status)
	}
}

func TestRouteNeverReadsARequestedPath(t *testing.T) {
	// The only target that can reach the filesystem is the pinned one; a
	// traversal-shaped target is an ordinary 404, not a file read.
	for _, target := range []string{"/../HTTPD.TXT", "/host/HTTPD.TXT", "/%2e%2e/HTTPD.TXT"} {
		if got := route(request{Method: "GET", Target: target}, []byte("secret"), true); got.Status != 404 {
			t.Errorf("target %q: status=%d, want 404", target, got.Status)
		}
	}
}

func TestFormatResponse(t *testing.T) {
	resp := response{Status: 200, ContentType: "text/plain; charset=utf-8", Body: []byte("hello\n")}

	full := string(formatResponse(resp, false))
	for _, want := range []string{
		"HTTP/1.1 200 OK\r\n",
		"Server: VirelaiOS\r\n",
		"Content-Type: text/plain; charset=utf-8\r\n",
		"Content-Length: 6\r\n",
		"Connection: close\r\n\r\n",
	} {
		if !strings.Contains(full, want) {
			t.Errorf("full response missing %q:\n%s", want, full)
		}
	}
	if !strings.HasSuffix(full, "hello\n") {
		t.Errorf("full response lost the body: %q", full)
	}

	head := string(formatResponse(resp, true))
	if strings.Contains(head, "hello") {
		t.Errorf("HEAD response carried a body: %q", head)
	}
	if !strings.Contains(head, "Content-Length: 6\r\n") {
		t.Errorf("HEAD response lost the entity length: %q", head)
	}
}

func TestFormatResponseStatusText(t *testing.T) {
	for status, text := range statusText {
		line := string(formatResponse(response{Status: status}, true))
		want := "HTTP/1.1 " + strconv.Itoa(status) + " " + text + "\r\n"
		if !strings.HasPrefix(line, want) {
			t.Errorf("status %d: first line %.20q, want prefix %q", status, line, want)
		}
	}
}

func TestMimeForPath(t *testing.T) {
	cases := map[string]string{
		"/host/HTTPD.TXT": "text/plain; charset=utf-8",
		"/host/PAGE.HTML": "text/html; charset=utf-8",
		"/host/data.json": "application/json",
		"/host/img.png":   "image/png",
		"/host/img.qoi":   "image/qoi",
		"/host/noext":     "application/octet-stream",
		"/host/weird.bin": "application/octet-stream",
	}
	for path, want := range cases {
		if got := mimeForPath(path); got != want {
			t.Errorf("mimeForPath(%q) = %q, want %q", path, got, want)
		}
	}
}

func TestAtoiPort(t *testing.T) {
	if p, ok := atoiPort("8080"); !ok || p != 8080 {
		t.Errorf("atoiPort(8080) = %d,%v", p, ok)
	}
	for _, bad := range []string{"", "0", "abc", "8080x", "99999", "-1"} {
		if _, ok := atoiPort(bad); ok {
			t.Errorf("atoiPort(%q) accepted a bad port", bad)
		}
	}
}

func TestListenPortDefaults(t *testing.T) {
	if got := listenPort(nil); got != defaultPort {
		t.Errorf("listenPort(nil) = %d", got)
	}
	if got := listenPort([]string{"--x", "9090"}); got != 9090 {
		t.Errorf("listenPort = %d, want 9090", got)
	}
}
