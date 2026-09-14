package webrender

import "testing"

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
