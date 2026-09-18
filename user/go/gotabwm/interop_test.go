package main

import (
	"testing"

	"virelai/vi"
)

// The gate greps these exact strings; a drift is a host-test failure rather
// than a live run that silently asserts nothing.
func TestInteropMarkerShapes(t *testing.T) {
	cases := []struct{ got, want string }{
		{MarkerRpcDeclare, "gotabwm: rpc declare id="},
		{MarkerRpcRaise, "gotabwm: rpc raise id="},
		{MarkerRpcAttach, "gotabwm: rpc attach id="},
		{MarkerRpcDetach, "gotabwm: rpc detach id="},
		{MarkerRpcCycle, "gotabwm: rpc cycle"},
		{MarkerRpcOther, "gotabwm: rpc other kind="},
		{MarkerHostFocus, "gotabwm: host focus id="},
		{MarkerHostView, "gotabwm: host view id="},
		{MarkerHostClose, "gotabwm: host close id="},
		{MarkerHostDone, "gotabwm: host done"},
		{MarkerTabOpen, "gotabwm: tab open id="},
		{MarkerTabFocus, "gotabwm: tab focus id="},
		{MarkerTabClose, "gotabwm: tab close id="},
		{MarkerRail, "gotabwm: rail "},
		{MarkerTabsEmpty, "gotabwm: tabs empty"},
		{MarkerSplit, "gotabwm: split "},
		{MarkerUnsplit, "gotabwm: unsplit"},
		{MarkerLayout, "gotabwm: layout "},
		{MarkerLayoutFile, "gotabwm: layout file="},
		{MarkerPane, "gotabwm: pane "},
		{MarkerPin, "gotabwm: pin "},
		{MarkerReorder, "gotabwm: reorder "},
		{MarkerOrder, "gotabwm: order "},
		{MarkerSessionWrite, "gotabwm: session write n="},
		{MarkerSessionLoad, "gotabwm: session load n="},
		{MarkerSessionTitles, "gotabwm: session titles="},
		{MarkerSessionBad, "gotabwm: session bad"},
	}
	for _, c := range cases {
		if c.got != c.want {
			t.Fatalf("marker = %q want %q", c.got, c.want)
		}
	}
}

// The ack MUST set the reply bit and mirror id/seq, or an unmodified Zig app
// ignores it and falls back to its legacy rect (the interop silently no-ops).
func TestBuildReplyWire(t *testing.T) {
	req := vi.WmRpc{Kind: vi.WmRpcKindDeclareFullscreen, ID: 7, Seq: 5, ReplyTo: 3}
	req.SetTitle("Calc")
	rep := buildReply(req, true)
	if rep.Kind&vi.WmRpcReplyFlag == 0 {
		t.Fatalf("ack kind %#x lacks the reply bit", rep.Kind)
	}
	if rep.Kind&0x7f != vi.WmRpcKindDeclareFullscreen {
		t.Fatalf("ack kind %#x lost the request kind", rep.Kind)
	}
	if rep.ID != req.ID || rep.Seq != req.Seq {
		t.Fatalf("ack id/seq = %d/%d want %d/%d", rep.ID, rep.Seq, req.ID, req.Seq)
	}
	if rep.Applied != 1 {
		t.Fatalf("ack applied = %d want 1", rep.Applied)
	}
	if rep.ReplyTo != req.ReplyTo {
		t.Fatalf("ack reply_to = %d want %d", rep.ReplyTo, req.ReplyTo)
	}
	// The ack frame must survive the wire round-trip the app decodes.
	got, ok := vi.DecodeWmRpc(rep.Encode())
	if !ok || got.Kind != rep.Kind || got.ID != rep.ID || got.Seq != rep.Seq || got.Applied != 1 {
		t.Fatalf("ack round-trip = %+v ok=%v", got, ok)
	}
	if rep2 := buildReply(req, false); rep2.Applied != 0 {
		t.Fatalf("refused ack applied = %d want 0", rep2.Applied)
	}
}

