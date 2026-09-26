// GOTABWM.ELF — M79k (issue #1720): the notify seam. An app that finishes a
// long operation or fails a save had nowhere to say so except serial output
// nobody is reading; kind 12 gives it a bounded toast strip on the scanout.
//
// Shape, and why each bound exists:
//
//   - WM_RPC kind 12 carries the message in the frame's 24-byte title — the
//     whole text budget (vi.Notify). No payload channel, no base64.
//   - The queue is NotifyMax deep and the OLDEST entry is dropped, never a
//     refusal: a flood of notifications must degrade to "the newest few",
//     not to a seat that stops answering. The drop is counted, so the
//     honesty marker can say it happened.
//   - Lifetime is in composite ticks, not wall time: compositeTick already
//     receives the tick count, and the seat's tick is the scheduler's 1 Hz
//     heartbeat. A toast is (born, expires) in ticks.
//   - The fade is a three-step colour ramp over the last notifyFadeTicks
//     ticks, NOT a hard cut and NOT alpha: fillRect writes an opaque
//     pixel (tabs.go), so blending would need machinery the seat does not
//     have. Three named Surface→Bg steps are a pixel-testable middle ground.
//   - Paint order: the toast strip is painted AFTER the launcher and after
//     chromeTick, so a notification fired by the app the user just launched
//     is never hidden by the launcher they are typing into. Pinned by
//     TestToastPaintsAboveLauncher.
//   - Geometry: the stack lives in the bottom-LEFT corner, so it clears the
//     22px top rail, the 148x20 bottom-right clock panel, and the centred
//     start surface. The stack grows UPWARD with age, newest nearest the
//     bottom edge.
//   - Click-to-focus uses focusHosted, the same helper alt-tab and rail
//     clicks use, so a toast is one more way to the same focus transition
//     (WIN_FOCUS to the sender) — not a private path.
//
// Non-goals (the card says so): a history centre, sounds, per-app
// permission gating. Dismissal is a timeout or a click; nothing else.
package main

import (
	"unsafe"

	"virelai/theme"
	"virelai/vi"
)

// The notify markers the class-B gate greps. Exported so notify_test.go pins
// the exact shapes, the way interop_test.go pins the other seat markers.
const (
	// MarkerNotify is printed AFTER the entry is queued, carrying the
	// sender tab id and the text as it was bounded onto the wire.
	MarkerNotify = "gotabwm: notify id="
	// MarkerNotifyDismiss is printed at the moment an entry leaves the
	// queue — expired by the tick clock or clicked through. `id=` is the
	// SENDER's tab id, the same name the queue and the focus path use,
	// never the queue slot.
	MarkerNotifyDismiss = "gotabwm: notify dismiss id="
	// MarkerNotifyDrop is printed when a full queue dropped its oldest
	// entry, so a truncated notification stream is never silent.
	MarkerNotifyDrop = "gotabwm: notify drop n="
	// MarkerNotifyPaint is printed ONCE, the first tick that actually put
	// a toast on the scanout and presented the frame. It is the third
	// point in the chain — queued (MarkerNotify), on screen
	// (MarkerNotifyPaint), gone (MarkerNotifyDismiss) — and it exists
	// because "the app asked and the seat acknowledged" says nothing about
	// whether the user ever SAW it. A gate needs a marker that lands after
	// the pixels are in the composed scanout, not after the request.
	MarkerNotifyPaint = "gotabwm: notify paint id="
)

// Notify geometry and lifetime. NotifyW fits the full 24-byte text budget
// at the 8px face advance (24*8 = 192) plus the 2px accent rule, the gaps
// and a right margin, so no bounded message is ever clipped by the panel.
const (
	NotifyMax       = 4           // queue depth; the oldest is dropped beyond it
	NotifyTicks     = 8           // lifetime in composite ticks (~8s at the 1Hz tick)
	notifyFadeTicks = 3           // ramp length: the last N ticks step toward Bg
	NotifyW         = 208         // panel width: 24 chars * 8 + rule + pads
	NotifyH         = ChromeH     // same band as the clock panel: 8px face + pads
	notifyGap       = 4           // vertical gap between stacked toasts
	notifyInset     = chromeInset // clears the capture frame, like the clock panel
	notifyRuleW     = 2           // the accent rule, one seat identity
	notifyTextPad   = 6           // text origin past the panel's left edge
)

