package main

import (
	"strings"
	"testing"
	"unsafe"

	"virelai/vi"
)

// fakeNetStats installs a slot-62 hook serving one mutable snapshot.
func fakeNetStats(t *testing.T, snap *vi.NetStats) {
	t.Helper()
	prev := vi.SetSyscallHookForTest(func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
		if num != vi.SlotNetStats {
			t.Fatalf("unexpected slot %d", num)
		}
		if a1 != vi.NetStatsBytes {
			t.Fatalf("buffer %d bytes, want %d", a1, vi.NetStatsBytes)
		}
		buf := unsafe.Slice((*byte)(unsafe.Pointer(a0)), a1)
		// Marshal through the same field set the kernel fills.
		copy(buf[0:6], snap.MAC[:])
		copy(buf[6:10], snap.OwnIP[:])
		copy(buf[10:14], snap.Gateway[:])
		buf[14] = snap.DHCPState
		copy(buf[15:19], snap.LeaseIP[:])
		copy(buf[20:24], snap.LeaseMask[:])
		copy(buf[24:28], snap.LeaseServer[:])
		putU32(buf[28:], snap.LeaseSecs)
		buf[32] = snap.TCPState
		copy(buf[33:37], snap.TCPPeerIP[:])
		putU16(buf[38:], snap.TCPPeerPort)
		buf[40] = snap.UDPCount
		for i := 0; i < 4; i++ {
			putU16(buf[42+2*i:], snap.UDPPorts[i])
		}
		buf[50] = snap.ARPCount
		putU64(buf[96:], snap.TXFrames)
		putU64(buf[104:], snap.TXBytes)
		putU64(buf[112:], snap.RXFrames)
		putU64(buf[120:], snap.RXBytes)
		putU64(buf[128:], snap.RXFiltered)
		putU64(buf[136:], snap.RXOverflow)
		for i := 0; i < 8; i++ {
			putU64(buf[144+8*i:], snap.TCPSegs[i])
		}
		for i := 0; i < 4; i++ {
			putU64(buf[208+8*i:], snap.UDPDgrams[i])
		}
		return int64(vi.NetStatsBytes)
	})
	t.Cleanup(func() { vi.SetSyscallHookForTest(prev) })
}

func putU16(b []byte, v uint16) {
	b[0] = byte(v)
	b[1] = byte(v >> 8)
}

func putU32(b []byte, v uint32) {
	b[0] = byte(v)
	b[1] = byte(v >> 8)
	b[2] = byte(v >> 16)
	b[3] = byte(v >> 24)
}

// TestRateDeltaRejectsBackwardsCounters pins the device-reset rule: a counter
// that went backwards reports 0, not a 2^64 spike.
func TestRateDeltaRejectsBackwardsCounters(t *testing.T) {
	if got := rateDelta(100, 250); got != 150 {
		t.Fatalf("delta = %d, want 150", got)
	}
	if got := rateDelta(250, 100); got != 0 {
		t.Fatalf("backwards delta = %d, want 0", got)
	}
	if got := rateDelta(7, 7); got != 0 {
		t.Fatalf("flat delta = %d, want 0", got)
	}
}

// TestFirstSampleHasNoRate pins that the first snapshot cannot invent a rate
// from the counters since boot.
func TestFirstSampleHasNoRate(t *testing.T) {
	snap := vi.NetStats{RXBytes: 4096, TXBytes: 1024}
	fakeNetStats(t, &snap)
	v := NewNetView()
	if !v.Refresh() {
		t.Fatal("first sample refused")
	}
	if v.RXRate != 0 || v.TXRate != 0 {
		t.Fatalf("first-sample rates = %d/%d, want 0/0", v.RXRate, v.TXRate)
	}
}

// TestSecondSampleReportsTheIntervalDelta is the 1 Hz behaviour the tab exists
// for: bytes over the last interval, per direction.
func TestSecondSampleReportsTheIntervalDelta(t *testing.T) {
	snap := vi.NetStats{RXBytes: 4096, TXBytes: 1024}
	fakeNetStats(t, &snap)
	v := NewNetView()
	v.Refresh()
	snap.RXBytes += 512
	snap.TXBytes += 64
	v.Refresh()
	if v.RXRate != 512 || v.TXRate != 64 {
		t.Fatalf("rates = %d/%d, want 512/64", v.RXRate, v.TXRate)
	}
	if !v.OK {
		t.Fatal("view must be OK after a successful sample")
	}
}

// TestLinesRenderTheSnapshot pins the text the tab paints, including the
// interface/DHCP/TCP fields SYSMON used to own.
func TestLinesRenderTheSnapshot(t *testing.T) {
	snap := vi.NetStats{
		MAC:       [6]byte{0x52, 0x54, 0x00, 0x12, 0x34, 0x56},
		OwnIP:     [4]byte{10, 0, 0, 1},
		Gateway:   [4]byte{10, 0, 0, 254},
		DHCPState: 3,
		LeaseSecs: 3600,
		TCPState:  2,
		RXBytes:   44,
		RXFrames:  33,
		TXBytes:   22,
		TXFrames:  11,
	}
	fakeNetStats(t, &snap)
	v := NewNetView()
	v.Refresh()
	text := strings.Join(v.Lines(), "\n")
	for _, want := range []string{
		"iface mac=52:54:00:12:34:56 ip=10.0.0.1 gw=10.0.0.254",
		"dhcp bound lease=3600s",
		"tcp ESTABLISHED peer=0.0.0.0:0",
		"rx 44 B in 33 frames",
		"tx 22 B in 11 frames",
	} {
		if !strings.Contains(text, want) {
			t.Fatalf("lines missing %q:\n%s", want, text)
		}
	}
}

// TestRefusedSnapshotIsVisible pins that a refusal says so instead of painting
// a plausible-looking zeroed interface.
func TestRefusedSnapshotIsVisible(t *testing.T) {
	vi.SetSyscallHookForTest(func(num uintptr, a0, a1, a2, a3 uintptr) int64 { return 0 })
	t.Cleanup(func() { vi.SetSyscallHookForTest(nil) })
	v := NewNetView()
	if v.Refresh() {
		t.Fatal("a 0 return must be a refusal")
	}
	if v.OK {
		t.Fatal("view must not be OK after a refusal")
	}
	if !strings.Contains(v.Lines()[0], "no snapshot") {
		t.Fatalf("refusal line = %q", v.Lines()[0])
	}
}

// TestStateNameHelpers mirror the kernel's enum naturals.
func TestStateNameHelpers(t *testing.T) {
	if dhcpName(3) != "bound" || dhcpName(0) != "idle" {
		t.Fatal("dhcp names drifted")
	}
	if tcpName(2) != "ESTABLISHED" || tcpName(4) != "CLOSED" || tcpName(0) != "IDLE" {
		t.Fatal("tcp names drifted")
	}
	if ipString([4]byte{192, 168, 1, 20}) != "192.168.1.20" {
		t.Fatal("ipString drifted")
	}
	if macString([6]byte{0x02, 0x0a, 0x0b, 0x0c, 0x0d, 0xef}) != "02:0a:0b:0c:0d:ef" {
		t.Fatal("macString drifted")
	}
}
