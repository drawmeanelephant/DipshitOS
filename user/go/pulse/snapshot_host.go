//go:build !virelai

package main

// Host snapshot stub: canned data so the model, update and view layers are
// fully testable off the guest. The guest build never compiles this file.
func takeSnapshot() snapshot {
	return snapshot{
		uptimeNs: 5025000000000, // 1h 23m 45s
		procs: []procInfo{
			{pid: 1, name: "GOTABWM.ELF", state: 2},
			{pid: 2, name: "PULSE.ELF", state: 2},
			{pid: 3, name: "NOTE.ELF", state: 1},
			{pid: 4, name: "TOP.BIN", state: 3},
		},
		dataFree: 1288490188, // ~1.2 GiB
		espFree:  361758720,  // ~345 MiB
		tcpOpen:  false,
		taken:    true,
	}
}

// The host cannot arm a Virelai process for termination: report ENOSYS.
func guestKill(pid uint64) int64 {
	return -38
}
