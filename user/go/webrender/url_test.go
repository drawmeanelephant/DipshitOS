package webrender

import (
	"strings"
	"testing"
)

func TestParseHTTPURL(t *testing.T) {
	cases := []struct {
		raw    string
		ok     bool
		host   string
		port   uint16
		path   string
		isIP   bool
		ipWord uint32
	}{
		{"http://10.0.0.2/", true, "10.0.0.2", 80, "/", true, 0x0A000002},
		{"http://10.0.0.2:80/x.html", true, "10.0.0.2", 80, "/x.html", true, 0x0A000002},
		{"http://10.0.0.2:8080", true, "10.0.0.2", 8080, "/", true, 0x0A000002},
		{"http://example.com/a/b", true, "example.com", 80, "/a/b", false, 0},
		{"HTTP://Example.COM/", true, "Example.COM", 80, "/", false, 0},
		{"https://example.com/", false, "", 0, "", false, 0},
		{"http://", false, "", 0, "", false, 0},
		{"http://h:99999/", false, "", 0, "", false, 0},
		{"", false, "", 0, "", false, 0},
	}
	for _, c := range cases {
		u, ok := ParseHTTPURL(c.raw)
		if ok != c.ok {
			t.Fatalf("%q: ok=%v want %v", c.raw, ok, c.ok)
		}
		if !ok {
			continue
		}
		if u.Host != c.host || u.Port != c.port || u.Path != c.path || u.IsIP != c.isIP {
			t.Fatalf("%q: got %+v", c.raw, u)
		}
		if c.isIP && IPv4ToU32(u.IPv4) != c.ipWord {
			t.Fatalf("%q: ip word %#x want %#x", c.raw, IPv4ToU32(u.IPv4), c.ipWord)
		}
	}
}

func TestParseIPv4Rejects(t *testing.T) {
	bad := []string{"", "1", "1.2.3", "1.2.3.4.5", "256.0.0.1", "1.2.3.999", "1.2.3.a", " 1.2.3.4", "1..2.3"}
	for _, s := range bad {
		if _, ok := ParseIPv4(s); ok {
			t.Fatalf("ParseIPv4(%q) accepted", s)
		}
	}
	if ip, ok := ParseIPv4("255.255.255.255"); !ok || IPv4ToU32(ip) != 0xFFFFFFFF {
		t.Fatalf("255.255.255.255 failed: %v", ip)
	}
}

func TestResolveHref(t *testing.T) {
	cases := []struct {
		base, href, want string
		ok               bool
	}{
		{"/host/PAGE.HTML", "NEXT.HTML", "/host/NEXT.HTML", true},
		{"/host/PAGE.HTML", "./NEXT.HTML", "/host/NEXT.HTML", true},
		{"/host/PAGE.HTML", "../UP.HTML", "/UP.HTML", true},
		{"/host/PAGE.HTML", "/abs/X.HTML", "/abs/X.HTML", true},
		{"/host/PAGE.HTML", "http://10.0.0.2/next", "http://10.0.0.2/next", true},
		{"/host/PAGE.HTML", "#frag", "", false},
		{"/host/PAGE.HTML", "NEXT.HTML#frag", "/host/NEXT.HTML", true},
	}
	for _, c := range cases {
		got, ok := ResolveHref(c.base, c.href)
		if ok != c.ok || got != c.want {
			t.Fatalf("ResolveHref(%q,%q) = %q,%v want %q,%v", c.base, c.href, got, ok, c.want, c.ok)
		}
	}
}

func TestHTTPStatusAndSplit(t *testing.T) {
	if s := HTTPStatus("HTTP/1.0 200 OK\r\n"); s != 200 {
		t.Fatalf("status=%d", s)
	}
	if s := HTTPStatus("HTTP/1.1 404 Not Found\n"); s != 404 {
		t.Fatalf("status=%d", s)
	}
	if s := HTTPStatus("garbage"); s != 0 {
		t.Fatalf("status=%d", s)
	}
	head, body, ok := SplitHTTPResponse([]byte("HTTP/1.0 200 OK\r\n\r\nhello"))
	if !ok || head != "HTTP/1.0 200 OK\r\n\r\n" || string(body) != "hello" {
		t.Fatalf("split: %q %q %v", head, body, ok)
	}
	if _, _, ok := SplitHTTPResponse([]byte("HTTP/1.0 200 OK\r\n")); ok {
		t.Fatal("truncated head accepted")
	}
}

