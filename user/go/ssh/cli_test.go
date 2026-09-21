package main

import "testing"

func TestParseTarget(t *testing.T) {
	got, ok := parseTarget([]string{"10.0.0.2"})
	if !ok || got.user != defaultUser || got.host != "10.0.0.2" || got.port != 22 || got.cmd != "" {
		t.Fatalf("default = %+v ok=%v", got, ok)
	}
	got, ok = parseTarget([]string{"alice@192.168.1.9:2222", "uname", "-a"})
	if !ok || got.user != "alice" || got.host != "192.168.1.9" || got.port != 2222 || got.cmd != "uname -a" {
		t.Fatalf("full = %+v ok=%v", got, ok)
	}
	if _, ok := parseTarget(nil); ok {
		t.Fatal("empty accepted")
	}
	for _, bad := range []string{"host.example", "10.0.0", "10.0.0.2.3", "256.0.0.1", "10.0.0.x", "@10.0.0.2", "10.0.0.2:", "10.0.0.2:0", "10.0.0.2:65536"} {
		if _, ok := parseTarget([]string{bad}); ok {
			t.Fatalf("accepted %q", bad)
		}
	}
}
