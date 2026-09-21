// Package settings is the schema-v2 SETTINGS.TXT codec, shared by the Go seat
// (GOTABWM.ELF) and the Go settings panel (GOSET.ELF).
//
// M66b (#1444) wrote this decode inside the seat, as the corrupt-fails-closed
// twin of the kernel's own loader (kernel/src/settings.zig): the same key=value
// grammar, the same `#v<digits>` header gate, the same verdict on a bad file.
// M71f (#1565) moves it here — one codec, two consumers — because the panel has
// to read and WRITE the same file the seat decoded. The seat keeps its
// seat-level markers (gotabwm: settings wm= / settings bad); the panel owns the
// user-facing edit and publishes crash-safe through vi.WriteFileSafe (temp +
// fsync + delete/rename), the same publish the kernel's `settings set` uses, so
// a panel save can never leave a partial file behind.
//
// KnownKeys mirrors the kernel's compiled table (kernel/src/settings.zig). It is
// a MIRROR, not a second schema: the panel offers exactly the keys the kernel
// already knows (card D1) and writes only those. The mirror is pinned against
// the kernel source by a host test, so a key added there and not here is a
// failing test rather than a silent drift.
package settings

import (
	"strings"

	"virelai/vi"
)

const (
	// Path is the file both consumers read. The kernel owns writing it; the
	// panel writes it too, through the same crash-safe publish.
	Path = "/host/SETTINGS.TXT"
	// Caps mirror the kernel's table (max_entries / max_key_len / max_val_len)
	// and its bounded load buffer.
	MaxKeys = 16
	MaxKey  = 32
	MaxVal  = 64
	MaxBody = 2048

	// SaveRefused is Save's return when the decode was corrupt: no file was
	// written. It is a package-local sentinel, not a kernel errno.
	SaveRefused int64 = -4097
)

// State is the decode verdict for the file.
const (
	// StateMissing is a first boot, or the pre-seed default flow. The compiled
	// defaults are in force; saving is allowed (that is how a fresh share gets
	// a settings file at all).
	StateMissing = iota
	// StateOK is a schema-v2 file this package understands.
	StateOK
	// StateCorrupt is a file the kernel refused whole (no valid header, a newer
	// schema, or an oversized body). Every write is refused: a corrupt file is
	// never laundered into a half-parsed one.
	StateCorrupt
)

// Setting is one key=value row of the schema-v2 file.
type Setting struct {
	Key string
	Val string
}

// File is a decoded settings file plus its verdict.
type File struct {
	Rows  []Setting
	State int
}

// Key is one row of the kernel's compiled table: the value in force when the
// file carries no such key, and the vocabulary the panel may cycle through
// (nil = free text, the kernel's own value space is open for that key).
type Key struct {
	Name    string
	Default string
	Vocab   []string
}

// KnownKeys mirrors kernel/src/settings.zig init(): the eight keys the kernel
// seeds before it loads the file. Order is the kernel's, so a diff against the
// kernel source reads straight down.
var KnownKeys = []Key{
	{Name: "hostname", Default: "virelai"},
	{Name: "prompt", Default: "virelai> "},
	{Name: "theme", Default: "dark", Vocab: []string{"dark", "light"}},
	{Name: "scrollback", Default: "1000"},
	{Name: "shadow", Default: "off", Vocab: []string{"on", "off"}},
	{Name: "focus_follows_mouse", Default: "off", Vocab: []string{"on", "off"}},
	{Name: "shell", Default: "monitor", Vocab: []string{"monitor", "sh"}},
	{Name: "wm", Default: "gotabwm", Vocab: []string{"gotabwm", "tabwm", "none"}},
}

// Known reports the kernel-table row for key.
func Known(key string) (Key, bool) {
	for _, k := range KnownKeys {
		if k.Name == key {
			return k, true
		}
	}
	return Key{}, false
}

// Default returns the value in force for key when the file carries no such
// key: the kernel's compiled default, or "".found=false for an unknown key.
func Default(key string) (string, bool) {
	if k, ok := Known(key); ok {
		return k.Default, true
	}
	return "", false
}

// Vocab returns the values the panel may cycle key through, and whether key is
// a known key at all. A known key with no vocabulary is free text.
func Vocab(key string) ([]string, bool) {
	k, ok := Known(key)
	if !ok {
		return nil, false
	}
	return k.Vocab, true
}

// Next returns the vocabulary value after cur, wrapping; a cur outside the
// vocabulary (a value the kernel would ignore) starts the cycle at the top.
func Next(vocab []string, cur string) string {
	if len(vocab) == 0 {
		return cur
	}
	for i, v := range vocab {
		if v == cur {
			return vocab[(i+1)%len(vocab)]
		}
	}
	return vocab[0]
}

