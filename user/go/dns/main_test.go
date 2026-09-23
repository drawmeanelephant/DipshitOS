package main

import "testing"

func TestParseArgs(t *testing.T) {
	cases := []struct {
		name       string
		args       []string
		wantHost   string
		wantServer [4]byte
		ok, help   bool
	}{
		{"image argv and default server", []string{"GODNS.ELF", "example.com"}, "example.com", [4]byte{10, 0, 0, 2}, true, false},
		{"explicit server", []string{"example.com", "1.1.1.1"}, "example.com", [4]byte{1, 1, 1, 1}, true, false},
		{"empty help", nil, "", [4]byte{}, true, true},
		{"flag help", []string{"--help"}, "", [4]byte{}, true, true},
		{"bad resolver", []string{"example.com", "nope"}, "", [4]byte{}, false, false},
		{"extra argument", []string{"example.com", "10.0.0.2", "extra"}, "", [4]byte{}, false, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, ok := parseArgs(tc.args)
			if ok != tc.ok || got.help != tc.help || got.host != tc.wantHost || got.server != tc.wantServer {
				t.Fatalf("parseArgs(%v) = (%+v,%v)", tc.args, got, ok)
			}
		})
	}
}
