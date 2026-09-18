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
		34: "file_delete", 35: "file_rename", 36: "file_truncate",
		42: "audio_info", 43: "audio_play",
		46: "win_fill_batch", 63: "mmap", 66: "time", 67: "tty_attach",
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
		SlotFileRename: "file_rename", SlotFileTruncate: "file_truncate",
		SlotAudioInfo: "audio_info",
		SlotAudioPlay: "audio_play", SlotWinFillBatch: "win_fill_batch",
		SlotMmap: "mmap", SlotTime: "time", SlotTtyAttach: "tty_attach",
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

func TestItoa64(t *testing.T) {
	for _, tc := range []struct {
		value int64
		want  string
	}{
		{0, "0"},
		{1, "1"},
		{-1, "-1"},
		{9223372036854775807, "9223372036854775807"},
		{-9223372036854775808, "-9223372036854775808"},
	} {
		if got := Itoa64(tc.value); got != tc.want {
			t.Errorf("Itoa64(%d) = %q, want %q", tc.value, got, tc.want)
		}
	}
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

func TestTtyAttachSelectors(t *testing.T) {
	if SlotTtyAttach != 67 {
		t.Fatalf("SlotTtyAttach = %d want 67", SlotTtyAttach)
	}
	if TtyDetach != 0 || TtySerial != 1 || TtyWindow != 2 || TtyNet != 3 {
		t.Fatalf("selectors = %d/%d/%d/%d want 0/1/2/3", TtyDetach, TtySerial, TtyWindow, TtyNet)
	}
}

func TestTtyAttachHostFails(t *testing.T) {
	if r := TtyAttach(TtyDetach); r != -ErrENOSYS {
		t.Fatalf("host TtyAttach = %d want -ENOSYS", r)
	}
	if r := TtyAttachWindow(1); r != -ErrENOSYS {
		t.Fatalf("host TtyAttachWindow = %d want -ENOSYS", r)
	}
}

// M66a (#1443): the file-domain error rows, the fsync binding, and the
// chunked write helper.

func TestFileErrorRows(t *testing.T) {
	if ErrFileNotFound != -6 || ErrFileIsDir != -1 || ErrFileExists != -9 || ErrFileHandleFull != -5 {
		t.Fatalf("file rows = %d/%d/%d/%d want -6/-1/-9/-5",
			ErrFileNotFound, ErrFileIsDir, ErrFileExists, ErrFileHandleFull)
	}
	if SlotFileSync != 77 {
		t.Fatalf("SlotFileSync = %d want 77", SlotFileSync)
	}
	// The chunk size IS the kernel's sys_file_write stage cap: a larger
	// count is refused with -ENOSPC (handle_file_write).
	if fileWriteChunk != 2048 {
		t.Fatalf("fileWriteChunk = %d want 2048", fileWriteChunk)
	}
}

// FileWriteAll chunks to the kernel's stage cap and advances by the count
// each call CONFIRMS: a 5000-byte body is 2048/2048/904 on the wire.
func TestFileWriteAllChunksByConfirmedCounts(t *testing.T) {
	var calls []int
	prev := SetSyscallHookForTest(func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
		if num != SlotFileWrite {
			t.Fatalf("slot %d, want file_write", num)
		}
		count := int(a2)
		if count > 2048 {
			return -ErrENOSPC
		}
		calls = append(calls, count)
		return int64(count)
	})
	defer SetSyscallHookForTest(prev)

	body := make([]byte, 5000)
	for i := range body {
		body[i] = byte(i)
	}
	n, r := FileWriteAll(3, body)
	if r != 0 || n != len(body) {
		t.Fatalf("FileWriteAll = %d, %d want %d, 0", n, r, len(body))
	}
	if len(calls) != 3 || calls[0] != 2048 || calls[1] != 2048 || calls[2] != 904 {
		t.Fatalf("chunk plan = %v, want 2048/2048/904", calls)
	}
}

