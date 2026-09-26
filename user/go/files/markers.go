// Serial markers for the M74a (issue #1644) file manager. Every line is
// printed only AFTER the event it describes has happened (after the frame is
// painted for frame markers), so the go-fileman class-B gate's serial asserts
// can only pass when the app really ran. These shapes are test surface:
// listing_test.go pins them on the host.
package main

const (
	markerOpen      = "gofiles: open id="
	markerDeclare   = "gofiles: declare accepted"
	markerDeclareNo = "gofiles: declare refused"
	markerList      = "gofiles: list "
	markerEntry     = "gofiles: entry "
	markerFound     = "gofiles: found KNOWN.TXT"
	markerView      = "gofiles: view "
	markerPresent   = "gofiles: present"
	markerClose     = "gofiles: close"
	markerOK        = "gofiles OK"
	markerListErr   = "gofiles: list error "
	markerCd        = "gofiles: cd "
	// M79e (#1708): the WM_RPC nav seam. `nav declare` is this app
	// announcing where it navigated; `nav back` is the proof the round
	// trip closed — the seat handed back a path and this app acted on it.
	markerNavDeclare = "gofiles: nav declare "
	markerNavBack    = "gofiles: nav back to "

	markerAttach  = "gofiles: attached"
	markerPainted = "gofiles: painted"
	markerReady   = "gofiles: ready"
	markerRepaint = "gofiles: repainted"
	markerKey     = "gofiles: key "
	markerMouse   = "gofiles: mouse b="
	markerResized = "gofiles: resized "

	markerRenamed  = "gofiles: renamed "
	markerRenameNo = "gofiles: rename refused "
	markerDeleted  = "gofiles: deleted "
	markerDeleteNo = "gofiles: delete refused "
	markerClip     = "gofiles: clip "
	markerPasted   = "gofiles: pasted "
	markerPasteNo  = "gofiles: paste refused "
	// M79k (#1720): this app is the notify adopter. The seat owns the
	// toast; the app's own half is the round trip. `notify sent` follows
	// an accepted ack, `notify refused` an absent seat or a refused
	// request — the same declare accepted/refused pair this app already
	// uses, because a silent failure is a lie either way.
	markerNotify   = "gofiles: notify sent "
	markerNotifyNo = "gofiles: notify refused "

	// markerSettled is printed one yield after the rename frame has been
	// painted and its `gofiles: renamed …` marker flushed: the gate's close
	// script waits on it so the screenshot taken at the rename marker is
	// never raced by the window teardown.
	markerSettled = "gofiles: settled after rename"
)
