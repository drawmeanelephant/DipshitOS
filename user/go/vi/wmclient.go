package vi

// M56b (issue #1316): the tab-client WM_RPC wire + event dispatch. The frame
// is byte-identical to kernel/src/wnd_core.zig's `WmRpc` (mirrored in
// user/src/lib/ui/abi.zig): 38 bytes, little-endian, fitting the frozen
// 64-byte mailbox slot. A tab client never calls slot 65 (`wmctl`) — that
// seam is WM-only; an app asks the registered WM over the mailbox instead and
// polls its own inbox for the ack.
//
// The wire mirror is the integration drift guard: if it ever drifts from
// wnd_core, the WM's `wnd: mail` serve and the `wmrpc: *-ack` markers stop
// matching and the live gate fails. TestWmRpcWire pins it on the host.

const (
	// WmRpcTitleMax is the frame title width (wnd_core `wm_rpc_title_max`).
	WmRpcTitleMax = 24
	// WmRpcMax is the mailbox slot bound the frame must fit (wnd_core
	// `wm_rpc_max`).
	WmRpcMax = 64
	// WmRpcReplyFlag marks a WM ack frame (wnd_core `wm_rpc_reply_flag`).
	WmRpcReplyFlag uint8 = 0x80
)

// The frozen request kinds (wnd_core / abi.zig). Do not renumber.
const (
	WmRpcKindRaise             uint8 = 1
	WmRpcKindConfig            uint8 = 2
	WmRpcKindRegisterAction    uint8 = 3
	WmRpcKindInvokeAction      uint8 = 4
	WmRpcKindAttachTab         uint8 = 5
	WmRpcKindDetachTab         uint8 = 6
	WmRpcKindCycleTab          uint8 = 7
	WmRpcKindDeclareFullscreen uint8 = 8
	// Additive app-side nav kinds (user/src/lib/tabapp.zig): the WM routes
	// WM_RPC by mailbox without interpreting `kind`, so these need no
	// frozen-ABI change.
	WmRpcKindNavDeclare uint8 = 9
	WmRpcKindNavPoll    uint8 = 10
)

// WmRpc is the 38-byte app-to-WM mailbox frame. Field order and widths are the
// kernel's: kind@0, id@1, seq@2, reply_to@3, applied@4, pad@5, x@6, y@8,
// w@10, h@12, title[24]@14.
type WmRpc struct {
	Kind    uint8
	ID      uint8
	Seq     uint8
	ReplyTo uint8
	Applied uint8
	Pad     uint8
	X       uint16
	Y       uint16
	W       uint16
	H       uint16
	Title   [WmRpcTitleMax]byte
}

// Encode marshals the frame little-endian into a fresh 38-byte slice. Hand
// encoded (not an unsafe cast) so the byte layout is explicit and does not
// depend on the compiler's struct padding.
func (m WmRpc) Encode() []byte {
	b := make([]byte, 38)
	b[0] = m.Kind
	b[1] = m.ID
	b[2] = m.Seq
	b[3] = m.ReplyTo
	b[4] = m.Applied
	b[5] = m.Pad
	putU16(b[6:], m.X)
	putU16(b[8:], m.Y)
	putU16(b[10:], m.W)
	putU16(b[12:], m.H)
	copy(b[14:38], m.Title[:])
	return b
}

// DecodeWmRpc parses a frame from b, which must be at least 38 bytes.
func DecodeWmRpc(b []byte) (WmRpc, bool) {
	if len(b) < 38 {
		return WmRpc{}, false
	}
	var m WmRpc
	m.Kind = b[0]
	m.ID = b[1]
	m.Seq = b[2]
	m.ReplyTo = b[3]
	m.Applied = b[4]
	m.Pad = b[5]
	m.X = getU16(b[6:])
	m.Y = getU16(b[8:])
	m.W = getU16(b[10:])
	m.H = getU16(b[12:])
	copy(m.Title[:], b[14:38])
	return m, true
}

// SetTitle copies up to WmRpcTitleMax bytes of s into the frame's title,
// leaving the remainder NUL-padded.
func (m *WmRpc) SetTitle(s string) {
	for i := range m.Title {
		m.Title[i] = 0
	}
	n := len(s)
	if n > WmRpcTitleMax {
		n = WmRpcTitleMax
	}
	copy(m.Title[:n], s[:n])
}

// TitleString returns the frame's title with the NUL padding trimmed.
func (m WmRpc) TitleString() string {
	n := 0
	for n < len(m.Title) && m.Title[n] != 0 {
		n++
	}
	return string(m.Title[:n])
}

// wmMailWaitTicks bounds one WM_RPC ack wait. Each miss parks one scheduler
// tick (slot 4 sys_sleep; 1 s on VZ) so a silent seat cannot burn millions
// of yield-spins inside tabapp.Init (#1489). The first probe is immediate —
// a WM that has already replied never sleeps. Expiry is false (honest
// refusal; DeclareFullscreen callers already handle it).
const wmMailWaitTicks = 8