// A mid-stream failure reports the CONFIRMED prefix (the caller can resume
// at n without corrupting the stream); a first-chunk failure reports (0, r).
func TestFileWriteAllSurfacesPartialWrites(t *testing.T) {
	calls := 0
	prev := SetSyscallHookForTest(func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
		calls++
		if calls == 2 {
			return -ErrEBADF // the kernel reports a dead handle mid-stream
		}
		return int64(a2)
	})
	defer SetSyscallHookForTest(prev)

	body := make([]byte, 4096)
	if n, r := FileWriteAll(1, body); r != -ErrEBADF || n != 2048 {
		t.Fatalf("mid-stream = %d, %d want 2048, -2", n, r)
	}

	prev2 := SetSyscallHookForTest(func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
		return -ErrENOSPC
	})
	defer SetSyscallHookForTest(prev2)
	if n, r := FileWriteAll(1, body); r != -ErrENOSPC || n != 0 {
		t.Fatalf("first-chunk = %d, %d want 0, -5", n, r)
	}
}

// A zero-count acceptance cannot advance the stream; the helper stops
// instead of spinning (the kernel never reports one for a non-empty chunk,
// so this guards the loop, not the kernel).
func TestFileWriteAllStopsOnAZeroCount(t *testing.T) {
	prev := SetSyscallHookForTest(func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
		return 0
	})
	defer SetSyscallHookForTest(prev)
	if n, r := FileWriteAll(1, []byte("x")); r >= 0 || n != 0 {
		t.Fatalf("zero-count = %d, %d want 0, <0", n, r)
	}
}

func TestFileSyncBinding(t *testing.T) {
	prev := SetSyscallHookForTest(func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
		if num != SlotFileSync {
			t.Fatalf("slot %d, want file_sync", num)
		}
		if a0 != 4 {
			t.Fatalf("fd arg = %d want 4", a0)
		}
		return 0
	})
	defer SetSyscallHookForTest(prev)
	if r := FileSync(4); r != 0 {
		t.Fatalf("FileSync = %d want 0", r)
	}
}

// FileAppend must chunk: a row longer than the kernel's 2048-byte write
// stage lands whole instead of failing with -ENOSPC.
func TestFileAppendWritesLongRows(t *testing.T) {
	prev := SetSyscallHookForTest(func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
		switch num {
		case SlotFileOpen:
			return 1
		case SlotFileWrite:
			if int(a2) > 2048 {
				return -ErrENOSPC
			}
			return int64(a2)
		case SlotFileClose:
			return 0
		}
		t.Fatalf("unexpected slot %d", num)
		return 0
	})
	defer SetSyscallHookForTest(prev)

	if !FileAppend("/host/SELFTEST/OUT/long.txt", make([]byte, 9000)) {
		t.Fatal("FileAppend failed on a 9000-byte row")
	}
}

// M66b (#1444): the rename binding and the crash-safe replace-write.

// hookStr rebuilds a path argument the fake kernel received. The pointer is
// the one strPtr handed the seam (still live inside the call), so this is
// the same contract the guest assembly reads through — test-only.
func hookStr(a0, a1 uintptr) string {
	if a0 == 0 || a1 == 0 {
		return ""
	}
	return string(unsafe.Slice((*byte)(unsafe.Pointer(a0)), a1))
}

// WriteFileSafe's publish order is the contract: open the .tmp, write,
// FSYNC, close, delete the live file, rename the temp over it. The fsync
// and the rename are what make a crash leave either the old bytes or no
// file — never a partial one.
func TestWriteFileSafePublishesByRename(t *testing.T) {
	var seq []uintptr
	prev := SetSyscallHookForTest(func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
		seq = append(seq, num)
		switch num {
		case SlotFileOpen:
			if got := hookStr(a0, a1); got != "/host/SET.TXT.tmp" {
				t.Fatalf("open = %q, want the temp path", got)
			}
			if a2 != uintptr(ModeWrite|ModeCreate) {
				t.Fatalf("open flags = %#x", a2)
			}
			return 1
		case SlotFileWrite:
			return int64(a2)
		case SlotFileSync, SlotFileClose:
			return 0
		case SlotFileDelete:
			if got := hookStr(a0, a1); got != "/host/SET.TXT" {
				t.Fatalf("delete = %q, want the live path", got)
			}
			return 0
		case SlotFileRename:
			if got := hookStr(a0, a1); got != "/host/SET.TXT.tmp" {
				t.Fatalf("rename from = %q, want the temp", got)
			}
			if got := hookStr(a2, a3); got != "/host/SET.TXT" {
				t.Fatalf("rename to = %q, want the live path", got)
			}
			return 0
		}
		t.Fatalf("unexpected slot %d", num)
		return 0
	})
	defer SetSyscallHookForTest(prev)

	if rc := WriteFileSafe("/host/SET.TXT", []byte("#v2\nwm=none\n")); rc != 0 {
		t.Fatalf("WriteFileSafe = %d, want 0", rc)
	}
	want := []uintptr{SlotFileOpen, SlotFileWrite, SlotFileSync, SlotFileClose, SlotFileDelete, SlotFileRename}
	if len(seq) != len(want) {
		t.Fatalf("call seq = %v, want %v", seq, want)
	}
	for i, w := range want {
		if seq[i] != w {
			t.Fatalf("call seq = %v, want %v", seq, want)
		}
	}
}

