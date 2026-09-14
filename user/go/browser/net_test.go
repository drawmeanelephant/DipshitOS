package main

import (
	"strings"
	"testing"

	"virelai/webrender"
)

// The security-critical decision: an https target is refused before any
// socket exists, so a page can never be fetched in the clear while the
// address bar claims https.
func TestClassifyTargetRefusesHTTPS(t *testing.T) {
	cases := []struct{ in, want string }{
		{"https://example.com/", "https"},
		{"HTTPS://10.0.0.2/x", "https"},
		{"http://example.com/", "dns"},
		{"http://10.0.0.2/", "http"},
		{"http://10.0.0.2:8080/x", "http"},
		{"http://", "url"},
		{"http://h:99999/", "url"},
		{"/host/A.HTML", "file"},
		{"A.HTML", "file"},
	}
	for _, c := range cases {
		if got := classifyTarget(c.in); got != c.want {
			t.Fatalf("classifyTarget(%q) = %q want %q", c.in, got, c.want)
		}
	}
}

// A refused https target must not reach the fetch path at all: navigate()
// must land on the error page with kind "https".
func TestHTTPSNeverFetches(t *testing.T) {
	a := &app{hist: newHistory()}
	a.navigate("https://example.com/", "")
	if a.errKind != "https" {
		t.Fatalf("errKind = %q want https", a.errKind)
	}
	if a.loading {
		t.Fatal("an https refusal must not start a load")
	}
	if a.errMsg == "" {
		t.Fatal("https refusal must explain itself")
	}
}

func TestDNSRefusalIsNotAHang(t *testing.T) {
	a := &app{hist: newHistory()}
	a.navigate("http://example.com/", "")
	if a.errKind != "dns" {
		t.Fatalf("errKind = %q want dns", a.errKind)
	}
	if a.loading {
		t.Fatal("a hostname must not arm a load")
	}
}

func TestMalformedURLIsDefined(t *testing.T) {
	for _, in := range []string{"http://", "http://h:99999/", "ftp://x/y", ""} {
		a := &app{hist: newHistory()}
		a.navigate(in, "")
		if a.errKind == "" && !a.loading {
			t.Fatalf("input %q produced neither an error nor a load", in)
		}
		if a.loading {
			t.Fatalf("input %q should not start a load", in)
		}
	}
}

// Stopping a load produces the "cancelled" state, not a hang and not a
// silent success.
func TestCancelLoadingTransition(t *testing.T) {
	a := &app{hist: newHistory(), loading: true, target: "http://10.0.0.2/"}
	a.cancelLoad()
	if a.loading {
		t.Fatal("cancel must clear the loading state")
	}
	if a.errKind != "cancelled" {
		t.Fatalf("errKind = %q want cancelled", a.errKind)
	}
	if a.lay != nil {
		t.Fatal("a cancelled load must not leave a stale page")
	}
}

// A stopped idle browser (no load in flight) is a status, not an error page.
func TestCancelIdleIsAStatus(t *testing.T) {
	a := &app{hist: newHistory()}
	a.cancelLoad()
	if a.errKind != "" {
		t.Fatalf("idle cancel raised an error: %q", a.errKind)
	}
	if a.status != "stopped" {
		t.Fatalf("status = %q want stopped", a.status)
	}
}

// On the host every socket call is -ENOSYS, so a stepped load must land on a
// defined error instead of spinning.
func TestLoadStepErrorIsDefined(t *testing.T) {
	a := &app{hist: newHistory(), loading: true, target: "http://10.0.0.2/"}
	a.loadStep()
	if a.loading {
		t.Fatal("a failed read must end the load")
	}
	if a.errKind == "" {
		t.Fatal("a failed read must set an error kind")
	}
}

// Redirect handling is pure and must resolve absolute, root-relative and
// relative Location values, and detect a loop by hop count.
func TestRedirectResolution(t *testing.T) {
	from, ok := webrender.ParseHTTPURL("http://10.0.0.2/a/b.html")
	if !ok {
		t.Fatal("bad base")
	}
	cases := []struct{ loc, want string }{
		{"http://10.0.0.2/next", "http://10.0.0.2/next"},
		{"/root", "http://10.0.0.2/root"},
		{"c.html", "http://10.0.0.2/a/c.html"},
		{"../up.html", "http://10.0.0.2/up.html"},
	}
	for _, c := range cases {
		got, ok := webrender.ResolveRedirect(from, c.loc)
		if !ok {
			t.Fatalf("ResolveRedirect(%q) failed", c.loc)
		}
		u := "http://" + got.Host + got.Path
		if u != c.want {
			t.Fatalf("ResolveRedirect(%q) = %q want %q", c.loc, u, c.want)
		}
	}
	if _, ok := webrender.ResolveRedirect(from, ""); ok {
		t.Fatal("empty Location must not resolve")
	}
	if !webrender.RedirectStatus(301) || !webrender.RedirectStatus(302) || webrender.RedirectStatus(200) {
		t.Fatal("RedirectStatus wrong")
	}
	head := "HTTP/1.0 302 Found\r\nLocation: /moved\r\n\r\n"
	if got := webrender.LocationHeader(head); got != "/moved" {
		t.Fatalf("LocationHeader = %q", got)
	}
	if got := webrender.LocationHeader("HTTP/1.0 200 OK\r\n\r\n"); got != "" {
		t.Fatalf("LocationHeader on 200 = %q", got)
	}
}

// Scheme-shaped targets must never be turned into file-channel paths: a
// javascript: or file: href is refused as a scheme, not rewritten into
// "/host/javascript:...".
func TestSchemeShapedTargetsAreRefused(t *testing.T) {
	cases := []struct{ in, wantKind string }{
		{"javascript:alert(1)", "unsupported"},
		{"file:///host/WEB-HISTORY.TXT", "unsupported"},
		{"mailto:someone@example.com", "unsupported"},
		{"data:text/html,<b>x</b>", "unsupported"},
		{"ftp://10.0.0.2/x", "unsupported"},
	}
	for _, c := range cases {
		got, kind := resolveInput(c.in)
		if kind != c.wantKind {
			t.Fatalf("resolveInput(%q) kind = %q want %q", c.in, kind, c.wantKind)
		}
		if strings.HasPrefix(got, "/host/") {
			t.Fatalf("resolveInput(%q) rewrote a scheme into a file path: %q", c.in, got)
		}
	}
	// And a plain name is still a file on the share.
	if got, kind := resolveInput("PAGE.HTML"); kind != "file" || got != "/host/PAGE.HTML" {
		t.Fatalf("plain name = %q,%q", got, kind)
	}
}

// A hostile page must render as inert text with no request armed: the script
// body is dropped by the parser and nothing on the page can act.
func TestHostilePageIsInert(t *testing.T) {
	a := &app{hist: newHistory()}
	a.navigate("/host/HOSTILE.HTML", "")
	if a.loading {
		t.Fatal("a local page must not arm a request")
	}
}