// notifyToast is one queued notification. tabID is the SENDER (the window
// the request carried), and it is what a click focuses — not a slot index.
type notifyToast struct {
	tabID   uint32
	text    string
	born    uint64
	expires uint64
}

// notifyQueue is the seat's toast strip: oldest first, so the newest is
// last and paints nearest the bottom edge. Bounded by NotifyMax.
var notifyQueue []notifyToast

// notifyDropped counts entries the bound threw away.
var notifyDropped int

// notifyPainted guards the one-shot MarkerNotifyPaint (the chromeTick
// one-shot discipline, for the same reason: the gate greps the transition,
// not a per-tick flood).
var notifyPainted bool

// notifyPush queues one notification for tabID at tick `ticks` and returns
// the text as it was bounded onto the wire (NUL-trimmed at 24 bytes by the
// frame title) plus whether an older entry was dropped to make room.
// Refuses an empty text before it can paint an empty panel.
func notifyPush(tabID uint32, text string, ticks uint64) (string, bool, bool) {
	if text == "" {
		return "", false, false
	}
	dropped := false
	if len(notifyQueue) >= NotifyMax {
		notifyQueue = notifyQueue[1:]
		notifyDropped++
		dropped = true
	}
	notifyQueue = append(notifyQueue, notifyToast{
		tabID:   tabID,
		text:    text,
		born:    ticks,
		expires: ticks + NotifyTicks,
	})
	return text, true, dropped
}

// notifyCount is the queue depth (the test surface for the bound).
func notifyCount() int { return len(notifyQueue) }

// clearNotify drops every toast raised by tab id, printing the dismiss
// marker for each. A toast for a tab that no longer exists is a dead entry:
// clicking it can never focus anything, and leaving it on screen is a claim
// the seat cannot keep. Called from TabStrip.CloseTab, the one choke point
// every close path (HID, RPC detach, choreography) funnels through — the
// same place clearPendingNav drops a dead tab's navigation target.
//
// The marker is printed HERE, not at the call site, for the same reason
// notifyTick prints it: the toast is off the scanout the instant the entry
// leaves the queue, and a caller that could forget (or forget again) would
// make a vanished toast silent. The entry is gone from the queue before the
// line is printed, so the marker can never claim a toast that is still up.
func clearNotify(id uint32) int {
	keep := notifyQueue[:0]
	gone := 0
	for _, t := range notifyQueue {
		if t.tabID == id {
			gone++
			continue
		}
		keep = append(keep, t)
	}
	notifyQueue = keep
	for i := 0; i < gone; i++ {
		vi.ConsoleLine(MarkerNotifyDismiss + vi.Itoa64(int64(id)))
	}
	return gone
}

// notifyExpire drops every entry whose lifetime has run out and reports the
// tab ids it dropped, so the caller can print the dismiss marker at the
// moment the toast actually left the screen. Expiry is a strict `ticks >=
// expires`: an entry born at tick T is visible on the tick that queued it
// and for exactly NotifyTicks-1 more, and is gone on the NotifyTicks-th.
func notifyExpire(ticks uint64) []uint32 {
	var gone []uint32
	keep := notifyQueue[:0]
	for _, t := range notifyQueue {
		if ticks >= t.expires {
			gone = append(gone, t.tabID)
			continue
		}
		keep = append(keep, t)
	}
	notifyQueue = keep
	return gone
}

// notifyRect is the panel rect for slot i, where slot 0 is the TOP of the
// stack (the OLDEST entry) and slot n-1 is nearest the bottom edge (the
// newest). The queue is stored oldest-first, so slot i draws notifyQueue[i]:
// a new toast appears at the bottom and pushes the older ones up, which is
// where the eye already is after reading the newest. Pure — the host test
// pins the hit zone against exactly this function, so the painted panel and
// the clickable panel can never disagree. A scanout too small for the panel
// gives up with the zero rect (paint nothing, click nothing) rather than a
// negative rect.
func notifyRect(width, height, i int) (x, y, w, h int) {
	if i < 0 || width <= 0 || height <= 0 || NotifyH <= 0 {
		return 0, 0, 0, 0
	}
	w, h = NotifyW, NotifyH
	if width < w+2*notifyInset {
		w = width - 2*notifyInset
	}
	if w <= 0 {
		return 0, 0, 0, 0
	}
	// Slot i is i panels above the bottom one, each NotifyH tall with a
	// notifyGap between neighbours.
	y = height - notifyInset - (i+1)*NotifyH - i*notifyGap
	if y < 0 {
		return 0, 0, 0, 0
	}
	return notifyInset, y, w, h
}

