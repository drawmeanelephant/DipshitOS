package vi

import (
	"testing"
	"unsafe"
)

// The slot table is the browser's contract with the kernel (ADR 0007); these
// numbers are pinned so a drift fails the host suite instead of the VM gate.
func TestSlotNumbers(t *testing.T) {
	want := map[uintptr]string{
		1: "write", 2: "yield", 3: "exit", 4: "sleep",
		5: "ipc_send", 6: "ipc_recv", 7: "procs",
		12: "win_open", 13: "win_fill", 14: "win_present", 15: "win_close",
		19: "win_query", 21: "poll_event", 22: "wait_event",
		23: "file_open", 24: "file_read", 25: "file_write", 26: "file_close", 27: "dir_list",
		28: "exec",
		30: "tcp_connect", 31: "tcp_send", 32: "tcp_recv", 33: "tcp_close",
		34: "file_delete", 36: "file_truncate",
		46: "win_fill_batch", 63: "mmap", 66: "time",
	}
	got := map[uintptr]string{
		SlotWrite: "write", SlotYield: "yield", SlotExit: "exit", SlotSleep: "sleep",
		SlotIPCSend: "ipc_send", SlotIPCRecv: "ipc_recv", SlotProcs: "procs",
		SlotWinOpen: "win_open", SlotWinFill: "win_fill", SlotWinPresent: "win_present",
		SlotWinClose: "win_close", SlotWinQuery: "win_query",
		SlotPollEvent: "poll_event", SlotWaitEvent: "wait_event",
		SlotFileOpen: "file_open", SlotFileRead: "file_read", SlotFileWrite: "file_write",
		SlotFileClose: "file_close", SlotDirList: "dir_list", SlotExec: "exec",
		SlotTCPConnect: "tcp_connect", SlotTCPSend: "tcp_send", SlotTCPRecv: "tcp_recv",
		SlotTCPClose: "tcp_close", SlotFileDelete: "file_delete",
		SlotFileTruncate: "file_truncate", SlotWinFillBatch: "win_fill_batch",
		SlotMmap: "mmap", SlotTime: "time",
	}
	for slot, name := range want {
		if got[slot] != name {
			t.Fatalf("slot %d = %q want %q", slot, got[slot], name)
		}
	}
	if len(got) != len(want) {
		t.Fatalf("slot table drift: %d entries want %d", len(got), len(want))
	}
}

// The event wire format must stay 16 bytes (ADR 0009) — the kernel copies
// exactly that many bytes out through uaccess.
func TestEventWireSize(t *testing.T) {
	if got := unsafe.Sizeof(Event{}); got != 16 {
		t.Fatalf("Event size = %d want 16", got)
	}
	if off := unsafe.Offsetof(Event{}.Seq); off != 4 {
		t.Fatalf("Seq offset = %d want 4", off)
	}
	if off := unsafe.Offsetof(Event{}.Arg1); off != 12 {
		t.Fatalf("Arg1 offset = %d want 12", off)
	}
}

// The batch record is 24 bytes with the kernel's field offsets
// (kernel/src/syscall.zig handle_win_fill_batch).
func TestFillerPacking(t *testing.T) {
	if FillRectSize != 24 || FillBatchMax != 32 {
		t.Fatalf("batch geometry = %d/%d want 24/32", FillRectSize, FillBatchMax)
	}
	var f Filler
	f.Rect(7, 1, 2, 3, 4, 0x11223344)
	if f.Pending() != 1 {
		t.Fatalf("pending = %d want 1", f.Pending())
	}
	b := f.buf[:FillRectSize]
	if b[0] != 7 {
		t.Fatalf("id byte = %d", b[0])
	}
	read := func(off int) uint32 {
		return uint32(b[off]) | uint32(b[off+1])<<8 | uint32(b[off+2])<<16 | uint32(b[off+3])<<24
	}
	if read(4) != 1 || read(8) != 2 || read(12) != 3 || read(16) != 4 || read(20) != 0x11223344 {
		t.Fatalf("packed rect wrong: %v", b)
	}
	f.Reset()
	if f.Pending() != 0 {
		t.Fatal("reset did not clear")
	}
}

