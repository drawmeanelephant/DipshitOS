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

func TestPlanHelperIsFETCHSOnly(t *testing.T) {
	tHTTPS := Classify("https://10.0.0.2:24533/")
	plan, ok := PlanHelper(tHTTPS)
	if !ok {
		t.Fatal("https IP literal must produce a helper plan")
	}
	if plan.Name != HelperName {
		t.Fatalf("helper name = %q want %s", plan.Name, HelperName)
	}
	if len(plan.Args) != 3 || plan.Args[0] != "10.0.0.2" || plan.Args[1] != "24533" || plan.Args[2] != DefaultSNI {
		t.Fatalf("helper args = %v", plan.Args)
	}
	for _, arg := range plan.Args {
		if len(arg) > 31 {
			t.Fatalf("argv slot %q exceeds the 31-byte exec cap", arg)
		}
	}
}

func TestPlanHelperRefusesNonHTTPS(t *testing.T) {
	for _, in := range []string{
		"http://10.0.0.2/",
		"https://example.com/",
		"https://",
		"/host/PAGE.HTML",
		"",
	} {
		if plan, ok := PlanHelper(Classify(in)); ok {
			t.Fatalf("Classify(%q) produced a helper plan %+v", in, plan)
		}
	}
}

func TestHTTPSNeverPlansCleartext(t *testing.T) {
	inputs := []string{
		"https://10.0.0.2:24533/",
		"https://10.0.0.2/",
		"HTTPS://10.0.0.2/x",
		"https://example.com/",
		"http://10.0.0.2/",
	}
	for _, in := range inputs {
		tgt := Classify(in)
		if WouldSendCleartext(tgt) {
			t.Fatalf("%q would send cleartext", in)
		}
		if tgt.Kind == KindHTTPS {
			if _, ok := PlanHelper(tgt); !ok {
				t.Fatalf("%q is https but has no helper plan", in)
			}
		}
		if tgt.Kind == KindHTTP {
			if _, ok := PlanHelper(tgt); ok {
				t.Fatalf("http URL %q must not be rewritten onto the TLS helper", in)
			}
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
