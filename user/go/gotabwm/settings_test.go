package main

import "testing"

// ---------------------------------------------------------------------------
// M66b (#1444) / M71f (#1565): the seat's settings MARKERS
//
// The schema-v2 codec itself moved to virelai/settings (settings_test.go
// there), because the Go settings panel GOSET.ELF reads and writes the same
// file through it. What stays here is what the seat owns: the gate grep
// targets, which no other consumer may rename silently.
// ---------------------------------------------------------------------------

// The seat's markers are gate grep targets: the corrupt line names itself,
// the good line carries the decoded seat.
func TestSettingsMarkerShapes(t *testing.T) {
	if MarkerSettingsBad != "gotabwm: settings bad" {
		t.Fatalf("bad marker = %q", MarkerSettingsBad)
	}
	if MarkerSettingsWM != "gotabwm: settings wm=" {
		t.Fatalf("wm marker = %q", MarkerSettingsWM)
	}
	if MarkerTokens != "gotabwm: tokens " {
		t.Fatalf("tokens marker = %q", MarkerTokens)
	}
}
