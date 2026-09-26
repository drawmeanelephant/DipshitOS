// Package mime is M81b (issue #1762): one table that says what a file IS,
// and one registry that says which app opens it.
//
// Before this package every app re-derived a file's type from its own name
// rules, and "open this" was a decision each app made differently or not at
// all. The split here is the card's: `Sniff` is PURE (bytes in, one ID out,
// host-testable with no guest and no syscall) and the handler REGISTRY is
// data, so registering a second app for a type is a table edit rather than a
// new branch in every app.
//
// The order of trust is the card's order, and it is load-bearing:
//
//	magic bytes  ->  extension  ->  printable-text heuristic  ->  Unknown
//
// Magic beats the name on purpose: a PNG called `README.TXT` is an image,
// and an app that opened it in a text editor would be lying about the bytes.
// The extension is the fallback for the formats with no distinctive magic
// (every text format), and the heuristic is the last honest resort: bytes
// with no magic, no known extension, and no control noise are text.
//
// This is NOT a MIME database. It is the small table the in-tree apps
// actually need, and it grows by adding a row (M82a's manifest `filetypes`
// column adopts this table later — never the reverse).
package mime

import (
	"strings"
	"unicode/utf8"
)

// ID is a file type in this table. The values are internal; the String form
// is what markers, receipts and menus print, and it is part of the gate
// surface (the go-selftest `mime` receipt and the GOFILES open markers).
type ID uint8

const (
	Unknown ID = iota
	Text
	Image
	Audio
	Archive
	Binary
)

// String is the type's table name — the word markers and receipts carry.
func (id ID) String() string {
	switch id {
	case Text:
		return "text"
	case Image:
		return "image"
	case Audio:
		return "audio"
	case Archive:
		return "archive"
	case Binary:
		return "binary"
	default:
		return "unknown"
	}
}

// HeadBytes is how much of a file a caller should read before Sniff. It is
// the furthest byte any rule in the table looks at (RIFF's subtype at +8,
// four bytes, so byte 12), rounded up — a peek, not a read of the file.
const HeadBytes = 16

// magicRule matches `magic` at byte `off` of the peeked head, AND `magic2` at
// byte `off2` when magic2 is set. A zero `off`/`off2` is the common case (a
// signature at the start of the file).
//
// The second half is not decoration. Magic outranks the extension, so a rule
// has to be RIGHT or a text file that happens to start with it is dispatched
// to the wrong app: "BM" is two bytes, and prose starts with it ("BMW…").
// Requiring the rest of the signature — BMP's zero reserved fields, RIFF's
// "RIFF" before a "WAVE"/"WEBP" subtype at +8 — is what makes the rule a
// signature rather than a coincidence.
type magicRule struct {
	id     ID
	off    int
	magic  string
	off2   int
	magic2 string
}

// magic is the FIRST stage of Sniff. Order inside the table does not matter
// (no two rules can match the same bytes at the same offset).
var magic = []magicRule{
	// Images: the formats the in-tree decoders know (webrender: QOI, PNG).
	{id: Image, magic: "qoif"},
	{id: Image, magic: "\x89PNG\r\n\x1a\n"},
	{id: Image, magic: "GIF87a"},
	{id: Image, magic: "GIF89a"},
	{id: Image, magic: "\xff\xd8\xff"}, // JPEG
	// Windows bitmap: "BM" alone is two bytes of prose, so the rule also
	// requires the two reserved u16 fields to be zero (bitmap_core.h), which
	// every writer leaves that way. Six bytes of evidence, not two.
	{id: Image, magic: "BM", off2: 6, magic2: "\x00\x00\x00\x00"},
	// The RIFF container: "RIFF" at 0 and the form type at +8. Matching the
	// subtype alone would call any file with the word WAVE at byte 8 a sound.
	{id: Image, magic: "RIFF", off2: 8, magic2: "WEBP"},

	// Audio: enough to tell a sound file from an image of the same name.
	{id: Audio, magic: "RIFF", off2: 8, magic2: "WAVE"},
	{id: Audio, magic: "OggS"},
	{id: Audio, magic: "fLaC"},
	{id: Audio, magic: "ID3"},

	// Archives.
	{id: Archive, magic: "PK\x03\x04"}, // zip
	{id: Archive, magic: "\x1f\x8b"},   // gzip

	// Guest/native binaries: the files that are certainly not text.
	{id: Binary, magic: "\x7fELF"},
}

// exts maps a lower-case extension (no dot) to its type. This is the
// fallback stage, and it is where most of the table's rows live because text
// formats have no magic at all.
var exts = map[string]ID{
	// text
	"txt": Text, "text": Text, "md": Text, "markdown": Text, "log": Text,
	"csv": Text, "json": Text, "toml": Text, "ini": Text, "cfg": Text,
	"conf": Text, "yaml": Text, "yml": Text, "sh": Text, "go": Text,
	"zig": Text, "c": Text, "h": Text, "py": Text, "rs": Text,
	// image
	"qoi": Image, "png": Image, "jpg": Image, "jpeg": Image, "gif": Image,
	"bmp": Image, "webp": Image,
	// audio
	"wav": Audio, "mp3": Audio, "ogg": Audio, "flac": Audio,
	// archive
	"zip": Archive, "gz": Archive, "tgz": Archive,
	// binary
	"elf": Binary, "bin": Binary, "exe": Binary, "img": Binary,
}