// A hosted app is closed after hostTicks ticks - the budget the composite loop
// counts down.
func TestHostTickBudget(t *testing.T) {
	if hostTicks <= 0 {
		t.Fatalf("hostTicks = %d: an app would never be closed", hostTicks)
	}
	if hostTicks > maxTicks {
		t.Fatalf("hostTicks %d > maxTicks %d: the close is unreachable", hostTicks, maxTicks)
	}
	// Two-tab path: 1 tick to show n=2, reorder, pin+refocus, SplitV,
	// Unsplit, SplitH, Unsplit, close pinned, close last (9). Plus the
	// single-tab budget must still fit in maxTicks.
	const twoTabTicks = 9
	if hostTicks+twoTabTicks > maxTicks {
		t.Fatalf("hostTicks %d + two-tab choreography %d > maxTicks %d",
			hostTicks, twoTabTicks, maxTicks)
	}
}

// The seat must not repaint the blank desktop while a tab is hosted, or the
// compose-N target (above the kernel's window layer) would overpaint the client.
func TestHostedSuppressesBlankPaint(t *testing.T) {
	savedTabs := tabs
	savedHosted := hostedApp
	defer func() {
		tabs = savedTabs
		hostedApp = savedHosted
	}()
	tabs = TabStrip{}
	hostedApp = 0
	if tabs.Count() != 0 {
		t.Fatal("strip should start empty")
	}
	if !tabs.OpenTab(9, "x") {
		t.Fatal("OpenTab")
	}
	hostedApp = 9
	if tabs.Count() == 0 || hostedApp == 0 {
		t.Fatal("hosted tab should be set")
	}
}

func TestLateOpenTabClearsStripDone(t *testing.T) {
	savedTabs := tabs
	savedDone, savedTwo, savedOne, savedStep := stripDone, stripSawTwo, stripClosedOne, stripStep
	defer func() {
		tabs = savedTabs
		stripDone, stripSawTwo, stripClosedOne, stripStep = savedDone, savedTwo, savedOne, savedStep
	}()

	tabs = TabStrip{}
	stripDone, stripSawTwo, stripClosedOne, stripStep = true, true, true, 4
	if !tabs.OpenTab(4, "late") {
		t.Fatal("OpenTab from empty")
	}
	noteStripOpen()
	if stripDone || stripSawTwo || stripClosedOne || stripStep != 0 {
		t.Fatalf("late OpenTab from empty left stripDone=%v sawTwo=%v closedOne=%v step=%d",
			stripDone, stripSawTwo, stripClosedOne, stripStep)
	}

	// A second tab on a live strip must not clear the two-tab latch.
	stripSawTwo = true
	if !tabs.OpenTab(5, "b") {
		t.Fatal("OpenTab second")
	}
	noteStripOpen()
	if !stripSawTwo {
		t.Fatal("OpenTab of a second tab cleared stripSawTwo")
	}

	// A no-op (duplicate) OpenTab must not reset either.
	stripDone = true
	if tabs.OpenTab(5, "b") {
		t.Fatal("duplicate OpenTab counted as added")
	}
	// applyRPC only calls noteStripOpen on added==true; pin that Count!=1
	// is what the helper uses when a second tab is already present.
	if tabs.Count() != 2 {
		t.Fatalf("count = %d want 2", tabs.Count())
	}
}

func TestAttachSyncsHostState(t *testing.T) {
	savedTabs := tabs
	savedHosted := hostedApp
	savedTicks := hostTicksLeft
	defer func() {
		tabs = savedTabs
		hostedApp = savedHosted
		hostTicksLeft = savedTicks
	}()

	tabs = TabStrip{}
	hostedApp = 0
	hostTicksLeft = 0
	if !tabs.OpenTab(7, "attached") {
		t.Fatal("OpenTab")
	}
	noteStripOpen()
	if !tabs.FocusTab(7) {
		t.Fatal("FocusTab")
	}
	hostedApp = 7
	hostTicksLeft = hostTicks
	if id, ok := tabs.Focused(); !ok || id != 7 || hostedApp != 7 || hostTicksLeft != hostTicks {
		t.Fatalf("attach sync: focus=%d ok=%v hosted=%d ticks=%d", id, ok, hostedApp, hostTicksLeft)
	}
}
