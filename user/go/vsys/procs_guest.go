//go:build virelai

package vsys

// Process-table snapshot over sys_procs (slot 7, ADR 0007).
//
// The row wire layout is fixed by the kernel: u64 pid@0, u64 state@8,
// u64 exit_status@16, name[16] NUL-padded@24, all little-endian, 40 bytes
// per row. That layout is documented canonically in user/go/vi/ipc.go
// (vi.ProcRow / vi.Procs). This file cannot reuse that decoder because vi
// imports vsys (an import cycle), so the decode below mirrors it
// field-for-field and must stay in sync with it.
const SlotProcs uintptr = 7

const (
	// ProcRowSize is the fixed width of one sys_procs snapshot row.
	ProcRowSize = 40
	// ProcNameBytes is the NUL-padded name field width inside a row.
	ProcNameBytes = 16
)

// Process state codes as marshalled by the kernel snapshot (mirrors
// vi.ProcCreated / vi.ProcRunning / vi.ProcExited).
const (
	ProcCreated uint64 = 1
	ProcRunning uint64 = 2
	ProcExited  uint64 = 3
)

// ProcRow is one decoded sys_procs row (mirrors vi.ProcRow).
type ProcRow struct {
	PID        uint64
	State      uint64
	ExitStatus uint64
	NameBuf    [ProcNameBytes]byte
}

// Name returns the row's process name with the NUL padding trimmed.
func (r ProcRow) Name() string {
	n := 0
	for n < len(r.NameBuf) && r.NameBuf[n] != 0 {
		n++
	}
	return string(r.NameBuf[:n])
}

func getU64(b []byte) uint64 {
	return uint64(b[0]) | uint64(b[1])<<8 | uint64(b[2])<<16 | uint64(b[3])<<24 |
		uint64(b[4])<<32 | uint64(b[5])<<40 | uint64(b[6])<<48 | uint64(b[7])<<56
}

// Procs snapshots the process table into dst, returning the number of rows
// written and the raw kernel result. sys_procs floors the request to whole
// rows and returns the ROW COUNT, not a byte count.
func Procs(dst []ProcRow) (int, int64) {
	if len(dst) == 0 {
		return 0, 0
	}
	buf := make([]byte, len(dst)*ProcRowSize)
	r := syscallFn(SlotProcs, slicePtr(buf), uintptr(len(buf)), 0, 0)
	if r < 0 {
		return 0, r
	}
	rows := int(r)
	if rows > len(dst) {
		rows = len(dst)
	}
	for i := 0; i < rows; i++ {
		off := i * ProcRowSize
		dst[i] = ProcRow{
			PID:        getU64(buf[off:]),
			State:      getU64(buf[off+8:]),
			ExitStatus: getU64(buf[off+16:]),
		}
		copy(dst[i].NameBuf[:], buf[off+24:off+24+ProcNameBytes])
	}
	return rows, r
}
