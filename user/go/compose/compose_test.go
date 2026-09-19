package main

import "testing"

// The gate greps these exact strings; a drift is a host-test failure rather
// than a live run that silently asserts nothing.
func TestComposeMarkerShapes(t *testing.T) {
	cases := []struct{ got, want string }{
		{markerPasted, "compose: pasted n="},
		{markerCopied, "compose: copied n="},
		{markerArmed, "compose: armed blink"},
		{markerBlink, "compose: blink"},
		{markerDone, "compose: done"},
		{markerExiting, "compose: exiting "},
		{markerPasteFail, "compose: paste failed (clipboard empty)"},
		{markerCopyFail, "compose: copy failed rc="},
		{markerArmFail, "compose: timer arm failed rc="},
	}
	for _, c := range cases {
		if c.got != c.want {
			t.Fatalf("marker = %q want %q", c.got, c.want)
		}
	}
}

// The exact arithmetic the live gate's `40 sys_timer_set calls=7` rides: one arm
// before the loop plus one re-arm per toggle. If the cadence constant moves, the
// gate's number has to move with it — so the number is pinned here, next to the
// constant, instead of only in the spec.
func TestTimerSetCallCount(t *testing.T) {
	if got := 1 + blinkToggles; got != 7 {
		t.Fatalf("1 + blinkToggles = %d want 7 (the gate's assert)", got)
	}
	if blinkIntervalTicks != 8 {
		t.Fatalf("blinkIntervalTicks = %d want 8 (the M14 S3 cadence)", blinkIntervalTicks)
	}
}

// A red boot's `exited status=` has to identify the step on its own: distinct,
// non-zero statuses, with the historical completion status kept.
func TestExitStatuses(t *testing.T) {
	if exitOK != 43 {
		t.Fatalf("exitOK = %d want 43 (the Zig selfdemo's completion status)", exitOK)
	}
	seen := map[int]string{}
	all := []struct {
		name string
		st   int
	}{
		{"exitOK", exitOK},
		{"exitPasteFail", exitPasteFail},
		{"exitCopyFail", exitCopyFail},
		{"exitArmFail", exitArmFail},
		{"exitPollFail", exitPollFail},
	}
	for _, c := range all {
		if c.st <= 0 {
			t.Fatalf("%s = %d, want a non-zero status", c.name, c.st)
		}
		if prev, dup := seen[c.st]; dup {
			t.Fatalf("%s and %s share status %d", prev, c.name, c.st)
		}
		seen[c.st] = c.name
	}
}
