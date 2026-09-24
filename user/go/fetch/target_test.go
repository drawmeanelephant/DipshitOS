package main

import "testing"

func TestClassifyHTTPSIPLiteral(t *testing.T) {
	got := Classify("https://10.0.0.2:24533/")
	if got.Kind != KindHTTPS {
		t.Fatalf("kind = %q want https", got.Kind)
	}
	if got.Host != "10.0.0.2" || got.Port != 24533 || got.Path != "/" {
		t.Fatalf("target = %+v", got)
	}
	if got.IPv4 != [4]byte{10, 0, 0, 2} {
		t.Fatalf("ipv4 = %v", got.IPv4)
	}
	def := Classify("https://10.0.0.2/")
	if def.Port != DefaultHTTPSPort {
		t.Fatalf("default port = %d want %d", def.Port, DefaultHTTPSPort)
	}
	upper := Classify("HTTPS://10.0.0.2/x")
	if upper.Kind != KindHTTPS || upper.Path != "/x" {
		t.Fatalf("uppercase scheme = %+v", upper)
	}
}

func TestClassifyRefusesHostnameAndHTTP(t *testing.T) {
	cases := []struct{ in, want string }{
		{"https://example.com/", KindDNS},
		{"https://leaf.example.com:443/", KindDNS},
		{"http://10.0.0.2/", KindHTTP},
		{"HTTP://10.0.0.2/", KindHTTP},
		{"https://", KindURL},
		{"https://10.0.0.2:99999/", KindURL},
		{"https://10.0.0.2:", KindURL},
		{"ftp://10.0.0.2/", KindURL},
		{"", KindURL},
	}
	for _, c := range cases {
		if got := Classify(c.in); got.Kind != c.want {
			t.Fatalf("Classify(%q) = %q want %q", c.in, got.Kind, c.want)
		}
	}
}

func TestPlanDialHTTPS(t *testing.T) {
	tHTTPS := Classify("https://10.0.0.2:24533/")
	plan, ok := PlanDial(tHTTPS)
	if !ok {
		t.Fatal("https IP literal must produce a dial plan")
	}
	if plan.Addr != "10.0.0.2" || plan.Port != 24533 || plan.SNI != DefaultSNI || plan.Path != "/" {
		t.Fatalf("dial plan = %+v", plan)
	}
}

func TestPlanDialRefusesNonHTTPS(t *testing.T) {
	for _, in := range []string{
		"http://10.0.0.2/",
		"https://example.com/",
		"https://",
		"/host/PAGE.HTML",
		"",
	} {
		if plan, ok := PlanDial(Classify(in)); ok {
			t.Fatalf("Classify(%q) produced a dial plan %+v", in, plan)
		}
	}
}

func TestHTTPSNeverPlansCleartext(t *testing.T) {
	inputs := []string{
		"https://10.0.0.2:24533/",
		"https://10.0.0.2/",
		"HTTPS://10.0.0.2/x",
		"https://example.com/",
	}
	for _, in := range inputs {
		tgt := Classify(in)
		if WouldSendCleartext(tgt) {
			t.Fatalf("%q would send cleartext", in)
		}
		if _, ok := PlanClear(tgt); ok {
			t.Fatalf("%q produced a cleartext plan", in)
		}
		if tgt.Kind == KindHTTPS {
			if _, ok := PlanDial(tgt); !ok {
				t.Fatalf("%q is https but has no dial plan", in)
			}
		}
	}
}

func TestPlanClearOnlyForExplicitHTTP(t *testing.T) {
	plan, ok := PlanClear(Classify("http://10.0.0.2:8080/a/b.bin"))
	if !ok {
		t.Fatal("explicit http:// IP literal must plan cleartext")
	}
	if plan.Addr != "10.0.0.2" || plan.Port != 8080 || plan.Path != "/a/b.bin" {
		t.Fatalf("clear plan = %+v", plan)
	}
	if plan, ok := PlanClear(Classify("http://10.0.0.2/")); !ok || plan.Port != 80 {
		t.Fatalf("default clear port = %+v ok=%v", plan, ok)
	}
	for _, in := range []string{
		"http://example.com/",
		"http://10.0.0.2:99999/",
		"http://",
		"ftp://10.0.0.2/",
		"",
	} {
		if plan, ok := PlanClear(Classify(in)); ok {
			t.Errorf("PlanClear(%q) = %+v, want refuse", in, plan)
		}
	}
}

func TestPortString(t *testing.T) {
	if got := portString(443); got != "443" {
		t.Fatalf("portString(443) = %q", got)
	}
	if got := portString(1); got != "1" {
		t.Fatalf("portString(1) = %q", got)
	}
	if got := portString(65535); got != "65535" {
		t.Fatalf("portString(65535) = %q", got)
	}
}

func TestFailClosedMatchesRequiresSpecificVerdict(t *testing.T) {
	if failClosedMatches("name", errStr("ETIMEDOUT")) {
		t.Fatal("a timeout must not count as fail-closed name")
	}
	if failClosedMatches("expired", errStr("tls: transport failed")) {
		t.Fatal("a transport error must not count as expired")
	}
	if failClosedMatches("", errStr("x")) {
		t.Fatal("empty expect")
	}
}

func TestClassifyHTTPIPLiteral(t *testing.T) {
	got := Classify("http://10.0.0.2:8080/a/b.bin")
	if got.Kind != KindHTTP {
		t.Fatalf("kind = %q want http", got.Kind)
	}
	if got.Host != "10.0.0.2" || got.Port != 8080 || got.Path != "/a/b.bin" {
		t.Fatalf("target = %+v", got)
	}
	if got.IPv4 != [4]byte{10, 0, 0, 2} {
		t.Fatalf("ipv4 = %v", got.IPv4)
	}
	if def := Classify("http://10.0.0.2/"); def.Port != 80 {
		t.Fatalf("default port = %d want 80", def.Port)
	}
}

func TestMarkersHaveNoFETCHS(t *testing.T) {
	for _, s := range []string{
		markerDial, markerHandshake, markerHSErr, markerFailClosed,
		markerSent, markerBody, markerOK, markerError,
	} {
		if containsFETCHS(s) {
			t.Fatalf("marker %q still names FETCHS.BIN", s)
		}
	}
}

func containsFETCHS(s string) bool {
	return len(s) >= 10 && (s == "FETCHS.BIN" ||
		len(s) >= 10 && (indexOf(s, "FETCHS.BIN") >= 0))
}

func indexOf(s, sub string) int {
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return i
		}
	}
	return -1
}
