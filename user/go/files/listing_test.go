package main

import (
	"testing"

	"virelai/vi"
)

func TestJoinPath(t *testing.T) {
	got, ok := joinPath("/host", "FM")
	if !ok || got != "/host/FM" {
		t.Fatalf("join /host+FM = %q ok=%v", got, ok)
	}
	got, ok = joinPath("/host/FM", "KNOWN.TXT")
	if !ok || got != "/host/FM/KNOWN.TXT" {
		t.Fatalf("join nested = %q ok=%v", got, ok)
	}
	if _, ok := joinPath("/host", ".."); ok {
		t.Fatal("join must refuse ..")
	}
	if _, ok := joinPath("/host", "a/b"); ok {
		t.Fatal("join must refuse a slash in the name")
	}
	long := make([]byte, maxPath)
	for i := range long {
		long[i] = 'A'
	}
	if _, ok := joinPath("/host", string(long)); ok {
		t.Fatal("join must refuse a path over the kernel cap")
	}
}

func TestParentPath(t *testing.T) {
	if got := parentPath("/host/FM/KNOWN.TXT"); got != "/host/FM" {
		t.Fatalf("parent file = %q", got)
	}
	if got := parentPath("/host/FM"); got != "/host" {
		t.Fatalf("parent dir = %q", got)
	}
	if got := parentPath("/host"); got != "/host" {
		t.Fatalf("parent root = %q", got)
	}
	if got := parentPath(""); got != "/host" {
		t.Fatalf("parent empty = %q", got)
	}
}

func TestContainsAndLabels(t *testing.T) {
	var entries [2]vi.DirEntry
	copy(entries[0].Name[:], "FM")
	entries[0].IsDir = 1
	copy(entries[1].Name[:], knownName)
	if !containsName(entries[:], 2, knownName) {
		t.Fatal("KNOWN.TXT should be found")
	}
	if containsName(entries[:], 1, knownName) {
		t.Fatal("n=1 must not see the second row")
	}
	labs := labelsOf(entries[:], 2)
	if len(labs) != 2 || labs[0] != "FM/" || labs[1] != knownName {
		t.Fatalf("labels = %#v", labs)
	}
}

func TestMarkerShapes(t *testing.T) {
	cases := []struct{ got, want string }{
		{markerOpen, "gofiles: open id="},
		{markerDeclare, "gofiles: declare accepted"},
		{markerList, "gofiles: list "},
		{markerEntry, "gofiles: entry "},
		{markerFound, "gofiles: found KNOWN.TXT"},
		{markerView, "gofiles: view "},
		{markerPresent, "gofiles: present"},
		{markerClose, "gofiles: close"},
		{markerOK, "gofiles OK"},
	}
	for _, c := range cases {
		if c.got != c.want {
			t.Fatalf("marker = %q want %q", c.got, c.want)
		}
	}
}