// Every failure path removes the temp and reports the failing code: the
// live file is left exactly as it was (old bytes or absent), never partial.
func TestWriteFileSafeFailureLeavesNoTemp(t *testing.T) {
	for _, tc := range []struct {
		name  string
		fail  uintptr // the slot that fails
		check func(*testing.T, []uintptr)
	}{
		{"write", SlotFileWrite, func(t *testing.T, seq []uintptr) {
			if seq[len(seq)-1] != SlotFileDelete {
				t.Fatalf("last call = %d, want the temp delete", seq[len(seq)-1])
			}
		}},
		{"sync", SlotFileSync, func(t *testing.T, seq []uintptr) {
			if seq[len(seq)-1] != SlotFileDelete {
				t.Fatalf("last call = %d, want the temp delete", seq[len(seq)-1])
			}
		}},
		{"rename", SlotFileRename, func(t *testing.T, seq []uintptr) {
			// delete(live) -> rename fails -> delete(temp): two deletes.
			if seq[len(seq)-1] != SlotFileDelete || seq[len(seq)-2] != SlotFileRename {
				t.Fatalf("tail = %v, want rename then temp delete", seq[len(seq)-2:])
			}
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var seq []uintptr
			prev := SetSyscallHookForTest(func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
				seq = append(seq, num)
				if num == tc.fail {
					return -ErrEACCES
				}
				switch num {
				case SlotFileOpen:
					return 1
				case SlotFileWrite:
					return int64(a2)
				case SlotFileDelete:
					return 0
				case SlotFileSync, SlotFileClose, SlotFileRename:
					return 0
				}
				t.Fatalf("unexpected slot %d", num)
				return 0
			})
			defer SetSyscallHookForTest(prev)

			if rc := WriteFileSafe("/host/SET.TXT", []byte("body")); rc != -ErrEACCES {
				t.Fatalf("WriteFileSafe = %d, want -7", rc)
			}
			tc.check(t, seq)
		})
	}
}

// An absent live file is not a publish failure: the delete reports ENOENT
// and the rename proceeds (first save on a fresh share).
func TestWriteFileSafeFirstSaveHasNothingToDelete(t *testing.T) {
	var seq []uintptr
	prev := SetSyscallHookForTest(func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
		seq = append(seq, num)
		if num == SlotFileDelete {
			return ErrFileNotFound // nothing live yet
		}
		switch num {
		case SlotFileOpen:
			return 1
		case SlotFileWrite:
			return int64(a2)
		case SlotFileSync, SlotFileClose, SlotFileRename:
			return 0
		}
		t.Fatalf("unexpected slot %d", num)
		return 0
	})
	defer SetSyscallHookForTest(prev)

	if rc := WriteFileSafe("/host/SET.TXT", []byte("body")); rc != 0 {
		t.Fatalf("WriteFileSafe = %d, want 0", rc)
	}
	if seq[len(seq)-1] != SlotFileRename {
		t.Fatalf("last call = %d, want the rename", seq[len(seq)-1])
	}
}

func TestFileRenameBinding(t *testing.T) {
	prev := SetSyscallHookForTest(func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
		if num != SlotFileRename {
			t.Fatalf("slot %d, want file_rename", num)
		}
		if got := hookStr(a0, a1); got != "/host/A" {
			t.Fatalf("from = %q", got)
		}
		if got := hookStr(a2, a3); got != "/host/B" {
			t.Fatalf("to = %q", got)
		}
		return 0
	})
	defer SetSyscallHookForTest(prev)
	if r := FileRename("/host/A", "/host/B"); r != 0 {
		t.Fatalf("FileRename = %d, want 0", r)
	}
	if r := FileRename("", "/host/B"); r != -ErrEINVAL {
		t.Fatalf("empty from = %d, want -1", r)
	}
	if r := FileRename("/host/A", ""); r != -ErrEINVAL {
		t.Fatalf("empty to = %d, want -1", r)
	}
}
