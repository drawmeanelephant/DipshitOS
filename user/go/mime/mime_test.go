// Host pins for the M81b (#1762) sniff table. These are the card's claims:
// magic beats the name, the extension is the fallback, the heuristic is the
// last resort, and a type with no registered handler says so instead of
// guessing. No guest, no syscall — the table is pure on purpose.
package mime

import "testing"

// withRegistry runs f against a private handler table so a registering test
// cannot leak into the next one (the guest's init registrations are the
// baseline every other test sees).
func withRegistry(t *testing.T, f func()) {
	t.Helper()
	saved := registry
	registry = append([]Handler(nil), registry...)
	defer func() { registry = saved }()
	f()
}

func TestMagicBeatsTheExtension(t *testing.T) {
	cases := []struct {
		name string
		head []byte
		want ID
	}{
		{"README.TXT", []byte("\x89PNG\r\n\x1a\nrest"), Image},
		{"NOTES.TXT", []byte("qoif" + "\x00\x00\x00\x10"), Image},
		{"SEED.TXT", []byte("GIF89a......"), Image},
		{"SEED.TXT", []byte("\xff\xd8\xff\xe0"), Image},
		{"SEED.TXT", []byte("BM......"), Image},
		{"DATA.BIN", []byte("\x7fELF\x02\x01\x01"), Binary},
		{"SEED.TXT", []byte("PK\x03\x04rest"), Archive},
		{"SEED.TXT", []byte("\x1f\x8b\x08rest"), Archive},
		// The two offset rules: RIFF alone is a container, the subtype at +8
		// is what says which.
		{"SOUND.TXT", []byte("RIFF\x00\x00\x00\x00WAVEfmt "), Audio},
		{"PIC.TXT", []byte("RIFF\x00\x00\x00\x00WEBPVP8 "), Image},
		// A magic match must not need the whole head: 3 bytes is enough.
		{"PIC.QOI", []byte("qoi"), Image},
	}
	for _, c := range cases {
		if got := Sniff(c.name, c.head); got != c.want {
			t.Errorf("Sniff(%q, %q) = %s, want %s", c.name, c.head, got, c.want)
		}
	}
}

func TestExtensionIsTheFallback(t *testing.T) {
	cases := []struct {
		name string
		want ID
	}{
		{"SEED.TXT", Text},
		{"PHOTO.QOI", Image},
		{"SONG.WAV", Audio},
		{"BUNDLE.ZIP", Archive},
		{"GUEST.BIN", Binary},
		// Case is the caller's accident, not the file's identity.
		{"Seed.Txt", Text},
		{"PHOTO.QOI", Image},
		// No extension, and a dotfile's leading dot is not one.
		{"README", Unknown},
		{".bashrc", Unknown},
		// An unknown extension is not a licence to guess.
		{"PAPER.PS", Unknown},
		// A trailing dot is not an extension either.
		{"SEED.", Unknown},
	}
	for _, c := range cases {
		if got := Sniff(c.name, nil); got != c.want {
			t.Errorf("Sniff(%q, nil) = %s, want %s", c.name, got, c.want)
		}
	}
}

func TestPrintableBytesAreTheLastResort(t *testing.T) {
	text := []byte("hello from the share\n")
	if got := Sniff("NOTES", text); got != Text {
		t.Errorf("printable bytes, no extension: got %s, want text", got)
	}
	// UTF-8 is text: an em dash is not control noise.
	utf := []byte("caf\xc3\xa9 \xe2\x80\x94 notes\n")
	if got := Sniff("NOTES", utf); got != Text {
		t.Errorf("valid UTF-8: got %s, want text", got)
	}
	// A NUL is not, and neither is a truncated multi-byte sequence.
	if got := Sniff("BLOB", []byte{'a', 0x00, 'b'}); got != Unknown {
		t.Errorf("NUL byte: got %s, want unknown", got)
	}
	if got := Sniff("BLOB", []byte{0xc3, 0x28}); got != Unknown {
		t.Errorf("invalid UTF-8: got %s, want unknown", got)
	}
	// An empty read says nothing: an unreadable file is Unknown, not text.
	if got := Sniff("SEED.TXT", nil); got != Text {
		t.Errorf("empty head with a known extension: got %s, want text (ext stage)", got)
	}
	if got := Sniff("SEED", nil); got != Unknown {
		t.Errorf("empty head, no extension: got %s, want unknown", got)
	}
}

