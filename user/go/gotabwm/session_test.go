package main

import (
	"testing"

	"virelai/vi"
)

func TestRestoreSessionBranchesAndFirstBootWorkspace(t *testing.T) {
	seed := TabStrip{}
	if !seed.OpenTab(0x41, "Sh") {
		t.Fatal("OpenTab")
	}
	raw, ok := seed.encodeTabsV2(7)
	if !ok {
		t.Fatal("encodeTabsV2")
	}

	t.Run("missing", func(t *testing.T) {
		var strip TabStrip
		_, state := restoreSessionBytes(&strip, nil, -1)
		if state != sessionMissing || strip.Count() != 0 {
			t.Fatalf("missing state=%d count=%d", state, strip.Count())
		}
		if !firstBootWorkspace(state, "gotabwm") {
			t.Fatal("missing session on the default seat must open the starter workspace")
		}
		if firstBootWorkspace(state, "none") || firstBootWorkspace(state, "tabwm") {
			t.Fatal("a non-default seat setting must not start a GOTABWM workspace")
		}
	})

	t.Run("corrupt", func(t *testing.T) {
		var strip TabStrip
		_, state := restoreSessionBytes(&strip, []byte("truncated"), 9)
		if state != sessionCorrupt || strip.Count() != 0 {
			t.Fatalf("corrupt state=%d count=%d", state, strip.Count())
		}
		if firstBootWorkspace(state, "gotabwm") {
			t.Fatal("corrupt session must not fabricate a starter tab")
		}
	})

	t.Run("present", func(t *testing.T) {
		var strip TabStrip
		seq, state := restoreSessionBytes(&strip, raw, int64(len(raw)))
		if state != sessionRestored || seq != 7 || strip.Count() != 1 {
			t.Fatalf("present state=%d seq=%d count=%d", state, seq, strip.Count())
		}
		if strip.At(0).Title != "Sh" || strip.At(0).ID != sessionIDBase {
			t.Fatalf("restored tab = %+v", strip.At(0))
		}
		if firstBootWorkspace(state, "gotabwm") {
			t.Fatal("present session must restore without adding a starter tab")
		}
	})
}

func TestHasLiveGuestELF(t *testing.T) {
	row := func(state uint64, name string) vi.ProcRow {
		r := vi.ProcRow{State: state}
		copy(r.NameBuf[:], name)
		return r
	}
	for _, tc := range []struct {
		name string
		rows []vi.ProcRow
		want bool
	}{
		{name: "no other program", rows: []vi.ProcRow{row(vi.ProcRunning, "GOTABWM.ELF")}},
		{name: "running client", rows: []vi.ProcRow{row(vi.ProcRunning, "GOSH.ELF")}, want: true},
		{name: "created client", rows: []vi.ProcRow{row(vi.ProcCreated, "GOCALC.ELF")}, want: true},
		{name: "exited client", rows: []vi.ProcRow{row(vi.ProcExited, "GOSH.ELF")}},
		{name: "non ELF", rows: []vi.ProcRow{row(vi.ProcRunning, "monitor")}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := hasLiveGuestELF(tc.rows); got != tc.want {
				t.Fatalf("hasLiveGuestELF = %v want %v", got, tc.want)
			}
		})
	}
}