// notifySlotOf maps a scanout point to the queue index it lands on. It
// walks the same notifyRect the paint walks, so a hit can only ever be
// reported where a panel was actually drawn. Slot and queue index are the
// same number, which is why this is a straight lookup and not a remap.
func notifySlotOf(px, py uint32, width, height, n int) (int, bool) {
	for slot := 0; slot < n; slot++ {
		x, y, w, h := notifyRect(width, height, slot)
		if w <= 0 || h <= 0 {
			continue
		}
		if int(px) >= x && int(px) < x+w && int(py) >= y && int(py) < y+h {
			return slot, true
		}
	}
	return 0, false
}

// notifyRamp is the fade: how much of the way from Surface toward Bg the
// panel fill is at `remaining` ticks before expiry. Zero (the untouched
// panel) above the ramp, then 1/3, 2/3, 3/3 in the final notifyFadeTicks
// — the last step being the desktop colour, which is why a toast that has
// run out is visually already gone one tick before it is dropped. Pure, and
// the exact three step values are pinned by the host test.
func notifyRamp(remaining uint64) uint32 {
	if remaining == 0 || remaining > uint64(notifyFadeTicks) {
		return 0
	}
	return uint32(notifyFadeTicks - remaining + 1)
}

// mixRGB blends a toward b by num/den in each 8-bit channel (integer, no
// float, no rounding drift). Tokens only (M69c): the caller passes theme
// values, never a hex literal.
//
// The per-channel math is SIGNED on purpose: the ramp runs from a lighter
// Surface toward a darker Bg, so `a - b` underflows if the channels are
// subtracted as uint32 and every dark target came out wrong (caught by
// TestNotifyFadeRampHasThreeExactSteps, which mixes 0x112233 toward
// 0xaabbcc — a case where a < b on every channel). Clamping is the
// rounding guard for the one case integer division can leave a channel a
// step outside 0..255.
func mixRGB(a, b uint32, num, den uint32) uint32 {
	if den == 0 {
		return a
	}
	out := uint32(0)
	for sh := uint(0); sh < 24; sh += 8 {
		ca := int32((a >> sh) & 0xff)
		cb := int32((b >> sh) & 0xff)
		c := ca - (ca-cb)*int32(num)/int32(den)
		if c < 0 {
			c = 0
		}
		if c > 255 {
			c = 255
		}
		out |= uint32(c) << sh
	}
	return out
}

// notifyFill is the panel's background colour at `remaining` ticks before
// expiry: plain Surface while the toast is fresh, then the ramp toward Bg.
func notifyFill(tok theme.Tokens, remaining uint64) uint32 {
	step := notifyRamp(remaining)
	if step == 0 {
		return tok.Surface
	}
	return mixRGB(tok.Surface, tok.Bg, step, uint32(notifyFadeTicks))
}

// notifyRule is the accent rule's colour, faded with the panel. A rule that
// stayed full-brightness over a Bg-coloured panel would be a bright blue
// line floating on the desktop, which is exactly the "not gone yet" read we
// do not want.
func notifyRule(tok theme.Tokens, remaining uint64) uint32 {
	step := notifyRamp(remaining)
	if step == 0 {
		return tok.Accent
	}
	return mixRGB(tok.Accent, tok.Bg, step, uint32(notifyFadeTicks))
}

// notifyText is the message colour, faded the same way (Ink toward Bg).
func notifyText(tok theme.Tokens, remaining uint64) uint32 {
	step := notifyRamp(remaining)
	if step == 0 {
		return tok.Ink
	}
	return mixRGB(tok.Ink, tok.Bg, step, uint32(notifyFadeTicks))
}