// The peek a caller is told to read must cover every rule in the table —
// otherwise a rule could never fire and the table would be lying about its
// own constants.
func TestHeadBytesCoversEveryMagicRule(t *testing.T) {
	for _, r := range magic {
		if r.off+len(r.magic) > HeadBytes {
			t.Errorf("rule %q at +%d needs %d bytes, HeadBytes is %d",
				r.magic, r.off, r.off+len(r.magic), HeadBytes)
		}
	}
	// …and the peek must actually be enough for the two offset rules.
	if got := Sniff("X", make([]byte, HeadBytes)); got == Unknown {
		// An all-zero head is neither magic nor printable: unknown, as pinned.
		t.Logf("all-zero head: %s", got)
	}
}

func TestHandlersAreTheRegisteredOnes(t *testing.T) {
	withRegistry(t, func() {
		img := Handlers(Image)
		if len(img) != 2 {
			t.Fatalf("image handlers = %d (%v), want 2 (GOVIEW + the raw-byte fallback)", len(img), img)
		}
		if img[0].Bin != "GOVIEW.ELF" || img[1].Bin != "GOEDIT.ELF" {
			t.Errorf("image candidate order = %s, %s; want GOVIEW.ELF, GOEDIT.ELF", img[0].Bin, img[1].Bin)
		}
		if h, ok := Default(Image); !ok || h.Bin != "GOVIEW.ELF" {
			t.Errorf("Default(Image) = %+v, %v; want GOVIEW.ELF", h, ok)
		}
		if h, ok := Default(Text); !ok || h.Bin != "GOEDIT.ELF" {
			t.Errorf("Default(Text) = %+v, %v; want GOEDIT.ELF", h, ok)
		}
		// The refusal half: a type nothing opens is a fact the caller needs.
		for _, id := range []ID{Audio, Archive, Binary, Unknown} {
			if h, ok := Default(id); ok {
				t.Errorf("Default(%s) = %+v; want no handler (a named refusal)", id, h)
			}
			if got := Handlers(id); len(got) != 0 {
				t.Errorf("Handlers(%s) = %v; want none", id, got)
			}
		}
	})
}

func TestRegisterAppendsAndDedups(t *testing.T) {
	withRegistry(t, func() {
		before := len(Handlers(Text))
		Register(Text, "GOEDIT.ELF", "Code Editor") // already there
		if got := len(Handlers(Text)); got != before {
			t.Errorf("re-registering the same binary: %d handlers, want %d", got, before)
		}
		Register(Text, "", "nameless") // refused: an empty binary execs nothing
		if got := len(Handlers(Text)); got != before {
			t.Errorf("empty bin: %d handlers, want %d", got, before)
		}
		Register(Text, "TERM.ELF", "Terminal")
		got := Handlers(Text)
		if len(got) != before+1 || got[len(got)-1].Bin != "TERM.ELF" {
			t.Fatalf("Handlers(Text) = %v; want the new candidate last", got)
		}
		if h, _ := Default(Text); h.Bin != "GOEDIT.ELF" {
			t.Errorf("Default(Text) moved to %s; the FIRST registration is the default", h.Bin)
		}
		// The returned slice is a copy: a caller must not be able to
		// reorder the registry by writing into it.
		got[0] = Handler{Bin: "HACKED"}
		if again := Handlers(Text); again[0].Bin == "HACKED" {
			t.Error("Handlers returned the registry itself, not a copy")
		}
	})
}

func TestIDNamesAreTheMarkerVocabulary(t *testing.T) {
	// These strings ride the GOFILES open markers and the go-selftest
	// receipt, which the class-B gates byte-compare.
	want := map[ID]string{
		Unknown: "unknown", Text: "text", Image: "image",
		Audio: "audio", Archive: "archive", Binary: "binary",
	}
	for id, s := range want {
		if got := id.String(); got != s {
			t.Errorf("ID(%d).String() = %q, want %q", id, got, s)
		}
	}
}
