package settings

import (
	"os"
	"regexp"
	"strings"
	"testing"
)

// ---------------------------------------------------------------------------
// M66b (#1444): the schema-v2 decode, corrupt-fails-closed
// (moved here from user/go/gotabwm by M71f #1565 — one codec, two consumers)
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
		ss, ok := Parse([]byte(body))
		if !ok {
			t.Fatalf("%s: good file refused", name)
		}
		if v, found := Get(ss, "wm"); !found || v != "tabwm" && v != "none" {
			t.Fatalf("%s: wm = %q found=%v", name, v, found)
		}
	}
	// The seeded gate fixture, decoded end to end.
	ss, ok := Parse([]byte("#v2\nwm=none\n"))
	if !ok || len(ss) != 1 || ss[0].Key != "wm" || ss[0].Val != "none" {
		t.Fatalf("seeded fixture = %+v ok=%v", ss, ok)
	}
}

func TestSettingsParseIsFailClosed(t *testing.T) {
	bad := map[string]string{
		"empty":      "",          // a wiped file
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
		if ss, ok := Parse([]byte(body)); ok {
			t.Fatalf("%s: corrupt file parsed as %+v", name, ss)
		}
	}
}

// The kernel's parser drops a malformed ROW and the load stands; only the
// header gates the whole file. The decoder mirrors that (and caps the
// table like the kernel's 16 entries / 32-byte keys / 64-byte values).
func TestSettingsParseDropsRowsButStands(t *testing.T) {
	ss, ok := Parse([]byte("#v2\nwm=none\nno_equals_here\n=emptykey\n"))
	if !ok {
		t.Fatal("a malformed row refused the whole file")
	}
	if len(ss) != 1 {
		t.Fatalf("rows = %+v, want the wm row only", ss)
	}
	// The later duplicate wins, like the kernel's set-internal.
	ss, ok = Parse([]byte("#v2\nwm=none\nwm=tabwm\n"))
	if !ok {
		t.Fatal("duplicates refused the file")
	}
	if v, _ := Get(ss, "wm"); v != "tabwm" {
		t.Fatalf("wm = %q, want the later row", v)
	}
	// Rows past the table cap are dropped, the load still succeeds.
	var b strings.Builder
	b.WriteString("#v2\n")
	for i := 0; i < MaxKeys+3; i++ {
		b.WriteString("k" + strings.Repeat("x", i) + "=v\n")
	}
	ss, ok = Parse([]byte(b.String()))
	if !ok {
		t.Fatal("over-cap table refused the file")
	}
	if len(ss) != MaxKeys {
		t.Fatalf("rows = %d, want the capped %d", len(ss), MaxKeys)
	}
}

