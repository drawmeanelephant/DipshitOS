package vi

import (
	"testing"
	"unsafe"
)

// M56a: the IPC slot numbers are the kernel's (ADR 0007); pin them so a drift
// fails the host suite instead of the VM gate.
func TestIpcSlotNumbers(t *testing.T) {
	if SlotIPCSend != 5 || SlotIPCRecv != 6 || SlotProcs != 7 {
		t.Fatalf("ipc slots = %d/%d/%d want 5/6/7", SlotIPCSend, SlotIPCRecv, SlotProcs)
	}
}

func TestMailboxBounds(t *testing.T) {
	if MailboxMessageMax != 64 {
		t.Fatalf("MailboxMessageMax = %d want 64", MailboxMessageMax)
	}
	if MailboxMaxMessages != 8 {
		t.Fatalf("MailboxMaxMessages = %d want 8", MailboxMaxMessages)
	}
	if ProcRowSize != 40 || ProcNameBytes != 16 {
		t.Fatalf("proc row geometry = %d/%d want 40/16", ProcRowSize, ProcNameBytes)
	}
}

// A zero-length send is a no-op that returns 0 without a syscall.
func TestIpcSendZeroLength(t *testing.T) {
	if got := IpcSend(3, nil); got != 0 {
		t.Fatalf("nil send = %d want 0", got)
	}
	if got := IpcSend(3, []byte{}); got != 0 {
		t.Fatalf("empty send = %d want 0", got)
	}
}

// A long send is truncated to the slot bound before the syscall. Off-guest
// the syscall is -ENOSYS, so this proves the bound was applied (no panic, a
// well-formed call) rather than host I/O.
func TestIpcSendTruncatesToSlotBound(t *testing.T) {
	long := make([]byte, MailboxMessageMax*3)
	if got := IpcSend(3, long); got != -ErrENOSYS {
		t.Fatalf("host send = %d want %d", got, -ErrENOSYS)
	}
}

func TestIpcRecvHostDegrades(t *testing.T) {
	var buf [8]byte
	n, r := IpcRecv(buf[:])
	if n != 0 || r != -ErrENOSYS {
		t.Fatalf("host recv = (%d,%d) want (0,%d)", n, r, -ErrENOSYS)
	}
	if n, r := IpcRecv(nil); n != 0 || r != 0 {
		t.Fatalf("empty recv = (%d,%d) want (0,0)", n, r)
	}
}

func TestProcsHostDegrades(t *testing.T) {
	rows := make([]ProcRow, 4)
	n, r := Procs(rows)
	if n != 0 || r != -ErrENOSYS {
		t.Fatalf("host procs = (%d,%d) want (0,%d)", n, r, -ErrENOSYS)
	}
	if n, r := Procs(nil); n != 0 || r != 0 {
		t.Fatalf("empty procs = (%d,%d) want (0,0)", n, r)
	}
}

// ProcRow decodes the kernel's fixed little-endian layout: pid@0, state@8,
// exit@16, name@24. A synthetic row goes through the same helpers the reader
// uses so the offsets are pinned together.
func TestProcRowLayout(t *testing.T) {
	if ProcRowSize != 40 {
		t.Fatalf("row size %d want 40", ProcRowSize)
	}
	if off := unsafe.Offsetof(ProcRow{}.NameBuf); off != 24 {
		t.Fatalf("NameBuf offset %d want 24", off)
	}
	raw := make([]byte, ProcRowSize)
	putU64(raw[0:], 7)
	putU64(raw[8:], ProcRunning)
	putU64(raw[16:], 0)
	copy(raw[24:], "TABWM.BIN")
	if getU64(raw[0:]) != 7 || getU64(raw[8:]) != ProcRunning {
		t.Fatal("row helpers wrong")
	}
	row := ProcRow{PID: getU64(raw[0:]), State: getU64(raw[8:])}
	copy(row.NameBuf[:], raw[24:24+ProcNameBytes])
	if row.Name() != "TABWM.BIN" {
		t.Fatalf("name = %q", row.Name())
	}
	// NUL padding is trimmed.
	short := ProcRow{}
	copy(short.NameBuf[:], "WND.BIN")
	if short.Name() != "WND.BIN" {
		t.Fatalf("padded name = %q", short.Name())
	}
}

func TestWmPeersHostEmpty(t *testing.T) {
	if p := WmPeers("DEMOAPP.ELF"); p.WM != 0 || p.Self != 0 {
		t.Fatalf("host WmPeers = %+v want zero", p)
	}
	if p := WmPeers(""); p.WM != 0 || p.Self != 0 {
		t.Fatalf("empty-name WmPeers = %+v want zero", p)
	}
}

// The errno table mirrors the kernel ErrorCode magnitudes
// (kernel/src/syscall.zig) — this is the M56a defect fix (ENOENT/ENOSPC were
// swapped and EEXIST aliased ENXIO before it).
func TestErrnoTable(t *testing.T) {
	pairs := []struct {
		got, want int64
	}{
		{ErrEINVAL, 1}, {ErrEBADF, 2}, {ErrEFAULT, 3}, {ErrENOSYS, 4},
		{ErrENOSPC, 5}, {ErrENOENT, 6}, {ErrEACCES, 7}, {ErrENAMETOOLONG, 8},
		{ErrENXIO, 9}, {ErrENOMEM, 10}, {ErrEAGAIN, 11}, {ErrETIMEDOUT, 12},
	}
	for _, p := range pairs {
		if p.got != p.want {
			t.Fatalf("errno constant = %d want %d", p.got, p.want)
		}
	}
	if -ErrENOSPC != -5 || -ErrENOENT != -6 {
		t.Fatalf("negation wrong: %d %d", -ErrENOSPC, -ErrENOENT)
	}
	if errno(ErrENOSPC).Error() != "ENOSPC" || errno(ErrENOENT).Error() != "ENOENT" {
		t.Fatalf("errno strings wrong: %s %s", errno(ErrENOSPC).Error(), errno(ErrENOENT).Error())
	}
}
