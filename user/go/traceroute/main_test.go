package main

import "testing"

func TestParseArgs(t *testing.T) {
	cases := []struct {
		name     string
		args     []string
		ip       string
		attempts int
		probes   int
		ok, help bool
	}{
		{"defaults", nil, "10.0.0.2", 16, 3, true, false},
		{"image argv", []string{"GOTRACEROUTE.ELF", "-m", "8", "-q", "2", "192.168.0.1"}, "192.168.0.1", 8, 2, true, false},
		{"help", []string{"-h"}, "", 16, 3, true, true},
		{"missing max", []string{"-m"}, "", 16, 3, false, false},
		{"max out of range", []string{"-m", "65"}, "", 16, 3, false, false},
		{"probes out of range", []string{"-q", "6"}, "", 16, 3, false, false},
		{"bad ip", []string{"not-an-ip"}, "", 16, 3, false, false},
		{"duplicate target", []string{"10.0.0.2", "10.0.0.3"}, "", 16, 3, false, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, ok := parseArgs(tc.args)
			if ok != tc.ok || got.help != tc.help {
				t.Fatalf("parseArgs(%v) = (%+v,%v)", tc.args, got, ok)
			}
			if ok && (got.ipText != tc.ip || got.maxAttempts != tc.attempts || got.probes != tc.probes) {
				t.Fatalf("parseArgs(%v) = (%+v,%v)", tc.args, got, ok)
			}
		})
	}
}

func TestParsePositive(t *testing.T) {
	for _, tc := range []struct {
		in   string
		max  int
		want int
		ok   bool
	}{
		{"1", 64, 1, true},
		{"64", 64, 64, true},
		{"0", 64, 0, false},
		{"65", 64, 0, false},
		{"x", 64, 0, false},
		{"", 64, 0, false},
	} {
		got, ok := parsePositive(tc.in, tc.max)
		if got != tc.want || ok != tc.ok {
			t.Errorf("parsePositive(%q,%d) = (%d,%v)", tc.in, tc.max, got, ok)
		}
	}
}
