//go:build virelai || pulse

package main

import (
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"
)

func testModel() model {
	return newModel(func(pid uint64) int64 { return 0 }, takeSnapshot)
}

func press(m model, text string) model {
	next, _ := m.Update(tea.KeyPressMsg(tea.Key{Text: text}))
	return next.(model)
}

func TestTabsSwitchFromTeaKeyPress(t *testing.T) {
	m := testModel()
	for key, want := range map[string]tab{"1": tabOverview, "2": tabProcs, "3": tabNet, "4": tabStorage} {
		got := press(m, key)
		if got.tab != want {
			t.Fatalf("key %q: tab = %v, want %v", key, got.tab, want)
		}
	}
}

func TestSelectionMovesWithJK(t *testing.T) {
	m := press(testModel(), "2")
	if m.sel != 0 {
		t.Fatalf("initial sel = %d, want 0", m.sel)
	}
	m = press(m, "j")
	if m.sel != 1 {
		t.Fatalf("after j: sel = %d, want 1", m.sel)
	}
	m = press(m, "k")
	if m.sel != 0 {
		t.Fatalf("after k: sel = %d, want 0", m.sel)
	}
	// k at the top clamps, j at the bottom clamps.
	m = press(m, "k")
	if m.sel != 0 {
		t.Fatalf("k at top: sel = %d, want 0", m.sel)
	}
	for i := 0; i < 10; i++ {
		m = press(m, "j")
	}
	if want := len(visibleProcs(m.snap, m.sortCol, m.filter)) - 1; m.sel != want {
		t.Fatalf("j at bottom: sel = %d, want %d", m.sel, want)
	}
}

func TestSortCyclesWithS(t *testing.T) {
	m := press(testModel(), "2")
	if m.sortCol != sortPID {
		t.Fatalf("initial sort = %v, want pid", m.sortCol)
	}
	m = press(m, "s")
	if m.sortCol != sortName {
		t.Fatalf("after s: sort = %v, want name", m.sortCol)
	}
	m = press(m, "s")
	if m.sortCol != sortState {
		t.Fatalf("after s s: sort = %v, want state", m.sortCol)
	}
}

func TestFilterNarrowsTable(t *testing.T) {
	m := press(testModel(), "2")
	m = press(m, "/")
	if !m.filtering {
		t.Fatal("/ did not enter filter mode")
	}
	for _, c := range []string{"n", "o", "t", "e"} {
		m = press(m, c)
	}
	if m.filter != "note" {
		t.Fatalf("filter = %q, want %q", m.filter, "note")
	}
	rows := visibleProcs(m.snap, m.sortCol, m.filter)
	if len(rows) != 1 || rows[0].name != "NOTE.ELF" {
		t.Fatalf("filtered rows = %+v, want only NOTE.ELF", rows)
	}
	m = press(m, "\n") // return leaves filter mode
	if m.filtering {
		t.Fatal("return did not leave filter mode")
	}
	if m.filter != "note" {
		t.Fatalf("filter after return = %q, want it kept", m.filter)
	}
}

func TestKillConfirmsThenArms(t *testing.T) {
	var killed uint64
	armed := false
	m := newModel(func(pid uint64) int64 {
		killed, armed = pid, true
		return 0
	}, takeSnapshot)
	m = press(m, "2")
	m = press(m, "x")
	if !m.confirm {
		t.Fatal("x did not open the kill dialog")
	}
	// The first row by pid is GOTABWM.ELF pid 1 in the host stub.
	m = press(m, "y")
	if m.confirm {
		t.Fatal("y did not close the kill dialog")
	}
	if !armed || killed != 1 {
		t.Fatalf("kill called with pid=%d armed=%v, want pid=1 armed=true", killed, armed)
	}
	if !strings.Contains(m.notice, "kill armed") || !strings.Contains(m.notice, "exit 137") {
		t.Fatalf("notice = %q, want the armed/exit-137 report", m.notice)
	}
}

func TestKillCancelKeepsProcess(t *testing.T) {
	armed := false
	m := newModel(func(pid uint64) int64 { armed = true; return 0 }, takeSnapshot)
	m = press(press(m, "2"), "x")
	m = press(m, "n")
	if armed {
		t.Fatal("n armed the kill anyway")
	}
	if m.confirm {
		t.Fatal("n did not close the kill dialog")
	}
}

func TestKillRefusalIsReported(t *testing.T) {
	m := newModel(func(pid uint64) int64 { return -1 }, takeSnapshot)
	m = press(press(m, "2"), "x")
	m = press(m, "y")
	if !strings.Contains(m.notice, "refused") || !strings.Contains(m.notice, "EINVAL") {
		t.Fatalf("notice = %q, want the honest EINVAL refusal", m.notice)
	}
}

func TestHelpOverlayToggles(t *testing.T) {
	m := press(testModel(), "?")
	if !m.help {
		t.Fatal("? did not open help")
	}
	if !strings.Contains(m.View().Content, "switch tab") {
		t.Fatal("help view missing the key list")
	}
	m = press(m, "?")
	if m.help {
		t.Fatal("second ? did not close help")
	}
}

func TestModelQuitsFromTeaKeyPress(t *testing.T) {
	if m := press(testModel(), "q"); !m.quit {
		t.Fatal("q did not request model shutdown")
	}
}

func TestRefreshKeyTakesSnapshot(t *testing.T) {
	calls := 0
	m := newModel(func(pid uint64) int64 { return 0 }, func() snapshot {
		calls++
		return takeSnapshot()
	})
	before := calls // newModel refreshes once
	m = press(m, "r")
	if calls != before+1 {
		t.Fatalf("r took %d snapshots, want one more than %d", calls, before)
	}
}

func TestViewCarriesTabsAndTitle(t *testing.T) {
	view := testModel().View().Content
	for _, want := range []string{"PULSE.ELF", "1:Overview", "2:Processes", "3:Network", "4:Storage"} {
		if !strings.Contains(view, want) {
			t.Fatalf("view missing %q", want)
		}
	}
}

func TestViewShowsProcessRows(t *testing.T) {
	m := press(testModel(), "2")
	view := m.View().Content
	for _, want := range []string{"GOTABWM.ELF", "PULSE.ELF", "running", "PID*"} {
		if !strings.Contains(view, want) {
			t.Fatalf("processes view missing %q", want)
		}
	}
}

func TestViewShowsOverviewNumbers(t *testing.T) {
	view := testModel().View().Content // overview is the default tab
	for _, want := range []string{"1h 23m 45s", "2 running", "1 created", "1 exited"} {
		if !strings.Contains(view, want) {
			t.Fatalf("overview view missing %q", want)
		}
	}
}

func TestViewShowsStorageFree(t *testing.T) {
	m := press(testModel(), "4")
	view := m.View().Content
	for _, want := range []string{"DATA volume", "ESP volume", "1.1 GiB", "345.0 MiB"} {
		if !strings.Contains(view, want) {
			t.Fatalf("storage view missing %q", want)
		}
	}
}
