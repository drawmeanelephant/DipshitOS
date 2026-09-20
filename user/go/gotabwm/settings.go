// GOTABWM.ELF — M66b (#1444): the schema-v2 SETTINGS.TXT decode, the
// corrupt-fails-closed twin of M62e's `.tabs` v2 session handling.
//
// The kernel owns the file (kernel/src/settings.zig): it writes the `#v2`
// header, and since M66b it saves crash-safe (temp + fsync + rename, never
// an in-place truncate) and REFUSES a file whose header is not a valid
// schema version — the partial-write shape — falling back to the compiled
// defaults. This seat-side decoder mirrors that contract for the Go seat:
// the same key=value grammar, the same header gate, and the same
// corrupt-fails-closed verdict. A bad file is reported and IGNORED — the
// seat boots on its own defaults, nothing is written back, and a corrupt
// file is never laundered into a half-parsed one.
//
// renderSettings is the codec's write half (the byte shape the kernel's
// own serializer emits); it is pinned host-side against that shape so the
// two implementations cannot drift, and is what later Go consumers of the
// settings round-trip will write through.

package main

import (
	"strings"

	"virelai/theme"
	"virelai/vi"
)

const (
	settingsPath    = "/host/SETTINGS.TXT"
	settingsMaxKeys = 16   // the kernel's max_entries table
	settingsMaxKey  = 32   // the kernel's max_key_len
	settingsMaxVal  = 64   // the kernel's max_val_len
	settingsMaxBody = 2048 // the kernel's bounded load buffer
)

// setting is one key=value row of the schema-v2 file.
type setting struct {
	key string
	val string
}

// Marker lines for the class-B gates (the seat prints each only after the
// syscall that backs it returned). MarkerSettingsWM carries the decoded
// `wm` value; a corrupt file names itself and nothing else is trusted.
const (
	MarkerSettingsWM  = "gotabwm: settings wm="
	MarkerSettingsBad = "gotabwm: settings bad"
	MarkerTokens      = "gotabwm: tokens "
)

// parseSettingsTXT decodes a schema-v2 SETTINGS.TXT body. The first line
// must be exactly `#v<digits>` with a version this seat understands (the
// kernel's gate: a malformed header or a NEWER schema is refused, not
// half-read; `#v0`/`#v1`/`#v2` all parse and migrate up); every other
// line is `key=value`, `#` comments and blank lines skipped. Bounded like
// the kernel's table: rows past the caps are dropped, the load still
// succeeds. A file that fails the header gate is corrupt: ok=false, and
// the caller fails closed.
func parseSettingsTXT(b []byte) ([]setting, bool) {
	first, rest := cutLine(string(b))
	first = strings.TrimSuffix(first, "\r")
	if !strings.HasPrefix(first, "#v") || len(first) <= 2 {
		return nil, false
	}
	digits := first[2:]
	if len(digits) > 3 {
		return nil, false // no real schema version needs more
	}
	ver := 0
	for i := 0; i < len(digits); i++ {
		c := digits[i]
		if c < '0' || c > '9' {
			return nil, false
		}
		ver = ver*10 + int(c-'0')
	}
	if ver > 2 {
		return nil, false
	}
	var out []setting
	for len(rest) > 0 {
		var line string
		line, rest = cutLine(rest)
		line = strings.TrimSpace(strings.TrimSuffix(line, "\r"))
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		key, val, hasEq := strings.Cut(line, "=")
		if !hasEq {
			continue // the kernel's parse_line refuses a row without '='
		}
		key = strings.TrimSpace(key)
		val = strings.TrimSpace(val)
		if key == "" || len(key) > settingsMaxKey || len(val) > settingsMaxVal {
			continue // the kernel's parse_line drops the row, the load stands
		}
		if len(out) >= settingsMaxKeys {
			break
		}
		out = append(out, setting{key: key, val: val})
	}
	return out, true
}

// cutLine splits s after the first newline (if any); the remainder keeps
// its newline handling for the next round.
func cutLine(s string) (line, rest string) {
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		return s[:i], s[i+1:]
	}
	return s, ""
}

// getSetting returns the last value decoded for key (the kernel's
// set-internal semantics: a later row updates the earlier one).
func getSetting(ss []setting, key string) (string, bool) {
	var val string
	found := false
	for _, s := range ss {
		if s.key == key {
			val, found = s.val, true
		}
	}
	return val, found
}

// renderSettings serializes rows in the kernel's exact byte shape: the
// `#v2` header, then one `key=value` line per row. Pinned host-side
// against the kernel serializer's output (see settings_test.go).
func renderSettings(ss []setting) []byte {
	var b strings.Builder
	b.WriteString("#v2\n")
	for _, s := range ss {
		b.WriteString(s.key)
		b.WriteString("=")
		b.WriteString(s.val)
		b.WriteString("\n")
	}
	return []byte(b.String())
}

// loadSettings reads and decodes /host/SETTINGS.TXT at seat start. Missing
// is silent (a first boot, or the pre-seed default flow); a file that
// fails the decode is corrupt-fails-closed — one marker line, then the
// seat runs on its own defaults, never a boot failure. A good decode names
// the `wm` seat the file carries (the key the boot default turns on).
func loadSettings() {
	// Read one byte past the kernel's bounded buffer: a file LARGER than
	// settingsMaxBody is refused whole (the kernel's stat gate), so the
	// seat never accepts what the kernel would refuse (M66b review).
	b, r := vi.ReadFileAll(settingsPath, settingsMaxBody+1)
	if r < 0 || b == nil {
		return
	}
	if len(b) > settingsMaxBody {
		vi.ConsoleLine(MarkerSettingsBad)
		return
	}
	ss, ok := parseSettingsTXT(b)
	if !ok {
		vi.ConsoleLine(MarkerSettingsBad)
		return
	}
	wm := "gotabwm"
	if v, found := getSetting(ss, "wm"); found {
		wm = v
	}
	if v, found := getSetting(ss, "theme"); found {
		_ = theme.Set(v)
	}
	vi.ConsoleLine(MarkerSettingsWM + wm + " keys=" + vi.Itoa64(int64(len(ss))))
}

// emitTokens prints the serial token probe go-wm-hid greps. Same shape as
// Zig `emit_tokens_marker` so a pixel/serial probe can pin one OS look.
func emitTokens() {
	t := theme.Current
	vi.ConsoleLine(MarkerTokens + "theme=" + theme.Name() +
		" bg=" + theme.Hex6(t.Bg) +
		" surface=" + theme.Hex6(t.Surface) +
		" border=" + theme.Hex6(t.Border) +
		" accent=" + theme.Hex6(t.Accent))
}
