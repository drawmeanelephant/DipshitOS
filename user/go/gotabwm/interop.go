// GOTABWM.ELF - M57c (issue #1318): the Go seat hosts UNMODIFIED Zig apps.
//
// This is the card that makes the seat real. A Zig app (CALC.BIN, NOTEPAD.BIN)
// links lib/tabapp.zig, opens its own window, then declares itself to the
// running WM over the WM_RPC mailbox and waits for the ack. It discovers the WM
// purely by process name (abi.zig wm_proc_names), which M57c extended with
// GOTABWM.ELF - the same additive step M42 SX3 took for TABWM.BIN. No app
// source change, no port: the same binaries that run under TABWM run here.
//
// The seat is the SERVER half. It drains its own mailbox, applies each request
// with the kernel's own primitives, and acks to the requester. The markers are:
//
//	declare_fullscreen (8)      gotabwm: tab open id=<n>
//	                            gotabwm: host focus / tab focus id=<n>
//	                            gotabwm: host view id=<n>
//	                            gotabwm: rpc declare id=<n>
//	raise (1)                   gotabwm: rpc raise / tab focus id=<n>
//	attach (5)                  gotabwm: tab open (if new); rpc attach id=<n>
//	detach (6)                  gotabwm: rpc detach id=<n>
//	cycle (7)                   gotabwm: tab focus id=<n>; rpc cycle
//	anything else               gotabwm: rpc other kind=<n>
//	rail after paint            gotabwm: rail n=<n> focus=<id>
//	close focused / last        gotabwm: host close / tab close id=<n>
//	                            then tab focus remaining, or tabs empty
//	loop ends                   gotabwm: host done
//
// The ack is the M56b wire (wmclient.go / wnd_core.zig): kind | 0x80, id, seq,
// applied. The app's own "calc: tab-aware (full-viewport)" proves the ack
// carried applied=1; "calc: resize relayout" / "notepad: resize relayout"
// proves the full-viewport proposal reached it; "calc: win_close" proves the
// close did.
package main

import (
	"virelai/vi"
)

// The interop markers the class-B gate greps. Exported so interop_test.go can
// pin the exact shapes (a drift is a host-test failure, not a silent live miss).
const (
	MarkerRpcDeclare = "gotabwm: rpc declare id="
	MarkerRpcRaise   = "gotabwm: rpc raise id="
	MarkerRpcAttach  = "gotabwm: rpc attach id="
	MarkerRpcDetach  = "gotabwm: rpc detach id="
	MarkerRpcCycle   = "gotabwm: rpc cycle"
	MarkerRpcOther   = "gotabwm: rpc other kind="
	MarkerHostFocus  = "gotabwm: host focus id="
	MarkerHostView   = "gotabwm: host view id="
	MarkerHostClose  = "gotabwm: host close id="
	MarkerHostDone   = "gotabwm: host done"
)

// tabs is the in-process strip (M62b). hostedApp is the focused client's
// window id (0 = none) kept in sync so the M57c paint-suppression check
// and go-wm-seat close path keep working with one hosted app.
var (
	tabs      TabStrip
	hostedApp uint32
)

// hostTicks is how long the seat hosts a SINGLE app before closing it —
// enough composite ticks for the app to declare, take the viewport and relayout.
// Two tabs skip this countdown and use the strip choreography in seat.go.
const hostTicks = 3

// hostTicksLeft counts down while exactly one tab is open; the composite
// loop closes that tab when it reaches zero (go-wm-seat / go-wm-default).
var hostTicksLeft int

// Two-tab close choreography (M62b): wait until the rail has been painted
// with n>=2, close the focused tab, then close the last. The seat stays
// registered after the strip is empty.
var (
	stripSawTwo    bool
	stripClosedOne bool
	stripDone      bool
	stripStep      int // two-tab: rail → reorder → pin → V → unsplit → H → unsplit → close pinned → close last
)

// serviceRPC drains the seat's mailbox and services every queued WM_RPC
// request. It is called from the composite loop, so the seat answers while it
// holds the scanout cadence. Bounded per call so a flood cannot starve the tick
// loop. Returns how many requests were served.
func serviceRPC() int {
	var buf [vi.WmRpcMax]byte
	served := 0
	for i := 0; i < 8; i++ {
		n, r := vi.IpcRecv(buf[:])
		if r < 0 || n < 38 {
			return served
		}
		req, ok := vi.DecodeWmRpc(buf[:n])
		if !ok {
			continue
		}
		// An ack is never a request (the M56b reply flag).
		if req.Kind&vi.WmRpcReplyFlag != 0 {
			continue
		}
		applied := applyRPC(req)
		replyRPC(req, applied)
		served++
	}
	return served
}