// waitWmRpcAck polls the caller's inbox for a matching WM_RPC ack. A silent
// mailbox parks between probes and returns (_, false) when the tick budget
// runs out; it never yield-spins.
func waitWmRpcAck(seq uint8) (WmRpc, bool) {
	var raw [WmRpcMax]byte
	for tick := uint64(0); tick < wmMailWaitTicks; tick++ {
		n, _ := IpcRecv(raw[:])
		if n >= 38 {
			rep, ok := DecodeWmRpc(raw[:n])
			if ok && rep.Kind&WmRpcReplyFlag != 0 && rep.Seq == seq {
				return rep, true
			}
		}
		if tick+1 >= wmMailWaitTicks {
			return WmRpc{}, false
		}
		_ = svc1(SlotSleep, 1)
	}
	return WmRpc{}, false
}

// WmMailRequest sends one WM_RPC request to the registered WM and polls the
// CALLER's own inbox for the matching ack. It returns whether the WM applied
// it. A missing WM seat or a bounded-poll timeout returns false (honest — the
// caller then falls back to the frozen syscall); recv reads the caller's own
// ring, so no self-pid is needed on the wire beyond `reply_to`.
func WmMailRequest(kind uint8, id uint32, x, y, w, h uint16, title, selfName string, seq uint8) bool {
	peers := WmPeers(selfName)
	if peers.WM == 0 || peers.Self == 0 {
		return false
	}
	req := WmRpc{
		Kind:    kind,
		ID:      uint8(id & 0xff),
		Seq:     seq,
		ReplyTo: uint8(peers.Self & 0xff),
		X:       x,
		Y:       y,
		W:       w,
		H:       h,
	}
	req.SetTitle(title)
	frame := req.Encode()
	if IpcSend(peers.WM, frame) < 0 {
		return false
	}
	rep, ok := waitWmRpcAck(req.Seq)
	if !ok {
		return false
	}
	return rep.Applied != 0
}

// DeclareFullscreen asks the WM to make this tab full-viewport eligible (kind
// 8). TABWM accepts; WND.BIN and the shim refuse and the app keeps its legacy
// size — the zero-regression path.
func DeclareFullscreen(winID uint32, title, selfName string) bool {
	return WmMailRequest(WmRpcKindDeclareFullscreen, winID, 0, 0, 0, 0, title, selfName, 1)
}

// DeclareNav tells the WM this tab navigated to path (kind 9) — the
// browser-history analogue for FILE/EDIT tabs.
func DeclareNav(winID uint32, path, selfName string) bool {
	if path == "" {
		return false
	}
	return WmMailRequest(WmRpcKindNavDeclare, winID, 0, 0, 0, 0, path, selfName, 6)
}

// PollNav asks the WM for a back/forward target the user picked on the rail
// (kind 10), returning the path when one is queued. Best-effort: a missing WM
// seat or no pending target returns ("", false).
func PollNav(winID uint32, selfName string) (string, bool) {
	peers := WmPeers(selfName)
	if peers.WM == 0 || peers.Self == 0 {
		return "", false
	}
	req := WmRpc{
		Kind:    WmRpcKindNavPoll,
		ID:      uint8(winID & 0xff),
		Seq:     7,
		ReplyTo: uint8(peers.Self & 0xff),
	}
	frame := req.Encode()
	if IpcSend(peers.WM, frame) < 0 {
		return "", false
	}
	rep, ok := waitWmRpcAck(req.Seq)
	if !ok || rep.Applied == 0 {
		return "", false
	}
	return rep.TitleString(), true
}

// WmAction is what a tab client's event dispatch decided to do.
type WmAction int

const (
	// WmActionNone: not a WM-lifecycle event (mouse/key/timer...).
	WmActionNone WmAction = iota
	// WmActionResized: the WM resized the canvas; relayout at (W, H).
	WmActionResized
	// WmActionClosed: the window closed; clean up and exit.
	WmActionClosed
)

// TabClient is the state the dispatch loop tracks: the window id and the
// CURRENT canvas size, which follows every WIN_RESIZE (the WM's SET_WINDOW
// seam). Apps lay out against these, never against compile-time constants,
// once tab-aware.
type TabClient struct {
	Win     uint32
	W       uint32
	H       uint32
	Focused bool
}

// NewTabClient returns a client for winID with the given initial canvas size.
func NewTabClient(winID, w, h uint32) *TabClient {
	return &TabClient{Win: winID, W: w, H: h}
}

// Dispatch classifies one WM-lifecycle event and tracks the canvas.
// WIN_RESIZE updates the tracked size and returns WmActionResized; WIN_CLOSE
// returns WmActionClosed; WIN_FOCUS/WIN_BLUR update the focus flag. Everything
// else is WmActionNone and stays the app's own business.
func (t *TabClient) Dispatch(ev Event) WmAction {
	switch ev.Kind {
	case EvWinClose:
		return WmActionClosed
	case EvWinResize:
		t.W = ev.Arg0
		t.H = ev.Arg1
		return WmActionResized
	case EvWinFocus:
		t.Focused = true
	case EvWinBlur:
		t.Focused = false
	}
	return WmActionNone
}
