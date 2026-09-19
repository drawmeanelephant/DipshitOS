package vi

import (
	"testing"
	"time"
	"unsafe"
)

// The WmRpc wire mirror must stay byte-identical to kernel/src/wnd_core.zig /
// user/src/lib/ui/abi.zig: 38 bytes, kind@0, x@6, title@14.
func TestWmRpcWire(t *testing.T) {
	if got := unsafe.Sizeof(WmRpc{}); got != 38 {
		t.Fatalf("WmRpc size = %d want 38", got)
	}
	if off := unsafe.Offsetof(WmRpc{}.X); off != 6 {
		t.Fatalf("X offset = %d want 6", off)
	}
	if off := unsafe.Offsetof(WmRpc{}.Title); off != 14 {
		t.Fatalf("Title offset = %d want 14", off)
	}
	if WmRpcTitleMax != 24 || WmRpcMax != 64 || WmRpcReplyFlag != 0x80 {
		t.Fatalf("wm rpc consts wrong: %d/%d/%#x", WmRpcTitleMax, WmRpcMax, WmRpcReplyFlag)
	}
	if 38 > WmRpcMax {
		t.Fatalf("frame does not fit the mailbox slot")
	}
}

func TestWmRpcEncodeDecodeRoundTrip(t *testing.T) {
	m := WmRpc{Kind: WmRpcKindDeclareFullscreen, ID: 4, Seq: 1, ReplyTo: 9, Applied: 1}
	m.SetTitle("MyApp")
	b := m.Encode()
	if len(b) != 38 {
		t.Fatalf("encoded len = %d want 38", len(b))
	}
	if b[0] != 8 || b[1] != 4 || b[2] != 1 || b[3] != 9 || b[4] != 1 || b[5] != 0 {
		t.Fatalf("encoded header wrong: %v", b[:6])
	}
	got, ok := DecodeWmRpc(b)
	if !ok {
		t.Fatal("decode failed")
	}
	if got.Kind != m.Kind || got.ID != m.ID || got.Seq != m.Seq || got.ReplyTo != m.ReplyTo || got.Applied != m.Applied {
		t.Fatalf("round-trip header drift: %+v", got)
	}
	if got.TitleString() != "MyApp" {
		t.Fatalf("title = %q", got.TitleString())
	}
	if _, ok := DecodeWmRpc(b[:37]); ok {
		t.Fatal("short buffer should not decode")
	}
}

// The u16 rect fields are little-endian at the frozen offsets: x@6, y@8,
// w@10, h@12.
func TestWmRpcRectBytes(t *testing.T) {
	m := WmRpc{Kind: WmRpcKindConfig, X: 0x1234, Y: 0x5678, W: 0x0102, H: 0x0304}
	b := m.Encode()
	if b[6] != 0x34 || b[7] != 0x12 {
		t.Fatalf("x bytes wrong: %v", b[6:8])
	}
	got, _ := DecodeWmRpc(b)
	if got.X != 0x1234 || got.Y != 0x5678 || got.W != 0x0102 || got.H != 0x0304 {
		t.Fatalf("rect round-trip wrong: %+v", got)
	}
}

func TestWmRpcTitleTruncation(t *testing.T) {
	m := WmRpc{}
	m.SetTitle("012345678901234567890123456789") // 30 > 24
	if m.TitleString() != "012345678901234567890123" {
		t.Fatalf("title truncation = %q", m.TitleString())
	}
	if got := m.Title[WmRpcTitleMax-1]; got != '3' {
		t.Fatalf("last title byte = %q", got)
	}
}

func TestTabClientDispatch(t *testing.T) {
	c := NewTabClient(4, 512, 340)
	if a := c.Dispatch(Event{Kind: EvMouseDown, Arg0: 10, Arg1: 10}); a != WmActionNone {
		t.Fatalf("mouse action = %v", a)
	}
	if c.W != 512 || c.H != 340 {
		t.Fatalf("canvas drifted: %d x %d", c.W, c.H)
	}
	if a := c.Dispatch(Event{Kind: EvWinResize, Arg0: 1100, Arg1: 720}); a != WmActionResized {
		t.Fatalf("resize action = %v", a)
	}
	if c.W != 1100 || c.H != 720 {
		t.Fatalf("resize not tracked: %d x %d", c.W, c.H)
	}
	if a := c.Dispatch(Event{Kind: EvWinFocus}); a != WmActionNone || !c.Focused {
		t.Fatalf("focus not tracked: %v %v", a, c.Focused)
	}
	if a := c.Dispatch(Event{Kind: EvWinBlur}); a != WmActionNone || c.Focused {
		t.Fatalf("blur not tracked: %v %v", a, c.Focused)
	}
	if a := c.Dispatch(Event{Kind: EvWinClose}); a != WmActionClosed {
		t.Fatalf("close action = %v", a)
	}
}

