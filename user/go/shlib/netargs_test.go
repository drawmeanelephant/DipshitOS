package shlib

import "testing"

func TestParseNetArgs(t *testing.T) {
	na, ok, err := ParseNetArgs([]string{"GOSH.ELF", "net"})
	if !ok || err != "" || na.Port != 2323 || na.Open {
		t.Fatalf("bare net = %+v ok=%v err=%q", na, ok, err)
	}
	na, ok, err = ParseNetArgs([]string{"GOSH.ELF", "net", "4444", "open"})
	if !ok || err != "" || na.Port != 4444 || !na.Open {
		t.Fatalf("net 4444 open = %+v ok=%v err=%q", na, ok, err)
	}
	na, ok, err = ParseNetArgs([]string{"GOSH.ELF", "net", "4444"})
	if !ok || err != "" || na.Port != 4444 || na.Open {
		t.Fatalf("net 4444 = %+v ok=%v err=%q", na, ok, err)
	}
	_, ok, err = ParseNetArgs([]string{"GOSH.ELF", "serial"})
	if ok || err != "" {
		t.Fatalf("serial is not net: ok=%v err=%q", ok, err)
	}
	_, ok, err = ParseNetArgs([]string{"GOSH.ELF", "net", "4444", "secret"})
	if ok || err == "" {
		t.Fatalf("unknown mode must refuse: ok=%v err=%q", ok, err)
	}
	_, ok, err = ParseNetArgs([]string{"GOSH.ELF", "net", "99999"})
	if ok || err == "" {
		t.Fatalf("bad port must refuse: ok=%v err=%q", ok, err)
	}
	// argv[0] omitted: the verb itself is the first word.
	na, ok, err = ParseNetArgs([]string{"net", "2323", "open"})
	if !ok || err != "" || na.Port != 2323 || !na.Open {
		t.Fatalf("verb-first = %+v ok=%v err=%q", na, ok, err)
	}
}
