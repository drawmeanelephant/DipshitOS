package main

import (
	"strings"
	"testing"
)

// ---------------------------------------------------------------------------
// M66b (#1444): the schema-v2 settings decode, corrupt-fails-closed
// ---------------------------------------------------------------------------

// The kernel's SETTINGS.TXT gate, mirrored: a valid `#v<digits>` header
// (v0/v1/v2 all parse and migrate up), then key=value rows. Everything the
// kernel refuses, this decoder refuses; everything the kernel accepts, it
// accepts.
func TestSettingsParseMirrorsTheKernelGate(t *testing.T) {
	good := map[string]string{
		"v2":     "#v2\nwm=none\nhostname=box\n",
		"v1":     "#v1\nwm=tabwm\n",
		"v0":     "#v0\nwm=tabwm\n",
		"crlf":   "#v2\r\nwm=none\r\n",
		"mkdirs": "#v2\n# a comment\n\n  wm = tabwm  \n",
	}
	for name, body := range good {
		ss, ok := parseSettingsTXT([]byte(body))
		if !ok {
			t.Fatalf("%s: good file refused", name)
		}
		if v, found := getSetting(ss, "wm"); !found || v != "tabwm" && v != "none" {
			t.Fatalf("%s: wm = %q found=%v", name, v, found)
		}
	}
	// The seeded gate fixture, decoded end to end.
	ss, ok := parseSettingsTXT([]byte("#v2\nwm=none\n"))
	if !ok || len(ss) != 1 || ss[0].key != "wm" || ss[0].val != "none" {
		t.Fatalf("seeded fixture = %+v ok=%v", ss, ok)
	}
}

func TestSettingsParseIsFailClosed(t *testing.T) {
	bad := map[string]string{
		"empty":      "", // a wiped file
		"headerless": "wm=none\n", // the partial in-place write shape
		"bare hash":  "#\nwm=none\n",
		"no digits":  "#v\nwm=none\n",
		"bad digit":  "#vx\nwm=none\n",
		"trailing":   "#v2x\nwm=none\n",
		"merged":     "#v2 wm=none\n", // header and data on one line
		"newer":      "#v3\nwm=none\n",
		"too long":   "#v1234\nwm=none\n",
		"pattern":    "\x00\x01\x02\x03\n", // vf write's probe-pattern garbage
	}
	for name, body := range bad {
		if ss, ok := parseSettingsTXT([]byte(body)); ok {
			t.Fatalf("%s: corrupt file parsed as %+v", name, ss)
		}
	}
}

// The kernel's parser drops a malformed ROW and the load stands; only the
// header gates the whole file. The decoder mirrors that (and caps the
// table like the kernel's 16 entries / 32-byte keys / 64-byte values).
func TestSettingsParseDropsRowsButStands(t *testing.T) {
	ss, ok := parseSettingsTXT([]byte("#v2\nwm=none\nno_equals_here\n=emptykey\n"))
	if !ok {
		t.Fatal("a malformed row refused the whole file")
	}
	if len(ss) != 1 {
		t.Fatalf("rows = %+v, want the wm row only", ss)
	}
	// The later duplicate wins, like the kernel's set-internal.
	ss, ok = parseSettingsTXT([]byte("#v2\nwm=none\nwm=tabwm\n"))
	if !ok {
		t.Fatal("duplicates refused the file")
	}
	if v, _ := getSetting(ss, "wm"); v != "tabwm" {
		t.Fatalf("wm = %q, want the later row", v)
	}
	// Rows past the table cap are dropped, the load still succeeds.
	var b strings.Builder
	b.WriteString("#v2\n")
	for i := 0; i < settingsMaxKeys+3; i++ {
		b.WriteString("k" + strings.Repeat("x", i) + "=v\n")
	}
	ss, ok = parseSettingsTXT([]byte(b.String()))
	if !ok {
		t.Fatal("over-cap table refused the file")
	}
	if len(ss) != settingsMaxKeys {
		t.Fatalf("rows = %d, want the capped %d", len(ss), settingsMaxKeys)
	}
}

// renderSettings is the write half of the codec: its bytes must equal what
// the kernel's own serializer emits for the same table (settings.zig
// init() order), so the two implementations cannot drift. Note the kernel
// round-trips `prompt=virelai> ` byte-exactly on WRITE (only a REload
// trims the value).
func TestSettingsRenderMatchesTheKernelSerializer(t *testing.T) {
	rows := []setting{
		{"hostname", "virelai"},
		{"prompt", "virelai> "},
		{"theme", "dark"},
		{"scrollback", "1000"},
		{"shadow", "off"},
		{"focus_follows_mouse", "off"},
		{"shell", "monitor"},
		{"wm", "tabwm"},
	}
	want := "#v2\nhostname=virelai\nprompt=virelai> \ntheme=dark\n" +
		"scrollback=1000\nshadow=off\nfocus_follows_mouse=off\n" +
		"shell=monitor\nwm=tabwm\n"
	if got := string(renderSettings(rows)); got != want {
		t.Fatalf("render:\n got %q\nwant %q", got, want)
	}
}

// The full round-trip on values the format carries byte-exactly: parse ->
// render -> parse is stable and the wm key survives.
func TestSettingsRoundTripIsStable(t *testing.T) {
	body := "#v2\nwm=none\nhostname=box\nshadow=on\n"
	ss, ok := parseSettingsTXT([]byte(body))
	if !ok {
		t.Fatal("seed refused")
	}
	ss2, ok := parseSettingsTXT(renderSettings(ss))
	if !ok {
		t.Fatal("re-parse refused the rendered bytes")
	}
	if len(ss2) != len(ss) {
		t.Fatalf("rows %d -> %d", len(ss), len(ss2))
	}
	for _, s := range ss {
		if v, found := getSetting(ss2, s.key); !found || v != s.val {
			t.Fatalf("key %s drifted: %q found=%v", s.key, v, found)
		}
	}
}

// The seat's markers are gate grep targets: the corrupt line names itself,
// the good line carries the decoded seat.
func TestSettingsMarkerShapes(t *testing.T) {
	if MarkerSettingsBad != "gotabwm: settings bad" {
		t.Fatalf("bad marker = %q", MarkerSettingsBad)
	}
	if MarkerSettingsWM != "gotabwm: settings wm=" {
		t.Fatalf("wm marker = %q", MarkerSettingsWM)
	}
}
