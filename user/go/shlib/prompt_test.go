package shlib

import (
	"strings"
	"testing"
)

// promptFacts is the fixture most tests expand against: an ordinary user in
// an ordinary directory on the seeded hostname.
func promptFacts() PromptFacts {
	return PromptFacts{User: "user", Host: "virelai", Cwd: "/data"}
}

// TestExpandPromptVocabulary pins every escape in the card, and the two
// rules that are easy to get wrong: a bracket span is LITERAL (so `\w`
// inside it prints as written, which is what makes the span useful for
// showing a literal escape to the user), and an unknown escape survives.
func TestExpandPromptVocabulary(t *testing.T) {
	cases := []struct {
		name, tmpl, want string
		facts            PromptFacts
	}{
		{"empty", "", "", promptFacts()},
		{"plain is untouched", "gosh> ", "gosh> ", promptFacts()},
		{"the whole vocabulary", `\u@\h:\w\$ `, "user@virelai:/data$ ", promptFacts()},
		{"root glyph", `\u\$ `, "system# ", PromptFacts{User: "system", Root: true}},
		{"user glyph", `\u\$ `, "user$ ", PromptFacts{User: "user"}},
		{"basename", `\W> `, "data> ", promptFacts()},
		{"basename of the root stays root", `\W> `, "/> ", PromptFacts{Cwd: "/"}},
		{"basename trims a trailing slash", `\W> `, "data> ", PromptFacts{Cwd: "/data/"}},
		{"cwd verbatim with no home", `\w`, "/data", PromptFacts{Cwd: "/data"}},
		{"cwd shortened against home", `\w`, "~/x", PromptFacts{Cwd: "/home/u/x", Home: "/home/u"}},
		{"home itself is tilde", `\w`, "~", PromptFacts{Cwd: "/home/u", Home: "/home/u"}},
		{"a prefix that is not a path boundary is not home", `\w`, "/home", PromptFacts{Cwd: "/home", Home: "/home/u"}},
		{"the root is not everybody's home", `\w`, "/data", PromptFacts{Cwd: "/data", Home: "/"}},
		{"bracket span is literal", `\[\w\]> `, `\w> `, promptFacts()},
		{"only the marks drop, the surrounding text stays", `[\[x\]]`, "[x]", promptFacts()},
		{"a stray closing bracket is dropped", `a\]b`, "ab", promptFacts()},
		{"double backslash is one", `a\\b`, `a\b`, promptFacts()},
		{"a trailing backslash is a backslash", `abc\`, `abc\`, promptFacts()},
		{"unknown escape survives", `\q\z`, `\q\z`, promptFacts()},
		{"empty facts expand, and an unknown cwd to nothing", `\u@\h:\w\$`, "@:$", PromptFacts{}},
	}
	for _, c := range cases {
		if got := ExpandPrompt(c.tmpl, c.facts); got != c.want {
			t.Errorf("%s: ExpandPrompt(%q) = %q want %q", c.name, c.tmpl, got, c.want)
		}
	}
}

// TestExpandPromptSGRPassthrough pins the colour contract: an SGR sequence
// reaches the terminal byte for byte, and a bracket span is the documented
// way to say "this paints nothing".
func TestExpandPromptSGRPassthrough(t *testing.T) {
	const green = "\x1b[32m"
	const reset = "\x1b[0m"
	f := promptFacts()
	if got := ExpandPrompt(green+`\w`+reset+`$ `, f); got != green+"/data"+reset+"$ " {
		t.Fatalf("bare SGR = %q", got)
	}
	// The bracket discipline is what makes the width measurable: the marks go,
	// the SGR stays, and the whole span counts zero cells.
	if got := ExpandPrompt(`\[`+green+`\]\w$ `, f); got != green+"/data$ " {
		t.Fatalf("bracketed SGR = %q", got)
	}
	// An unterminated CSI at the end of a template must not eat the template.
	if got := ExpandPrompt("\x1b[", f); got != "\x1b[" {
		t.Fatalf("truncated CSI = %q", got)
	}
}

// TestVisibleWidth pins the measurement the line editor's tail math depends
// on: cells, not bytes, with CSI and bracket spans counting nothing. The
// accented-character cases are the whole reason this is rune-based -- the
// grid stores one cell per rune (Screen.putByte -> putRune), so a prompt
// containing one is one cell wider than its byte length.
func TestVisibleWidth(t *testing.T) {
	cases := []struct {
		name, s string
		want    int
	}{
		{"empty", "", 0},
		{"ascii", "gosh> ", 6},
		{"one cell per ascii byte", "abc", 3},
		{"a two-byte rune is one cell", "é", 1},
		{"a three-byte rune is one cell", "→", 1},
		{"mixed", "aé→b", 4},
		{"sgr counts nothing", "\x1b[32mok\x1b[0m", 2},
		{"a long sgr parameter counts nothing", "\x1b[38;5;120mok", 2},
		{"a bracket span counts nothing", `\[\x1b[32m\]ok`, 2},
		{"an unterminated span swallows the rest", `\[abc`, 0},
		{"a lone escape paints nothing", "\x1bok", 2},
		{"invalid utf-8 still advances", "\xff", 1},
	}
	for _, c := range cases {
		if got := VisibleWidth(c.s); got != c.want {
			t.Errorf("%s: VisibleWidth(%q) = %d want %d", c.name, c.s, got, c.want)
		}
	}
}

// TestPromptFromSettings pins the shared loader: first key wins, the value is
// trimmed, CRLF carries no CR, and exactly ONE trailing space is appended --
// the loader's, not the template's, so `prompt=\w` needs none written out.
func TestPromptFromSettings(t *testing.T) {
	cases := []struct {
		name, body, want string
	}{
		{"missing key", "#v2\nwm=none\n", "gosh> "},
		{"empty body", "", "gosh> "},
		{"empty value", "prompt=\n", "gosh> "},
		{"whitespace value", "prompt=   \n", "gosh> "},
		{"one trailing space", "prompt=sh$\n", "sh$ "},
		{"trimmed", "prompt=  sh$  \n", "sh$ "},
		{"first key wins", "prompt=one\nprompt=two\n", "one "},
		{"indented", "  prompt=term> \n", "term> "},
		{"crlf", "prompt=sh$\r\n", "sh$ "},
		{"a substring is not the key", "xprompt=nope\n", "gosh> "},
		{"a template keeps its escapes, and the loader trims then adds one space", `prompt=\w> `, `\w> `},
		{"a bare backslash survives", `prompt=\`, `\` + " "},
	}
	for _, c := range cases {
		if got := PromptFromSettings(c.body, "gosh> "); got != c.want {
			t.Errorf("%s: PromptFromSettings(%q) = %q want %q", c.name, c.body, got, c.want)
		}
	}
}

// TestSettingFromSettingsAndPromptHost pins the generic key reader and the
// `\h` default, which is the hostname the kernel seeds.
func TestSettingFromSettingsAndPromptHost(t *testing.T) {
	body := "#v2\nwm=none\nhostname=box\nprompt=x\n"
	if got := SettingFromSettings(body, "wm", "none"); got != "none" {
		t.Fatalf("wm = %q", got)
	}
	if got := SettingFromSettings(body, "theme", "dark"); got != "dark" {
		t.Fatalf("missing theme = %q want the default", got)
	}
	if got := PromptHost(body); got != "box" {
		t.Fatalf("PromptHost = %q want %q", got, "box")
	}
	if got := PromptHost("prompt=x\n"); got != defaultHostName {
		t.Fatalf("PromptHost with no key = %q want %q", got, defaultHostName)
	}
	if got := PromptHost("hostname=\n"); got != defaultHostName {
		t.Fatalf("PromptHost with an empty key = %q want the default", got)
	}
}

// TestPromptUserName pins the `\u` vocabulary to the words `id` already
// prints, and the privilege glyph to the same principal.
func TestPromptUserName(t *testing.T) {
	if got := PromptUserName(uidSystem, true); got != "system" {
		t.Fatalf("uid 0 = %q want %q", got, "system")
	}
	if got := PromptUserName(1000, true); got != "user" {
		t.Fatalf("uid 1000 = %q want %q", got, "user")
	}
	if got := PromptUserName(uidSystem, false); got != "user" {
		t.Fatalf("no principal = %q want %q", got, "user")
	}
	if privilegeGlyph(true) != "#" || privilegeGlyph(false) != "$" {
		t.Fatalf("privilege glyphs = %q / %q", privilegeGlyph(true), privilegeGlyph(false))
	}
}

// TestPromptFactsFor pins the provider both front-ends share: the cwd comes
// from the shell's own PWD, the user and privilege glyph from the principal
// read AT CALL TIME, and a refused principal degrades to a plain user rather
// than to a stale uid.
func TestPromptFactsFor(t *testing.T) {
	uid := uint32(1000)
	sh := &Shell{env: NewEnv()}
	provider := PromptFactsFor(sh, func() (uint32, uint32, bool) { return uid, 0, true }, "box")
	f := provider()
	if f.Host != "box" || f.User != "user" || f.Root || f.Cwd != "/" {
		t.Fatalf("facts = %+v", f)
	}
	// `cd /data` moves the prompt, because the shell moved PWD.
	sh.env.Set("PWD", "/data")
	if got := provider().Cwd; got != "/data" {
		t.Fatalf("cwd after cd = %q", got)
	}
	// The principal is read per call, not captured at construction.
	uid = uidSystem
	f = provider()
	if f.User != "system" || !f.Root {
		t.Fatalf("facts after the principal changed = %+v", f)
	}
	// A host that cannot answer the principal seam says "user", not "system".
	refused := PromptFactsFor(nil, func() (uint32, uint32, bool) { return 0, 0, false }, "box")
	if f = refused(); f.User != "user" || f.Root || f.Cwd != "" {
		t.Fatalf("refused principal = %+v", f)
	}
}

// TestExpandPromptIsBounded is the honesty check on an escape that expands
// from the environment: a very long cwd cannot make the editor allocate
// without bound on every repaint. The expander itself is linear in the
// template plus what the facts contribute, so the bound that matters is the
// line's -- and the editor already refuses to grow past it.
func TestExpandPromptIsBounded(t *testing.T) {
	long := strings.Repeat("d", 4096)
	got := ExpandPrompt(`\w`, PromptFacts{Cwd: long})
	if len(got) != len(long) {
		t.Fatalf("expanded to %d bytes, want %d", len(got), len(long))
	}
}