// Render is the write half of the codec: its bytes must equal what the
// kernel's own serializer emits for the same table (settings.zig init()
// order), so the two implementations cannot drift. Note the kernel
// round-trips `prompt=virelai> ` byte-exactly on WRITE (only a REload
// trims the value). This unit pin compares Go against a Go-side literal —
// it cannot catch kernel/Go drift by itself; the real cross-implementation
// pin is go-wm-default boot 04's share-equals on the healed file, and M71f's
// panel save is compared byte-for-byte on the share by that spec too.
func TestSettingsRenderMatchesTheKernelSerializer(t *testing.T) {
	rows := []Setting{
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
	if got := string(Render(rows)); got != want {
		t.Fatalf("render:\n got %q\nwant %q", got, want)
	}
}

// The full round-trip on values the format carries byte-exactly: parse ->
// render -> parse is stable and the wm key survives.
func TestSettingsRoundTripIsStable(t *testing.T) {
	body := "#v2\nwm=none\nhostname=box\nshadow=on\n"
	ss, ok := Parse([]byte(body))
	if !ok {
		t.Fatal("seed refused")
	}
	ss2, ok := Parse(Render(ss))
	if !ok {
		t.Fatal("re-parse refused the rendered bytes")
	}
	if len(ss2) != len(ss) {
		t.Fatalf("rows %d -> %d", len(ss), len(ss2))
	}
	for _, s := range ss {
		if v, found := Get(ss2, s.Key); !found || v != s.Val {
			t.Fatalf("key %s drifted: %q found=%v", s.Key, v, found)
		}
	}
}

// ---------------------------------------------------------------------------
// M71f (#1565): the panel's edit half — known keys, vocabularies, publish
// ---------------------------------------------------------------------------

// KnownKeys is a MIRROR of the kernel's compiled table, not a second schema.
// Read kernel/src/settings.zig and pin the mirror: every set_internal() key
// must be present here with the same default, and no extra key may be offered.
// A key added to the kernel and not to the panel is a failing test, not a
// silent drift.
func TestKnownKeysMirrorTheKernelTable(t *testing.T) {
	src, err := os.ReadFile("../../../kernel/src/settings.zig")
	if err != nil {
		t.Fatalf("read kernel/src/settings.zig: %v (this test only runs in-tree)", err)
	}
	// `_ = set_internal("key", "value");` — plus `wm`, whose default is the
	// `wm_default` const rather than a literal.
	rowRe := regexp.MustCompile(`set_internal\("([^"]+)", ("[^"]*"|[A-Za-z_][A-Za-z0-9_]*)\)`)
	constRe := regexp.MustCompile(`const wm_default: \[\]const u8 = "([^"]*)"`)

	cm := constRe.FindStringSubmatch(string(src))
	if cm == nil {
		t.Fatal("kernel/src/settings.zig: no wm_default const found")
	}
	consts := map[string]string{"wm_default": cm[1]}

	want := map[string]string{}
	for _, m := range rowRe.FindAllStringSubmatch(string(src), -1) {
		key, val := m[1], m[2]
		if strings.HasPrefix(val, `"`) {
			want[key] = strings.Trim(val, `"`)
			continue
		}
		v, ok := consts[val]
		if !ok {
			t.Fatalf("kernel default for %q is %s, which this test cannot resolve", key, val)
		}
		want[key] = v
	}
	if len(want) == 0 {
		t.Fatal("no set_internal rows parsed out of the kernel table")
	}

	got := map[string]string{}
	for _, k := range KnownKeys {
		got[k.Name] = k.Default
	}
	for key, val := range want {
		gv, ok := got[key]
		if !ok {
			t.Errorf("kernel key %q is not offered by the panel", key)
			continue
		}
		if gv != val {
			t.Errorf("key %q default %q, kernel %q", key, gv, val)
		}
	}
	for key := range got {
		if _, ok := want[key]; !ok {
			t.Errorf("panel offers %q, which the kernel table does not carry", key)
		}
	}
}

// A key absent from the file is still a row: the panel shows what is IN FORCE,
// so `wm` is settable on a share that has never carried one (card D2).
func TestDisplaySurfacesAbsentKnownKeysWithTheValueInForce(t *testing.T) {
	f := File{Rows: []Setting{{"hostname", "box"}}, State: StateOK}
	d := f.Display()
	// The one file row IS a known key, so the table is exactly the kernel's
	// eight: it is filled out, never duplicated.
	if len(d) != len(KnownKeys) {
		t.Fatalf("display rows = %d, want %d", len(d), len(KnownKeys))
	}
	if v, ok := Get(d, "wm"); !ok || v != "gotabwm" {
		t.Fatalf("wm row = %q ok=%v, want the compiled default", v, ok)
	}
	if v, ok := Get(d, "theme"); !ok || v != "dark" {
		t.Fatalf("theme row = %q ok=%v", v, ok)
	}
	if v, ok := Get(d, "hostname"); !ok || v != "box" {
		t.Fatalf("file row lost: %q ok=%v", v, ok)
	}
	// A missing file is the same story: the compiled defaults are in force.
	if v, ok := (File{State: StateMissing}).Effective("wm"); !ok || v != "gotabwm" {
		t.Fatalf("missing file wm = %q ok=%v", v, ok)
	}
}

// Effective prefers the file's value, then the kernel default; an unknown key
// with no row has no value at all.
func TestEffectivePrefersTheFileValue(t *testing.T) {
	f := File{Rows: []Setting{{"wm", "tabwm"}}, State: StateOK}
	if v, ok := f.Effective("wm"); !ok || v != "tabwm" {
		t.Fatalf("wm = %q ok=%v", v, ok)
	}
	if v, ok := f.Effective("shell"); !ok || v != "monitor" {
		t.Fatalf("shell = %q ok=%v", v, ok)
	}
	if v, ok := f.Effective("not_a_key"); ok {
		t.Fatalf("unknown key produced %q", v)
	}
}

// Set updates the LAST row for the key (the kernel's later-row-wins) or
// appends; it never duplicates.
func TestSetUpdatesTheLastRowOrAppends(t *testing.T) {
	ss := []Setting{{"wm", "none"}, {"shadow", "on"}, {"wm", "tabwm"}}
	ss = Set(ss, "wm", "gotabwm")
	if len(ss) != 3 {
		t.Fatalf("Set duplicated the key: %+v", ss)
	}
	if v, _ := Get(ss, "wm"); v != "gotabwm" {
		t.Fatalf("wm = %q", v)
	}
	if ss[2].Key != "wm" {
		t.Fatalf("Set rewrote the wrong row: %+v", ss)
	}
	ss = Set(ss, "shell", "sh")
	if len(ss) != 4 || ss[3].Key != "shell" {
		t.Fatalf("new key did not append: %+v", ss)
	}
}

// Next cycles a known vocabulary and restarts at the top for a value outside
// it (a value the seat would ignore, e.g. the Zig panel's `amber`).
func TestNextCyclesTheVocabulary(t *testing.T) {
	vocab, ok := Vocab("wm")
	if !ok {
		t.Fatal("wm has no vocabulary")
	}
	if got := Next(vocab, "gotabwm"); got != "tabwm" {
		t.Fatalf("gotabwm -> %q", got)
	}
	if got := Next(vocab, "none"); got != "gotabwm" {
		t.Fatalf("none -> %q (want the wrap)", got)
	}
	if got := Next(vocab, "amber"); got != "gotabwm" {
		t.Fatalf("outside value -> %q (want the top)", got)
	}
	// The Go seat's own reader has no amber palette (user/go/theme.Set
	// refuses it), so the panel must not offer one.
	if tv, _ := Vocab("theme"); !hasOnly(tv, "dark", "light") {
		t.Fatalf("theme vocabulary = %v, want exactly dark|light", tv)
	}
	if _, ok := Vocab("not_a_key"); ok {
		t.Fatal("unknown key has a vocabulary")
	}
}

func hasOnly(vocab []string, want ...string) bool {
	if len(vocab) != len(want) {
		return false
	}
	for i := range want {
		if vocab[i] != want[i] {
			return false
		}
	}
	return true
}

// A corrupt decode is refused by Save: the panel must never launder a file the
// kernel refused whole. StateMissing is NOT refused — a first boot is exactly
// how a fresh share gets a settings file.
func TestSaveRefusesOnlyACorruptDecode(t *testing.T) {
	if rc := (File{State: StateCorrupt}).Save(); rc != SaveRefused {
		t.Fatalf("corrupt save rc = %d, want SaveRefused", rc)
	}
	if SaveRefused == 0 {
		t.Fatal("SaveRefused must not look like success")
	}
}