// Parse decodes a schema-v2 SETTINGS.TXT body. The first line must be exactly
// `#v<digits>` with a version this consumer understands (the kernel's gate: a
// malformed header or a NEWER schema is refused, not half-read; `#v0`/`#v1`/
// `#v2` all parse and migrate up); every other line is `key=value`, `#`
// comments and blank lines skipped. Bounded like the kernel's table: rows past
// the caps are dropped, the load still succeeds. A file that fails the header
// gate is corrupt: ok=false, and the caller fails closed.
func Parse(b []byte) ([]Setting, bool) {
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
	var out []Setting
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
		if key == "" || len(key) > MaxKey || len(val) > MaxVal {
			continue // the kernel's parse_line drops the row, the load stands
		}
		if len(out) >= MaxKeys {
			break
		}
		out = append(out, Setting{Key: key, Val: val})
	}
	return out, true
}

// Render serializes rows in the kernel's exact byte shape: the `#v2` header,
// then one `key=value` line per row. Pinned host-side against the kernel
// serializer's output (see settings_test.go).
func Render(ss []Setting) []byte {
	var b strings.Builder
	b.WriteString("#v2\n")
	for _, s := range ss {
		b.WriteString(s.Key)
		b.WriteString("=")
		b.WriteString(s.Val)
		b.WriteString("\n")
	}
	return []byte(b.String())
}

// Get returns the last value decoded for key (the kernel's set-internal
// semantics: a later row updates the earlier one).
func Get(ss []Setting, key string) (string, bool) {
	var val string
	found := false
	for _, s := range ss {
		if s.Key == key {
			val, found = s.Val, true
		}
	}
	return val, found
}

// Set updates the last row for key in place, or appends one when the file
// carries no such row. The kernel's own set is the same shape: a later row
// wins, and a new key lands at the end of the table.
func Set(ss []Setting, key, val string) []Setting {
	for i := len(ss) - 1; i >= 0; i-- {
		if ss[i].Key == key {
			ss[i].Val = val
			return ss
		}
	}
	return append(ss, Setting{Key: key, Val: val})
}

// Effective returns the value the seat will honor for key: the file's value
// when the file carries one, else the kernel's compiled default. found=false
// for an unknown key with no row.
func (f File) Effective(key string) (string, bool) {
	if v, ok := Get(f.Rows, key); ok {
		return v, true
	}
	return Default(key)
}

// Display returns the rows the panel shows: the decoded rows, plus one row per
// KNOWN key the file does not carry, holding the value actually in force. The
// edit surface is therefore exactly what the seat honors — a key absent from
// the file is still visible and still settable. Unknown keys present in the
// file are preserved untouched (see Set key), never offered for editing.
func (f File) Display() []Setting {
	out := make([]Setting, 0, len(f.Rows)+len(KnownKeys))
	out = append(out, f.Rows...)
	for _, k := range KnownKeys {
		if _, ok := Get(f.Rows, k.Name); !ok {
			out = append(out, Setting{Key: k.Name, Val: k.Default})
		}
	}
	return out
}

// Load reads and decodes Path. A missing file is StateMissing (the compiled
// defaults are in force); a file that fails the decode is StateCorrupt and
// nothing in it is trusted — the same verdict the kernel and the seat reach.
func Load() File {
	// Read one byte past the kernel's bounded buffer: a file LARGER than
	// MaxBody is refused whole (the kernel's stat gate), so neither consumer
	// accepts what the kernel would refuse (M66b review).
	b, r := vi.ReadFileAll(Path, MaxBody+1)
	if r < 0 || b == nil {
		return File{State: StateMissing}
	}
	if len(b) > MaxBody {
		return File{State: StateCorrupt}
	}
	rows, ok := Parse(b)
	if !ok {
		return File{State: StateCorrupt}
	}
	return File{Rows: rows, State: StateOK}
}

// Save publishes the file's rows crash-safe (vi.WriteFileSafe: temp + fsync +
// delete/rename). It REFUSES a corrupt decode — a panel must never launder a
// file the kernel refused — returning SaveRefused. Any other negative return is
// the kernel code of the step that failed; every failure removes the temp, so
// the target is either the old bytes, the new bytes, or absent (defaults).
func (f File) Save() int64 {
	if f.State == StateCorrupt {
		return SaveRefused
	}
	return vi.WriteFileSafe(Path, Render(f.Rows))
}

// cutLine splits s after the first newline (if any); the remainder keeps its
// newline handling for the next round.
func cutLine(s string) (line, rest string) {
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		return s[:i], s[i+1:]
	}
	return s, ""
}
