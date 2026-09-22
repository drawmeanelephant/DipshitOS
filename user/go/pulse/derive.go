package main

// Untagged on purpose: this layer is pure (no tea, no syscalls), so it is the
// part of pulse the default `go test ./...` class-A run exercises; the
// Charm-dependent model/update/view files stay behind `virelai || pulse`.

import (
	"sort"
	"strings"
)

// stateName renders a kernel process state code for the table.
func stateName(s uint64) string {
	switch s {
	case 1: // ProcCreated
		return "created"
	case 2: // ProcRunning
		return "running"
	case 3: // ProcExited
		return "exited"
	}
	return "unknown"
}

// stateRank orders states for sorting: live first, dead last.
func stateRank(s uint64) int {
	switch s {
	case 2:
		return 0
	case 1:
		return 1
	case 3:
		return 2
	}
	return 3
}

// visibleProcs applies the name filter and the sort column to a snapshot.
// It is pure: the same snapshot always renders the same table.
func visibleProcs(snap snapshot, col sortCol, filter string) []procInfo {
	rows := snap.procs
	if filter != "" {
		f := strings.ToLower(filter)
		kept := rows[:0:0]
		for _, p := range rows {
			if strings.Contains(strings.ToLower(p.name), f) {
				kept = append(kept, p)
			}
		}
		rows = kept
	}
	out := make([]procInfo, len(rows))
	copy(out, rows)
	sort.SliceStable(out, func(i, j int) bool {
		switch col {
		case sortName:
			if out[i].name != out[j].name {
				return out[i].name < out[j].name
			}
		case sortState:
			if ri, rj := stateRank(out[i].state), stateRank(out[j].state); ri != rj {
				return ri < rj
			}
		}
		return out[i].pid < out[j].pid
	})
	return out
}

// countStates tallies the snapshot by state code.
func countStates(snap snapshot) (running, created, exited int) {
	for _, p := range snap.procs {
		switch p.state {
		case 2:
			running++
		case 1:
			created++
		case 3:
			exited++
		}
	}
	return running, created, exited
}

// formatUptime renders nanoseconds as "1h 23m 45s" (dropping zero units).
func formatUptime(ns int64) string {
	if ns < 0 {
		ns = 0
	}
	s := ns / 1e9
	h := s / 3600
	m := (s % 3600) / 60
	sec := s % 60
	switch {
	case h > 0:
		return itoa64(uint64(h)) + "h " + itoa64(uint64(m)) + "m " + itoa64(uint64(sec)) + "s"
	case m > 0:
		return itoa64(uint64(m)) + "m " + itoa64(uint64(sec)) + "s"
	default:
		return itoa64(uint64(sec)) + "s"
	}
}

// formatBytes renders a byte count as "1.2 GiB" (one decimal when >= 10 of a
// unit would be misleadingly coarse). Negative means unknown.
func formatBytes(n int64) string {
	if n < 0 {
		return "unknown"
	}
	const (
		kiB = 1024
		miB = 1024 * kiB
		giB = 1024 * miB
	)
	switch {
	case n >= giB:
		return oneDecimal(n, giB) + " GiB"
	case n >= miB:
		return oneDecimal(n, miB) + " MiB"
	case n >= kiB:
		return oneDecimal(n, kiB) + " KiB"
	default:
		return itoa64(uint64(n)) + " B"
	}
}

func oneDecimal(n, unit int64) string {
	whole := n / unit
	tenths := (n % unit * 10) / unit
	return itoa64(uint64(whole)) + "." + itoa64(uint64(tenths))
}

// itoa64 renders a uint64 without importing strconv (keeps the guest import
// surface identical to the other seat apps, which use vi.Itoa64).
func itoa64(v uint64) string {
	if v == 0 {
		return "0"
	}
	var b [20]byte
	i := len(b)
	for v > 0 {
		i--
		b[i] = byte('0' + v%10)
		v /= 10
	}
	return string(b[i:])
}

// killErrText renders a sys_kill errno honestly: EINVAL is documented in the
// ABI; anything else is reported raw with the likely cause.
func killErrText(rc int64) string {
	if rc == -1 {
		return "EINVAL (bad target)"
	}
	return "errno " + itoa64(uint64(-rc)) + " (cross-principal kill needs cap_proc_admin)"
}