func TestFillerAutoFlushBoundary(t *testing.T) {
	var f Filler
	for i := 0; i < FillBatchMax; i++ {
		f.Rect(1, uint32(i), 0, 1, 1, 0xFFFFFF)
	}
	if f.Pending() != FillBatchMax {
		t.Fatalf("pending = %d want %d", f.Pending(), FillBatchMax)
	}
	// One more record overflows the batch: on the host Flush() is a no-op
	// sycall that still resets, so the pending count must drop to 1.
	f.Rect(1, 99, 0, 1, 1, 0xFFFFFF)
	if f.Pending() != 1 {
		t.Fatalf("after overflow pending = %d want 1", f.Pending())
	}
}

func TestZeroSizeRectsDropped(t *testing.T) {
	var f Filler
	f.Rect(1, 0, 0, 0, 5, 0xFFFFFF)
	f.Rect(1, 0, 0, 5, 0, 0xFFFFFF)
	if f.Pending() != 0 {
		t.Fatalf("zero-size rects were queued: %d", f.Pending())
	}
}

func TestOutOfRangeAndCaps(t *testing.T) {
	if MaxFileBytes != 256*1024 {
		t.Fatalf("MaxFileBytes = %d", MaxFileBytes)
	}
	if writeChunk > 256 {
		t.Fatalf("console chunk %d exceeds the kernel cap", writeChunk)
	}
	// Host: every syscall is a no-op, so reads fail cleanly rather than panic.
	if b, rc := ReadFileAll("/host/NOPE.HTML", 1024); b != nil || rc >= 0 {
		t.Fatalf("host read should fail: %v %d", b, rc)
	}
	if FileExists("/host/NOPE.HTML") {
		t.Fatal("host FileExists should be false")
	}
	if FileAppend("/host/NOPE.TXT", []byte("x")) {
		t.Fatal("host FileAppend should fail")
	}
	Console(string(make([]byte, 1000))) // must not panic when chunked
}

func TestArgsHost(t *testing.T) {
	if Args() != nil {
		t.Fatal("host Args should be nil")
	}
}

func TestDirEntryWireSize(t *testing.T) {
	if got := unsafe.Sizeof(DirEntry{}); got != 40 {
		t.Fatalf("DirEntry size = %d want 40", got)
	}
	if off := unsafe.Offsetof(DirEntry{}.Size); off != 32 {
		t.Fatalf("Size offset = %d want 32", off)
	}
	if off := unsafe.Offsetof(DirEntry{}.IsDir); off != 36 {
		t.Fatalf("IsDir offset = %d want 36", off)
	}
	if MaxDirEntries != 16 {
		t.Fatalf("MaxDirEntries = %d want 16", MaxDirEntries)
	}
}

func TestDirEntryNameString(t *testing.T) {
	var e DirEntry
	copy(e.Name[:], "KNOWN.TXT")
	e.IsDir = 0
	if got := e.NameString(); got != "KNOWN.TXT" {
		t.Fatalf("NameString = %q", got)
	}
	if e.Dir() {
		t.Fatal("file must not report Dir")
	}
	e.IsDir = 1
	if !e.Dir() {
		t.Fatal("directory must report Dir")
	}
}

func TestDirListHostFails(t *testing.T) {
	var buf [MaxDirEntries]DirEntry
	n, rc := DirList("/host", buf[:])
	if n != 0 || rc >= 0 {
		t.Fatalf("host DirList = %d, %d want 0, <0", n, rc)
	}
}

func TestExecRefusals(t *testing.T) {
	if _, err := Exec(""); err != errno(ErrEINVAL) {
		t.Fatalf("empty name: %v", err)
	}
	tooMany := make([]string, 9)
	if _, err := Exec("X.BIN", tooMany...); err != errno(ErrEINVAL) {
		t.Fatalf("argc>8: %v", err)
	}
}
