//go:build virelai || pulse

package main

import (
	"reflect"
	"testing"
)

func stubSnap() snapshot {
	return snapshot{
		uptimeNs: 3723000000000,
		procs: []procInfo{
			{pid: 9, name: "ZED.BIN", state: 3},
			{pid: 2, name: "PULSE.ELF", state: 2},
			{pid: 5, name: "ALPHA.ELF", state: 1},
			{pid: 1, name: "GOTABWM.ELF", state: 2},
		},
		taken: true,
	}
}

func pids(rows []procInfo) []uint64 {
	out := make([]uint64, len(rows))
	for i, r := range rows {
		out[i] = r.pid
	}
	return out
}

func TestVisibleProcsSortsByPID(t *testing.T) {
	got := pids(visibleProcs(stubSnap(), sortPID, ""))
	want := []uint64{1, 2, 5, 9}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("pid sort = %v, want %v", got, want)
	}
}

func TestVisibleProcsSortsByName(t *testing.T) {
	got := pids(visibleProcs(stubSnap(), sortName, ""))
	want := []uint64{5, 1, 2, 9} // ALPHA, GOTABWM, PULSE, ZED
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("name sort = %v, want %v", got, want)
	}
}

func TestVisibleProcsSortsByStateLiveFirst(t *testing.T) {
	got := pids(visibleProcs(stubSnap(), sortState, ""))
	want := []uint64{1, 2, 5, 9} // running, running, created, exited
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("state sort = %v, want %v", got, want)
	}
}

func TestVisibleProcsFiltersCaseInsensitively(t *testing.T) {
	got := visibleProcs(stubSnap(), sortPID, "elf")
	if len(got) != 3 {
		t.Fatalf("filter 'elf' matched %d rows, want 3", len(got))
	}
	got = visibleProcs(stubSnap(), sortPID, "ZED")
	if len(got) != 1 || got[0].pid != 9 {
		t.Fatalf("filter 'ZED' = %+v, want pid 9 only", got)
	}
}

func TestVisibleProcsEmptySnapshot(t *testing.T) {
	if got := visibleProcs(snapshot{}, sortPID, ""); len(got) != 0 {
		t.Fatalf("empty snapshot gave %d rows", len(got))
	}
}

func TestCountStates(t *testing.T) {
	r, c, e := countStates(stubSnap())
	if r != 2 || c != 1 || e != 1 {
		t.Fatalf("counts = %d/%d/%d, want 2/1/1", r, c, e)
	}
}

func TestFormatUptime(t *testing.T) {
	for ns, want := range map[int64]string{
		0:             "0s",
		45000000000:   "45s",
		754000000000:  "12m 34s",
		5025000000000: "1h 23m 45s",
		-5:            "0s",
	} {
		if got := formatUptime(ns); got != want {
			t.Fatalf("formatUptime(%d) = %q, want %q", ns, got, want)
		}
	}
}

func TestFormatBytes(t *testing.T) {
	for n, want := range map[int64]string{
		-1:         "unknown",
		0:          "0 B",
		999:        "999 B",
		1024:       "1.0 KiB",
		1536:       "1.5 KiB",
		1048576:    "1.0 MiB",
		361758720:  "345.0 MiB",
		1288490188: "1.1 GiB",
	} {
		if got := formatBytes(n); got != want {
			t.Fatalf("formatBytes(%d) = %q, want %q", n, got, want)
		}
	}
}

func TestStateName(t *testing.T) {
	for s, want := range map[uint64]string{1: "created", 2: "running", 3: "exited", 99: "unknown"} {
		if got := stateName(s); got != want {
			t.Fatalf("stateName(%d) = %q, want %q", s, got, want)
		}
	}
}

func TestKillErrText(t *testing.T) {
	if got := killErrText(-1); got != "EINVAL (bad target)" {
		t.Fatalf("killErrText(-1) = %q", got)
	}
	if got := killErrText(-13); got != "errno 13 (cross-principal kill needs cap_proc_admin)" {
		t.Fatalf("killErrText(-13) = %q", got)
	}
}