func TestFormatGetRequest(t *testing.T) {
	got := FormatGetRequest("10.0.0.2", "/index.html")
	want := "GET /index.html HTTP/1.0\r\nHost: 10.0.0.2\r\nUser-Agent: VirelaiOS/1.0\r\n\r\n"
	if got != want {
		t.Fatalf("got %q", got)
	}
	if got := FormatGetRequest("h", ""); got[:4] != "GET " || got[4:5] != "/" {
		t.Fatalf("empty path: %q", got)
	}
}

func TestSetCookieHeaders(t *testing.T) {
	head := "HTTP/1.0 200 OK\r\nSet-Cookie: sid=abc; Path=/; HttpOnly; Secure\r\nSet-Cookie: theme=dark; Domain=.example.com\r\nset-cookie: bare=1\r\n\r\n"
	cs := SetCookieHeaders(head)
	if len(cs) != 3 {
		t.Fatalf("parsed %d cookies want 3: %+v", len(cs), cs)
	}
	if cs[0].Name != "sid" || cs[0].Value != "abc" || cs[0].Path != "/" || cs[0].Flags != "HttpOnly; Secure" {
		t.Fatalf("cookie 0 = %+v", cs[0])
	}
	if cs[1].Domain != ".example.com" {
		t.Fatalf("cookie 1 = %+v", cs[1])
	}
	if cs[2].Name != "bare" || cs[2].Value != "1" {
		t.Fatalf("cookie 2 = %+v", cs[2])
	}
	if got := SetCookieHeaders("HTTP/1.0 200 OK\r\nContent-Length: 3\r\n\r\n"); len(got) != 0 {
		t.Fatalf("cookie-less head parsed %d cookies", len(got))
	}
	// A malformed row must be skipped, not crash.
	if got := SetCookieHeaders("HTTP/1.0 200 OK\r\nSet-Cookie: novalue\r\n\r\n"); len(got) != 0 {
		t.Fatalf("malformed Set-Cookie parsed %d cookies", len(got))
	}
}

func TestCookieHeaderMatching(t *testing.T) {
	rows := []string{
		"1\tsid\tabc\t\t/\tHttpOnly",    // host-only, path /
		"2\tid\t7\t.example.com\t/\t",   // domain suffix
		"3\tscoped\tx\t\t/app\t",        // path /app
		"4\tother\t9\t.other.test\t/\t", // unrelated domain
		"broken",                        // malformed row ignored
	}
	got := CookieHeader(rows, "example.com", "/app/page")
	for _, want := range []string{"sid=abc", "id=7", "scoped=x"} {
		if !strings.Contains(got, want) {
			t.Fatalf("missing %s in %q", want, got)
		}
	}
	if strings.Contains(got, "other=9") {
		t.Fatalf("unrelated domain cookie leaked: %q", got)
	}
	if got := CookieHeader(rows, "example.com", "/other"); strings.Contains(got, "scoped=x") {
		t.Fatalf("path-scoped cookie leaked: %q", got)
	}
	if got := CookieHeader(nil, "example.com", "/"); got != "" {
		t.Fatalf("empty store produced %q", got)
	}
}

func TestFormatGetRequestWithCookies(t *testing.T) {
	plain := FormatGetRequest("10.0.0.2", "/")
	if got := FormatGetRequestWithCookies("10.0.0.2", "/", ""); got != plain {
		t.Fatalf("cookie-less request changed: %q", got)
	}
	got := FormatGetRequestWithCookies("10.0.0.2", "/x", "sid=abc; id=7")
	if !strings.Contains(got, "Cookie: sid=abc; id=7\r\n") {
		t.Fatalf("missing cookie header: %q", got)
	}
	if !strings.HasSuffix(got, "\r\n\r\n") {
		t.Fatalf("request must end with a blank line: %q", got)
	}
	if strings.Index(got, "Cookie:") > strings.Index(got, "\r\n\r\n") {
		t.Fatal("cookie header after the terminator")
	}
}