// applyRPC performs one WM_RPC request with the kernel's own primitives and
// returns whether it was applied. Only the paths a tab-aware Zig app exercises
// are implemented; everything else is refused (applied=0) rather than faked.
func applyRPC(req vi.WmRpc) bool {
	id := uint32(req.ID)
	switch req.Kind & 0x7f {
	case vi.WmRpcKindDeclareFullscreen: // 8, the path lib/tabapp.zig uses
		if tabs.OpenTab(id, req.TitleString()) {
			noteStripOpen()
			vi.ConsoleLine(MarkerTabOpen + vi.Itoa64(int64(id)))
		}
		hostedApp = id
		hostTicksLeft = hostTicks
		// Focus and raise through the kernel's taskbar-click primitive, so the
		// app receives the real WIN_FOCUS. New declares take focus so two
		// clients leave exactly one focused tab (M62b).
		if vi.WmctlTaskbarClick(id) == 0 {
			_ = tabs.FocusTab(id)
			vi.ConsoleLine(MarkerHostFocus + vi.Itoa64(int64(id)))
			vi.ConsoleLine(MarkerTabFocus + vi.Itoa64(int64(id)))
		}
		// Propose the full viewport. The kernel clamps (WM proposes, kernel
		// clamps) and pushes WIN_RESIZE to the app, which relayouts.
		if vi.WmctlSetWindowRect(id, 0, 0, uint32(vi.ScanoutWidth), uint32(vi.ScanoutHeight)) == 0 {
			vi.ConsoleLine(MarkerHostView + vi.Itoa64(int64(id)))
		}
		vi.ConsoleLine(MarkerRpcDeclare + vi.Itoa64(int64(id)))
		return true
	case vi.WmRpcKindRaise: // 1
		if vi.WmctlTaskbarClick(id) == 0 {
			_ = tabs.FocusTab(id)
			vi.ConsoleLine(MarkerRpcRaise + vi.Itoa64(int64(id)))
			vi.ConsoleLine(MarkerTabFocus + vi.Itoa64(int64(id)))
			return true
		}
		return false
	case vi.WmRpcKindAttachTab: // 5
		if tabs.OpenTab(id, req.TitleString()) {
			noteStripOpen()
			vi.ConsoleLine(MarkerTabOpen + vi.Itoa64(int64(id)))
		}
		// Same host-state sync as declare: an attach-without-declare client
		// still lands on the strip with focus and the single-tab close budget.
		_ = tabs.FocusTab(id)
		hostedApp = id
		hostTicksLeft = hostTicks
		vi.ConsoleLine(MarkerRpcAttach + vi.Itoa64(int64(id)))
		return true
	case vi.WmRpcKindDetachTab: // 6
		_ = tabs.CloseTab(id)
		syncHostedFromStrip()
		vi.ConsoleLine(MarkerRpcDetach + vi.Itoa64(int64(id)))
		return true
	case vi.WmRpcKindCycleTab: // 7
		if nid, ok := tabs.NextID(); ok {
			if vi.WmctlTaskbarClick(nid) == 0 {
				_ = tabs.FocusTab(nid)
				vi.ConsoleLine(MarkerTabFocus + vi.Itoa64(int64(nid)))
			}
		}
		vi.ConsoleLine(MarkerRpcCycle)
		return true
	default:
		vi.ConsoleLine(MarkerRpcOther + vi.Itoa64(int64(req.Kind&0x7f)))
		return false
	}
}

// replyRPC acks one request to its requester. The frame mirrors the request's
// id/seq and carries the applied flag plus the reply bit, exactly like TABWM's
// wnd_mail_reply, so an unmodified app accepts it.
func replyRPC(req vi.WmRpc, applied bool) {
	// The title carries the nav-poll payload in TABWM; the paths this card
	// exercises carry none, so the ack's title stays zeroed (buildReply).
	if req.ReplyTo != 0 {
		_ = vi.IpcSend(uint32(req.ReplyTo), buildReply(req, applied).Encode())
	}
}

// buildReply is the pure half of replyRPC: the ack frame for one request. Split
// out so the host test pins the wire (reply bit, mirrored id/seq, applied flag)
// without a guest.
func buildReply(req vi.WmRpc, applied bool) vi.WmRpc {
	var rep vi.WmRpc
	rep.Kind = req.Kind | vi.WmRpcReplyFlag
	rep.ID = req.ID
	rep.Seq = req.Seq
	rep.ReplyTo = req.ReplyTo
	if applied {
		rep.Applied = 1
	}
	return rep
}

// closeHosted closes the focused tab's window through the WM seam; the app
// receives the real WIN_CLOSE and exits. Focus moves to the remaining tab
// (M62b) or the strip goes empty. Returns whether a close was issued.
func closeHosted() bool {
	id, ok := tabs.Focused()
	if !ok {
		if hostedApp == 0 {
			return false
		}
		id = hostedApp
	}
	if vi.WmctlWinClose(id) != 0 {
		return false
	}
	vi.ConsoleLine(MarkerHostClose + vi.Itoa64(int64(id)))
	vi.ConsoleLine(MarkerTabClose + vi.Itoa64(int64(id)))
	_ = tabs.CloseTab(id)
	syncHostedFromStrip()
	if nid, ok := tabs.Focused(); ok {
		// Closing one side of a split leaves a single tab: restore
		// full-viewport (Unsplit already ran in the two-tab choreography;
		// this covers a close while still split).
		if tabs.Count() == 1 {
			_ = applyRect(nid, FullRect(uint32(vi.ScanoutWidth), uint32(vi.ScanoutHeight)))
		}
		if vi.WmctlTaskbarClick(nid) == 0 {
			vi.ConsoleLine(MarkerTabFocus + vi.Itoa64(int64(nid)))
			vi.ConsoleLine(MarkerHostFocus + vi.Itoa64(int64(nid)))
		}
	} else {
		vi.ConsoleLine(MarkerTabsEmpty)
	}
	return true
}

func syncHostedFromStrip() {
	if id, ok := tabs.Focused(); ok {
		hostedApp = id
		return
	}
	hostedApp = 0
}

// noteStripOpen restarts close-handling when a tab lands on an empty strip.
// Without this, a late OpenTab after the single-tab path set stripDone would
// stay open until process exit (the gate-unreachable edge: a second declare
// more than hostTicks after the first). A second tab on an already-populated
// strip must not clear stripSawTwo — that latch is what keeps the two-tab
// close path from falling through to the single-tab countdown.
func noteStripOpen() {
	if tabs.Count() != 1 {
		return
	}
	stripDone = false
	stripSawTwo = false
	stripClosedOne = false
	stripStep = 0
}
