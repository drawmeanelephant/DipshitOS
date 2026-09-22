package shlib

import (
	"strings"
	"testing"
)

// toolOut runs one tool line through the engine and returns its output and
// status (the same path a user line takes, pipes included).
func toolOut(t *testing.T, h *fakeHost, line string) (string, int) {
	t.Helper()
	h.out = nil
	sh := NewShell(h, &History{})
	st, act := sh.RunLine(line)
	if act != ActionContinue {
		t.Fatalf("%q: unexpected action", line)
	}
	return h.outString(), st
}

func TestToolboxWc(t *testing.T) {
	h := newFakeHost()
	out, st := toolOut(t, h, "printf 'a\\nb\\nc\\n' | wc -l")
	if st != 0 || strings.TrimSpace(out) != "3" {
		t.Fatalf("wc -l = (%q, %d), want 3", out, st)
	}
	out, _ = toolOut(t, h, "printf 'one two three' | wc -w")
	if strings.TrimSpace(out) != "3" {
		t.Fatalf("wc -w = %q", out)
	}
	out, _ = toolOut(t, h, "printf 'xyz' | wc -c")
	if strings.TrimSpace(out) != "3" {
		t.Fatalf("wc -c = %q", out)
	}
	// File input through the host seam, TOOL.BIN-style output line.
	h.files["DATA.TXT"] = []byte("1\n2\n3\n")
	out, st = toolOut(t, h, "wc -l DATA.TXT")
	if st != 0 || out != "3 DATA.TXT\n" {
		t.Fatalf("wc -l FILE = (%q, %d), want \"3 DATA.TXT\"", out, st)
	}
}

func TestToolboxHeadTail(t *testing.T) {
	h := newFakeHost()
	out, _ := toolOut(t, h, "printf '1\\n2\\n3\\n4\\n5\\n' | head -n 2")
	if out != "1\n2\n" {
		t.Fatalf("head = %q", out)
	}
	out, _ = toolOut(t, h, "printf '1\\n2\\n3\\n4\\n5\\n' | tail -n 2")
	if out != "4\n5\n" {
		t.Fatalf("tail = %q", out)
	}
}

func TestToolboxGrep(t *testing.T) {
	h := newFakeHost()
	out, st := toolOut(t, h, "printf 'alpha\\nbeta\\nAlphaBeta\\n' | grep -i alpha")
	if st != 0 || out != "alpha\nAlphaBeta\n" {
		t.Fatalf("grep -i = (%q, %d)", out, st)
	}
	_, st = toolOut(t, h, "printf 'alpha' | grep zeta")
	if st != 1 {
		t.Fatalf("grep no-match status = %d, want 1", st)
	}
}

func TestToolboxSortCut(t *testing.T) {
	h := newFakeHost()
	out, _ := toolOut(t, h, "printf 'c\\na\\nb\\n' | sort")
	if out != "a\nb\nc\n" {
		t.Fatalf("sort = %q", out)
	}
	out, _ = toolOut(t, h, "printf 'b\\na\\nb\\n' | sort -r -u")
	if out != "b\na\n" {
		t.Fatalf("sort -r -u = %q", out)
	}
	out, _ = toolOut(t, h, "printf 'a:1:x\\nb:2:y\\n' | cut -d : -f 2")
	if out != "1\n2\n" {
		t.Fatalf("cut -d = %q", out)
	}
	out, _ = toolOut(t, h, "printf 'a:b:c\\n' | cut -d : -f 1,3")
	if out != "a:c\n" {
		t.Fatalf("cut list = %q", out)
	}
	out, _ = toolOut(t, h, "printf 'a:b:c\\n' | cut -d : -f 2-3")
	if out != "b:c\n" {
		t.Fatalf("cut range = %q", out)
	}
}

func TestToolboxPrintf(t *testing.T) {
	h := newFakeHost()
	out, _ := toolOut(t, h, "printf 'x=%s n=%d 100%% done' 7 7")
	if out != "x=7 n=7 100% done" {
		t.Fatalf("printf = %q", out)
	}
	out, _ = toolOut(t, h, "printf 'A\\nB\\tC\\\\D'")
	if out != "A\nB\tC\\D" {
		t.Fatalf("printf escapes = %q", out)
	}
}

func TestToolboxTest(t *testing.T) {
	h := newFakeHost()
	cases := []struct {
		line string
		want int
	}{
		{"test -n hello", 0},
		{"test -z ''", 0},
		{"test -n ''", 1},
		{`[ abc = abc ]`, 0},
		{`[ abc != xyz ]`, 0},
		{`[ 5 -lt 9 ]`, 0},
		{`[ 5 -ge 9 ]`, 1},
		{`[ -e DATA.TXT ]`, 0},
		{`[ -e /host/NOPE.TXT ]`, 1},
		{`[ one two ]`, 2}, // missing ] is a usage error
	}
	h.files["DATA.TXT"] = []byte("x")
	for _, tc := range cases {
		_, st := toolOut(t, h, tc.line)
		if st != tc.want {
			t.Fatalf("%q status = %d, want %d", tc.line, st, tc.want)
		}
	}
}

// TestToolboxCutEmptyDelim pins the empty-delimiter refusal: `cut -d ""`
// tokenizes to a genuine empty word (quoting makes a word, not a separator),
// so reading byte 0 of it would panic the shell on a typed line.
func TestToolboxCutEmptyDelim(t *testing.T) {
	h := newFakeHost()
	out, st := toolOut(t, h, `printf 'a:b\n' | cut -d "" -f 1`)
	if st != 2 {
		t.Fatalf(`cut -d "" status = %d, want 2`, st)
	}
	if !strings.Contains(out, "-d needs one delimiter character") {
		t.Fatalf(`cut -d "" message = %q`, out)
	}
	// The same empty word reached through a variable is refused too
	// (an unset or empty variable expands to a real empty argument).
	h2 := newFakeHost()
	run, _ := session(h2)
	if st := run("set E="); st != 0 {
		t.Fatalf("set status = %d", st)
	}
	h2.out = nil
	if st := run(`printf 'a:b\n' | cut -d $E -f 1`); st != 2 {
		t.Fatalf(`cut -d $E status = %d, want 2`, st)
	}
	if got := h2.outString(); !strings.Contains(got, "-d needs one delimiter character") {
		t.Fatalf(`cut -d $E message = %q`, got)
	}
}

// TestToolboxNegatives pins the usage refusals.
func TestToolboxNegatives(t *testing.T) {
	h := newFakeHost()
	for _, line := range []string{"wc -x", "head -z 1", "grep", "cut -f 0", "sort -x"} {
		_, st := toolOut(t, h, line)
		if st == 0 {
			t.Fatalf("%q unexpectedly succeeded", line)
		}
	}
}