// Sniff is the whole decision: what is this file, given its name and the
// first HeadBytes of it. Pure — no syscall, no globals, no I/O.
func Sniff(name string, head []byte) ID {
	if id, ok := byMagic(head); ok {
		return id
	}
	if id, ok := byExt(name); ok {
		return id
	}
	if looksText(head) {
		return Text
	}
	return Unknown
}

func byMagic(head []byte) (ID, bool) {
	for _, r := range magic {
		if !at(head, r.off, r.magic) {
			continue
		}
		if r.magic2 != "" && !at(head, r.off2, r.magic2) {
			continue
		}
		return r.id, true
	}
	return Unknown, false
}

// at reports whether the bytes at off are exactly want. A rule that would read
// past the peek simply does not match: an unreadable tail is not evidence.
func at(head []byte, off int, want string) bool {
	if off < 0 || len(head) < off+len(want) {
		return false
	}
	return string(head[off:off+len(want)]) == want
}

// byExt resolves the extension case-insensitively. A name with no dot, or a
// leading dot only (".bashrc"), has no extension.
func byExt(name string) (ID, bool) {
	i := strings.LastIndexByte(name, '.')
	if i <= 0 || i == len(name)-1 {
		return Unknown, false
	}
	id, ok := exts[strings.ToLower(name[i+1:])]
	return id, ok
}

// looksText is the last honest resort: no magic, no known extension, and the
// bytes carry no control noise. Valid UTF-8 counts as text (a NOTES.TXT with
// an em dash is still text); a NUL byte never does.
//
// The trailing-rune trim is the part that matters at HeadBytes = 16. The peek
// is a byte count, not a character count, so a multi-byte character can
// straddle the cut: 15 ASCII bytes then a 2-byte em dash leaves half a rune,
// and utf8.Valid calls that invalid — an extensionless UTF-8 note would be
// refused as unknown. A truncated TAIL is an artifact of the peek; only
// invalid bytes anywhere else are a fact about the file.
func looksText(head []byte) bool {
	if len(head) == 0 {
		return false
	}
	for _, b := range head {
		switch {
		case b >= 0x20 && b <= 0x7e:
		case b == '\t' || b == '\n' || b == '\r':
		case b >= 0x80: // decided by the UTF-8 check below
		default:
			return false
		}
	}
	if n := trimPartialRune(head); n < len(head) {
		head = head[:n]
		if len(head) == 0 {
			return false // nothing but a severed rune: not text we can claim
		}
	}
	return utf8.Valid(head)
}

// trimPartialRune returns the length of head with an incomplete trailing
// multi-byte sequence removed, or len(head) when the tail is already whole.
// A UTF-8 lead byte is 11xxxxxx; the sequence is 2, 3 or 4 bytes long, so at
// most the last 3 bytes need looking at. Bytes that are all continuations
// have no lead to find — utf8.Valid rejects them, which is the right answer.
func trimPartialRune(head []byte) int {
	for back := 1; back <= 3 && back <= len(head); back++ {
		b := head[len(head)-back]
		if b < 0x80 || b >= 0xc0 {
			// b is a lead byte (or ASCII): does its sequence fit?
			var want int
			switch {
			case b >= 0xf0:
				want = 4
			case b >= 0xe0:
				want = 3
			case b >= 0xc0:
				want = 2
			default:
				return len(head) // plain ASCII tail
			}
			if back < want {
				return len(head) - back // severed: drop it
			}
			return len(head)
		}
	}
	return len(head)
}

// Handler is one app that can open a type: the binary to exec and the label a
// menu shows for it.
type Handler struct {
	ID    ID
	Bin   string
	Label string
}

// registry is the handler table, in registration order. It is package state
// rather than a constant so an app (or a test) can add a handler without
// editing this file; the guest's registrations all happen in init.
var registry []Handler

// Register adds a handler for a type. The FIRST registration for a type is
// the default one Open dispatches to; later ones are the "Open with…"
// candidates. Re-registering the same binary for a type is a no-op, so an
// app's init cannot double itself into the list.
func Register(id ID, bin, label string) {
	if bin == "" {
		return
	}
	for _, h := range registry {
		if h.ID == id && h.Bin == bin {
			return
		}
	}
	registry = append(registry, Handler{ID: id, Bin: bin, Label: label})
}

// Handlers is the candidate list for a type, in registration order. The
// result is a copy: a caller cannot reorder the table by accident.
func Handlers(id ID) []Handler {
	var out []Handler
	for _, h := range registry {
		if h.ID == id {
			out = append(out, h)
		}
	}
	return out
}

// Default is the handler Open dispatches to — the first registration for the
// type. The bool is false for a type nothing has registered (the caller owes
// the user a named refusal, not a silent no-op).
func Default(id ID) (Handler, bool) {
	for _, h := range registry {
		if h.ID == id {
			return h, true
		}
	}
	return Handler{}, false
}

// init registers the two live adopters (the card's day-one requirement):
// GOVIEW.ELF opens images and takes a path in argv[1]; GOEDIT.ELF opens text
// and takes a path in argv[1] as well. GOEDIT is ALSO an image handler,
// second, because GOVIEW refuses images it has no decoder for ("this format
// has no guest decoder") and reading the raw bytes is the honest fallback
// then. A type with no registration is Audio (nothing in the tree plays
// sound yet), Archive and Binary — those refuse by name.
func init() {
	Register(Image, "GOVIEW.ELF", "Image Viewer")
	Register(Text, "GOEDIT.ELF", "Code Editor")
	Register(Image, "GOEDIT.ELF", "Code Editor (raw bytes)")
}