// Off-guest there is no WM seat, so every request is an honest false (never a
// fabricated success).
func TestWmMailRequestNoSeat(t *testing.T) {
	if WmMailRequest(WmRpcKindRaise, 4, 0, 0, 0, 0, "", "DEMOAPP.ELF", 1) {
		t.Fatal("host WmMailRequest should be false")
	}
	if DeclareFullscreen(4, "T", "DEMOAPP.ELF") {
		t.Fatal("host DeclareFullscreen should be false")
	}
	if DeclareNav(4, "/host", "DEMOAPP.ELF") {
		t.Fatal("host DeclareNav should be false")
	}
	if _, ok := PollNav(4, "DEMOAPP.ELF"); ok {
		t.Fatal("host PollNav should be false")
	}
}

func TestWmRpcKindConstants(t *testing.T) {
	pairs := []struct {
		got, want uint8
	}{
		{WmRpcKindRaise, 1}, {WmRpcKindConfig, 2}, {WmRpcKindRegisterAction, 3},
		{WmRpcKindInvokeAction, 4}, {WmRpcKindAttachTab, 5}, {WmRpcKindDetachTab, 6},
		{WmRpcKindCycleTab, 7}, {WmRpcKindDeclareFullscreen, 8},
		{WmRpcKindNavDeclare, 9}, {WmRpcKindNavPoll, 10},
	}
	for _, p := range pairs {
		if p.got != p.want {
			t.Fatalf("kind = %d want %d", p.got, p.want)
		}
	}
}

// wmMailFake is a scripted kernel for the WM_RPC client: a process table
// with a live seat, a send that succeeds, and a recv that is either empty
// or a scripted ack. Slot 4 (sys_sleep) is counted so a silent seat is
// pinned as a tick-bounded park, not a yield-spin.
type wmMailFake struct {
	sendCalls  int
	recvCalls  int
	sleepCalls int
	procsCalls int
	sendTarget uint32
	// reply, when set, is copied into the caller's recv buffer starting at
	// the replyAt-th recv (1-based). recvCalls < replyAt returns empty.
	reply   []byte
	replyAt int
}

func namedProc(pid uint64, name string) ProcRow {
	r := ProcRow{PID: pid, State: ProcRunning}
	copy(r.NameBuf[:], name)
	return r
}

func (f *wmMailFake) hook(num uintptr, a0, a1, a2, a3 uintptr) int64 {
	switch num {
	case SlotProcs:
		f.procsCalls++
		buf := hookBytes(a0, a1)
		rows := []ProcRow{
			namedProc(3, "GOTABWM.ELF"),
			namedProc(9, "NOTE.ELF"),
		}
		n := 0
		for _, r := range rows {
			off := n * ProcRowSize
			if off+ProcRowSize > len(buf) {
				break
			}
			putU64(buf[off:], r.PID)
			putU64(buf[off+8:], r.State)
			putU64(buf[off+16:], r.ExitStatus)
			copy(buf[off+24:], r.NameBuf[:])
			n++
		}
		return int64(n)
	case SlotIPCSend:
		f.sendCalls++
		f.sendTarget = uint32(a0)
		return int64(a2)
	case SlotIPCRecv:
		f.recvCalls++
		if f.reply != nil && f.replyAt > 0 && f.recvCalls >= f.replyAt {
			dst := hookBytes(a0, a1)
			copy(dst, f.reply)
			return int64(len(f.reply))
		}
		return 0
	case SlotSleep:
		f.sleepCalls++
		return 0
	}
	return -ErrENOSYS
}

func startWmMailFake(t *testing.T) *wmMailFake {
	t.Helper()
	f := &wmMailFake{}
	prev := SetSyscallHookForTest(f.hook)
	t.Cleanup(func() { SetSyscallHookForTest(prev) })
	return f
}

func TestWmMailWaitTicksIsATickBound(t *testing.T) {
	// A two-million-iteration yield loop is not a tick bound (#1489).
	if wmMailWaitTicks < 2 || wmMailWaitTicks > 32 {
		t.Fatalf("wmMailWaitTicks = %d want a small scheduler-tick budget", wmMailWaitTicks)
	}
}