// paintNotify paints the whole strip and returns the pixel count written.
// Pure: it edits the caller's scanout slice and touches nothing else, the
// contract paintChrome and paintStartSurface already hold and the host test
// pins. `ticks` selects the ramp step for every entry.
func paintNotify(scan []byte, width, height int, ticks uint64) int {
	if width <= 0 || height <= 0 || len(scan) < 4 || len(notifyQueue) == 0 {
		return 0
	}
	pixN := len(scan) / 4
	pix := unsafe.Slice((*uint32)(unsafe.Pointer(&scan[0])), pixN)
	maxH := pixN / width
	if maxH <= 0 {
		return 0
	}
	tok := theme.Current
	written := 0
	n := len(notifyQueue)
	for slot := 0; slot < n; slot++ {
		// Slot i draws queue entry i: the queue is oldest-first and the
		// stack grows upward, so the newest lands nearest the bottom.
		e := notifyQueue[slot]
		x, y, w, h := notifyRect(width, height, slot)
		if w <= 0 || h <= 0 {
			continue
		}
		remaining := e.expires - ticks
		written += fillRect(pix, width, maxH, x, y, w, h, notifyFill(tok, remaining))
		step := notifyRamp(remaining)
		written += fillRect(pix, width, maxH, x, y, w, tok.BorderW,
			mixRGB(tok.Border, tok.Bg, step, uint32(notifyFadeTicks)))
		written += fillRect(pix, width, maxH, x, y, notifyRuleW, h, notifyRule(tok, remaining))
		written += drawText8(pix, width, maxH, x+notifyTextPad, y+chromePad,
			e.text, notifyText(tok, remaining))
	}
	return written
}

// notifyPaintMarker returns the marker line for the first painted toast and
// whether the caller should print it. One-shot per process: the toast is
// painted on every tick of its life, and a gate wants to know it reached
// the scanout, not how many frames it covered. `painted` is false on an
// empty strip (nothing was drawn, so there is nothing to claim) and on
// every tick after the first.
func notifyPaintMarker(painted bool) (string, bool) {
	if !painted || notifyPainted || len(notifyQueue) == 0 {
		return "", false
	}
	notifyPainted = true
	// The NEWEST entry's sender: the one the user is being told about.
	return MarkerNotifyPaint + vi.Itoa64(int64(notifyQueue[len(notifyQueue)-1].tabID)), true
}

// notifyHit reports the queue index under a scanout point, or false. It is
// the click-to-focus entry point and shares notifyRect with the paint.
func notifyHit(px, py uint32, width, height int) (int, bool) {
	if len(notifyQueue) == 0 {
		return 0, false
	}
	return notifySlotOf(px, py, width, height, len(notifyQueue))
}

// notifyDismissByIndex removes the entry at queue index i (a click) and
// returns its tab id — the id the dismiss marker and focus path both use.
func notifyDismissByIndex(i int) (uint32, bool) {
	if i < 0 || i >= len(notifyQueue) {
		return 0, false
	}
	id := notifyQueue[i].tabID
	notifyQueue = append(notifyQueue[:i], notifyQueue[i+1:]...)
	return id, true
}

// notifyTick is the per-composite-tick half: expire first (so a toast that
// has run out is not painted for one more frame), then print the dismiss
// markers for whatever left. Expiry is the ONLY thing this half can drop —
// a click goes through notifyClicked from the pointer path.
func notifyTick(ticks uint64) {
	for _, id := range notifyExpire(ticks) {
		vi.ConsoleLine(MarkerNotifyDismiss + vi.Itoa64(int64(id)))
	}
}

// notifyClicked is the click-to-focus action: the toast under the pointer
// is dismissed and its SENDER is focused through the same focusHosted seam
// alt-tab and rail clicks use, so the app receives the real WIN_FOCUS and
// the dismiss marker names the same id the notify marker did.
//
// It returns how many toasts it dismissed, and the caller consumes the
// PRESS on a hit REGARDLESS of that number's being non-zero — consumption
// is decided by the hit test, not by the work succeeding. Making the
// pointer path depend on the focus leg would mean a press whose focus
// request the kernel refuses falls through to the content forward, arming
// a content drag inside a hosted pane on a click that was aimed at a toast
// (found by TestHandleWmPointerPressOnToastIsChrome, where the host's
// -ENOSYS taskbar seam makes the focus leg fail by construction).
func notifyClicked(px, py uint32) int {
	i, ok := notifyHit(px, py, vi.ScanoutWidth, vi.ScanoutHeight)
	if !ok {
		return 0
	}
	id, ok := notifyDismissByIndex(i)
	if !ok {
		return 0
	}
	// The marker comes first: the toast IS gone at this point, whatever
	// the kernel says about focusing a window that may have died.
	vi.ConsoleLine(MarkerNotifyDismiss + vi.Itoa64(int64(id)))
	if !focusHosted(id) {
		return 1
	}
	vi.ConsoleLine(MarkerTabFocus + vi.Itoa64(int64(id)))
	vi.ConsoleLine(MarkerHostFocus + vi.Itoa64(int64(id)))
	return 1
}
