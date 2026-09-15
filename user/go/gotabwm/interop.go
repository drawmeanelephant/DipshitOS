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
//	declare_fullscreen (8)      gotabwm: rpc declare id=<n>
//	                            gotabwm: host focus id=<n> (taskbar-click)
//	                            gotabwm: host view id=<n>  (full viewport)
//	raise (1)                   gotabwm: rpc raise id=<n>
//	attach (5) / detach (6)     gotabwm: rpc attach/detach id=<n>
//	cycle (7)                   gotabwm: rpc cycle
//	anything else               gotabwm: rpc other kind=<n>
//	after hostTicks ticks       gotabwm: host close id=<n> (WIN_CLOSE)
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

// hostedApp is the window id of the Zig app the seat is hosting (0 = none).
// While it is set the seat stops repainting the blank desktop: the kernel's own
// layer (the unmigrated Zig window and its chrome) is painted at the tick, and
// the compose-N target sits ABOVE it, so a full-frame blank paint would overpaint
// the client.
var hostedApp uint32

// hostTicks is how long the seat hosts an app before closing it - enough ticks
// for the app to declare, take the viewport and relayout.
const hostTicks = 3

// hostTicksLeft counts down while an app is hosted; the composite loop closes
// the app when it reaches zero.
var hostTicksLeft int

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
		hostedApp = id
		hostTicksLeft = hostTicks
		// Focus and raise through the kernel's taskbar-click primitive, so the
		// app receives the real WIN_FOCUS.
		if vi.WmctlTaskbarClick(id) == 0 {
			vi.ConsoleLine(MarkerHostFocus + vi.Itoa64(int64(id)))
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
			vi.ConsoleLine(MarkerRpcRaise + vi.Itoa64(int64(id)))
			return true
		}
		return false
	case vi.WmRpcKindAttachTab: // 5
		vi.ConsoleLine(MarkerRpcAttach + vi.Itoa64(int64(id)))
		return true
	case vi.WmRpcKindDetachTab: // 6
		vi.ConsoleLine(MarkerRpcDetach + vi.Itoa64(int64(id)))
		return true
	case vi.WmRpcKindCycleTab: // 7
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

// closeHosted closes the hosted app's window through the WM seam; the app
// receives the real WIN_CLOSE and exits. Returns whether a close was issued.
func closeHosted() bool {
	if hostedApp == 0 {
		return false
	}
	id := hostedApp
	hostedApp = 0
	if vi.WmctlWinClose(id) == 0 {
		vi.ConsoleLine(MarkerHostClose + vi.Itoa64(int64(id)))
		return true
	}
	return false
}