// A live WM pid that never acks must refuse in a handful of parks, not hang
// inside a million-iteration yield-spin. This is the live-wm1 path: WinOpen
// succeeded, DeclareFullscreen blocked tabapp.Init until the gate timed out.
func TestWmMailRequestSilentSeatRefuses(t *testing.T) {
	f := startWmMailFake(t)
	start := time.Now()
	if WmMailRequest(WmRpcKindDeclareFullscreen, 4, 0, 0, 0, 0, "T", "NOTE.ELF", 1) {
		t.Fatal("silent seat must refuse, not succeed")
	}
	if elapsed := time.Since(start); elapsed > 500*time.Millisecond {
		t.Fatalf("silent-seat wait hung: %v", elapsed)
	}
	if f.sendCalls != 1 || f.sendTarget != 3 {
		t.Fatalf("send = %d to pid %d, want 1 to WM pid 3", f.sendCalls, f.sendTarget)
	}
	if f.recvCalls != wmMailWaitTicks {
		t.Fatalf("recv probes = %d want %d (one per tick)", f.recvCalls, wmMailWaitTicks)
	}
	if f.sleepCalls != wmMailWaitTicks-1 {
		t.Fatalf("parks = %d want %d (sys_sleep between probes, not after the last)", f.sleepCalls, wmMailWaitTicks-1)
	}
	if DeclareFullscreen(4, "T", "NOTE.ELF") {
		t.Fatal("DeclareFullscreen must surface the refusal")
	}
}

func TestWmMailRequestAckApplied(t *testing.T) {
	f := startWmMailFake(t)
	rep := WmRpc{Kind: WmRpcKindDeclareFullscreen | WmRpcReplyFlag, ID: 4, Seq: 1, Applied: 1}
	f.reply = rep.Encode()
	f.replyAt = 1
	if !WmMailRequest(WmRpcKindDeclareFullscreen, 4, 0, 0, 0, 0, "T", "NOTE.ELF", 1) {
		t.Fatal("applied ack should succeed")
	}
	if f.recvCalls != 1 {
		t.Fatalf("recv probes = %d want 1 (first probe takes a ready ack)", f.recvCalls)
	}
	if f.sleepCalls != 0 {
		t.Fatalf("parks = %d want 0 when the ack is already in the inbox", f.sleepCalls)
	}
}

func TestWmMailRequestAckRefused(t *testing.T) {
	f := startWmMailFake(t)
	rep := WmRpc{Kind: WmRpcKindDeclareFullscreen | WmRpcReplyFlag, ID: 4, Seq: 1, Applied: 0}
	f.reply = rep.Encode()
	f.replyAt = 1
	if WmMailRequest(WmRpcKindDeclareFullscreen, 4, 0, 0, 0, 0, "T", "NOTE.ELF", 1) {
		t.Fatal("applied=0 ack is a refusal")
	}
	if f.sleepCalls != 0 {
		t.Fatalf("parks = %d want 0", f.sleepCalls)
	}
}

func TestWmMailRequestAckAfterPark(t *testing.T) {
	f := startWmMailFake(t)
	rep := WmRpc{Kind: WmRpcKindDeclareFullscreen | WmRpcReplyFlag, ID: 4, Seq: 1, Applied: 1}
	f.reply = rep.Encode()
	f.replyAt = 3
	if !WmMailRequest(WmRpcKindDeclareFullscreen, 4, 0, 0, 0, 0, "T", "NOTE.ELF", 1) {
		t.Fatal("ack after two empty probes should succeed")
	}
	if f.recvCalls != 3 {
		t.Fatalf("recv probes = %d want 3", f.recvCalls)
	}
	if f.sleepCalls != 2 {
		t.Fatalf("parks = %d want 2", f.sleepCalls)
	}
}

func TestPollNavSilentSeatRefuses(t *testing.T) {
	f := startWmMailFake(t)
	start := time.Now()
	if path, ok := PollNav(4, "NOTE.ELF"); ok || path != "" {
		t.Fatalf("silent PollNav = (%q, %v) want empty refusal", path, ok)
	}
	if elapsed := time.Since(start); elapsed > 500*time.Millisecond {
		t.Fatalf("silent PollNav hung: %v", elapsed)
	}
	if f.recvCalls != wmMailWaitTicks || f.sleepCalls != wmMailWaitTicks-1 {
		t.Fatalf("PollNav wait = %d probes / %d parks, want %d / %d",
			f.recvCalls, f.sleepCalls, wmMailWaitTicks, wmMailWaitTicks-1)
	}
}

func TestPollNavAckReturnsPath(t *testing.T) {
	f := startWmMailFake(t)
	rep := WmRpc{Kind: WmRpcKindNavPoll | WmRpcReplyFlag, ID: 4, Seq: 7, Applied: 1}
	rep.SetTitle("/host")
	f.reply = rep.Encode()
	f.replyAt = 1
	path, ok := PollNav(4, "NOTE.ELF")
	if !ok || path != "/host" {
		t.Fatalf("PollNav = (%q, %v) want (/host, true)", path, ok)
	}
	if f.sleepCalls != 0 {
		t.Fatalf("parks = %d want 0", f.sleepCalls)
	}
}
