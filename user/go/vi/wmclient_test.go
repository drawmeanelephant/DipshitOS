package vi

import (
	"testing"
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
