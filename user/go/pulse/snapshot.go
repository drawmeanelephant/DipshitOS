//go:build virelai

package main

import (
	"virelai/vsys"
)

// takeSnapshot polls every data source the UI shows. It runs at 1 Hz from
// the app timer in main; a slow or failing source must never take the UI
// down, so each read is independent and failures surface as zero values.
func takeSnapshot() snapshot {
	var s snapshot
	s.uptimeNs = vsys.Nanotime()

	var rows [16]vsys.ProcRow
	n, rc := vsys.Procs(rows[:])
	if rc >= 0 {
		for i := 0; i < n; i++ {
			s.procs = append(s.procs, procInfo{
				pid:   rows[i].PID,
				name:  rows[i].Name(),
				state: rows[i].State,
			})
		}
	}

	s.dataFree = vsys.VolumeFree(0)
	s.espFree = vsys.VolumeFree(1)
	s.tcpOpen = vsys.ClientLive != nil
	s.taken = true
	return s
}

// guestKill arms a process for termination (slot 29).
func guestKill(pid uint64) int64 {
	return vsys.Kill(pid)
}
