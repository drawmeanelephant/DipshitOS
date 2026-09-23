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

	// markerSettled is printed one yield after the rename frame has been
	// painted and its `gofiles: renamed …` marker flushed: the gate's close
	// script waits on it so the screenshot taken at the rename marker is
	// never raced by the window teardown.
	markerSettled = "gofiles: settled after rename"
)
