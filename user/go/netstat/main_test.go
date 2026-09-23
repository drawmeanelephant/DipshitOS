package main

import "testing"

func TestFormatting(t *testing.T) {
	if got := ipString([4]byte{192, 168, 64, 5}); got != "192.168.64.5" {
		t.Fatalf("ipString = %q", got)
	}
	if got := macString([6]byte{2, 0, 0, 0, 0, 2}); got != "02:00:00:00:00:02" {
		t.Fatalf("macString = %q", got)
	}
	for state, want := range map[byte]string{0: "idle", 1: "selecting", 2: "requesting", 3: "bound", 4: "renewing", 5: "rebinding", 9: "idle"} {
		if got := dhcpName(state); got != want {
			t.Errorf("dhcpName(%d) = %q, want %q", state, got, want)
		}
	}
	for state, want := range map[byte]string{0: "IDLE", 1: "SYN-SENT", 2: "ESTABLISHED", 3: "FIN-WAIT", 4: "CLOSED", 9: "IDLE"} {
		if got := tcpName(state); got != want {
			t.Errorf("tcpName(%d) = %q, want %q", state, got, want)
		}
	}
}
