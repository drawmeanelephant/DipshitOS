package main

import "testing"

// The marker values are gate contracts: go-term.spec asserts each of them
// and go-wm-hid asserts `goterm: attached` (and the ABSENCE of
// `goterm: line ` on a boot where nobody typed). Renaming any of these is
// a spec change, not a refactor.
func TestTermMarkerShapes(t *testing.T) {
	cases := []struct{ got, want string }{
		{markerOpen, "goterm: open id="},
		{markerDeclare, "goterm: declare accepted"},
		{markerReady, "goterm: ready"},
		{markerTty, "goterm: tty"},
		{markerAttach, "goterm: attached"},
		{markerPrompt, "goterm: prompt"},
		{markerLine, "goterm: line "},
		{markerDone, "goterm: done status="},
		{markerClose, "goterm: close"},
		{markerOK, "goterm OK"},
		{markerMonitor, "goterm: monitor"},
		{markerMonErr, "goterm: monitor failed"},
		{markerOpenErr, "goterm: error open "},
		{markerTtyErr, "goterm: no /dev/tty"},
		{markerAttErr, "goterm: attach failed"},
		{ttyPath, "/dev/tty"},
	}
	for _, c := range cases {
		if c.got != c.want {
			t.Fatalf("marker = %q want %q", c.got, c.want)
		}
	}
}

// The default prompt is the shell's own (the same `gosh> ` GOSH falls
// back to); the live prompt comes from SETTINGS.TXT via
// promptFromSettings, never from a hand-written constant in this app.
func TestDefaultPromptIsTheShellFallback(t *testing.T) {
	if defaultPrompt != "gosh> " {
		t.Fatalf("defaultPrompt = %q want %q", defaultPrompt, "gosh> ")
	}
}

func TestPromptFromSettings(t *testing.T) {
	cases := []struct {
		name, body, want string
	}{
		{"missing key falls back", "#v2\nwm=none\n", defaultPrompt},
		{"empty body falls back", "", defaultPrompt},
		{"empty value falls back", "prompt=\n", defaultPrompt},
		{"whitespace value falls back", "prompt=   \n", defaultPrompt},
		{"key wins with one trailing space", "prompt=sh$\n", "sh$ "},
		{"value is trimmed", "prompt=  sh$  \n", "sh$ "},
		{"first key wins", "prompt=one\nprompt=two\n", "one "},
		{"indented key counts", "  prompt=term> \n", "term> "},
		{"CRLF value carries no CR", "prompt=sh$\r\n", "sh$ "},
		{"substring of another key is not the key", "xprompt=nope\n", defaultPrompt},
	}
	for _, c := range cases {
		if got := promptFromSettings(c.body, defaultPrompt); got != c.want {
			t.Errorf("%s: promptFromSettings(%q) = %q want %q", c.name, c.body, got, c.want)
		}
	}
}

func TestStartupLinesFrom(t *testing.T) {
	cases := []struct {
		name, body string
		want       []string
	}{
		{"empty", "", nil},
		{"blank only", "\n   \n\t\n", nil},
		{
			"CRLF folded, blanks dropped, order kept",
			"echo one\r\n\r\n  \necho two\r\necho three",
			[]string{"echo one", "echo two", "echo three"},
		},
		{
			"lone CR terminated lines are trimmed",
			"line one\r\nline two\r",
			[]string{"line one", "line two"},
		},
		{
			"content whitespace is preserved (the engine parses it)",
			" echo  padded \n",
			[]string{" echo  padded "},
		},
	}
	for _, c := range cases {
		got := startupLinesFrom(c.body)
		if len(got) != len(c.want) {
			t.Errorf("%s: got %d lines %q want %d %q", c.name, len(got), got, len(c.want), c.want)
			continue
		}
		for i := range got {
			if got[i] != c.want[i] {
				t.Errorf("%s: line %d = %q want %q", c.name, i, got[i], c.want[i])
			}
		}
	}
}
