package vi

import "testing"

// snapWith builds a snapshot with the two fields the classifier reads.
func snapWith(ownIP [4]byte, arp []byte) NetStats {
	// arp is a flat list of [4]byte destinations, packed into the table.
	var s NetStats
	s.OwnIP = ownIP
	count := len(arp) / 4
	if count > 4 {
		count = 4
	}
	s.ARPCount = byte(count)
	for i := 0; i < count; i++ {
		copy(s.ARPIPs[i][:], arp[i*4:i*4+4])
	}
	return s
}

// TestClassifyNetOffline pins the first rung: no own IP is offline, device
// absent and unconfigured alike -- the classifier reads the snapshot, not
// the hardware.
func TestClassifyNetOffline(t *testing.T) {
	d := ClassifyNet(NetStats{}, [4]byte{10, 0, 0, 2})
	if d != NetOfflineNoIP {
		t.Fatalf("no own IP -> %d, want offline_no_ip", d)
	}
	// An ARP entry for the destination does not make an unconfigured
	// interface routable.
	s := snapWith([4]byte{}, []byte{10, 0, 0, 2})
	if d := ClassifyNet(s, [4]byte{10, 0, 0, 2}); d != NetOfflineNoIP {
		t.Fatalf("no own IP with an ARP entry -> %d, want offline_no_ip", d)
	}
}

// TestClassifyNetArpTable pins the ready/no-route split against the table
// and the own-IP loopback precedent.
func TestClassifyNetArpTable(t *testing.T) {
	s := snapWith([4]byte{10, 0, 0, 1}, []byte{10, 0, 0, 2})
	if d := ClassifyNet(s, [4]byte{10, 0, 0, 2}); d != NetReady {
		t.Fatalf("ARP-resolved destination -> %d, want ready", d)
	}
	if d := ClassifyNet(s, [4]byte{10, 0, 0, 99}); d != NetNoRoute {
		t.Fatalf("IP set, ARP miss -> %d, want no_route", d)
	}
	// The own address needs no ARP entry (UDP-loopback precedent).
	if d := ClassifyNet(s, [4]byte{10, 0, 0, 1}); d != NetReady {
		t.Fatalf("own IP -> %d, want ready", d)
	}
}

// TestClassifyNetIgnoresPaddingSlots guards the loop bound: arp_count above 4
// must not read past the four packed slots.
func TestClassifyNetIgnoresPaddingSlots(t *testing.T) {
	var s NetStats
	s.OwnIP = [4]byte{10, 0, 0, 1}
	s.ARPCount = 9 // out of range on purpose (the Zig test does the same)
	if d := ClassifyNet(s, [4]byte{1, 2, 3, 4}); d != NetNoRoute {
		t.Fatalf("arp_count=9 with an empty table -> %d, want no_route", d)
	}
}

// TestNetDiagnosisMessage pins the N14 strings live-net-offline.spec greps.
func TestNetDiagnosisMessage(t *testing.T) {
	got := NetDiagnosisMessage("ping", NetOfflineNoIP, [4]byte{10, 0, 0, 2})
	want := "ping: offline — no IP address (set one: net ip <a.b.c.d> or net dhcp)\n"
	if got != want {
		t.Fatalf("offline message = %q, want %q", got, want)
	}
	got = NetDiagnosisMessage("ping", NetNoRoute, [4]byte{10, 0, 0, 2})
	want = "ping: no route to 10.0.0.2 (resolve first: net arp <a.b.c.d>)\n"
	if got != want {
		t.Fatalf("no-route message = %q, want %q", got, want)
	}
}

// TestNetPreflightRefusalIsUnknown: a refused snapshot is NetUnknown, never a
// fabricated offline verdict.
func TestNetPreflightRefusalIsUnknown(t *testing.T) {
	installHook(t, func(num uintptr, a0, a1, a2, a3 uintptr) int64 { return 0 })
	if d, _ := NetPreflight([4]byte{10, 0, 0, 2}); d != NetUnknown {
		t.Fatalf("refused snapshot -> %d, want unknown", d)
	}
}

// TestFormatIPv4 pins the dotted-quad shape the messages embed.
func TestFormatIPv4(t *testing.T) {
	if got := FormatIPv4([4]byte{192, 168, 64, 5}); got != "192.168.64.5" {
		t.Fatalf("FormatIPv4 = %q", got)
	}
	if got := FormatIPv4([4]byte{}); got != "0.0.0.0" {
		t.Fatalf("FormatIPv4 zero = %q", got)
	}
}
