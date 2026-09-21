package vi

import (
	"testing"
	"unsafe"
)

// TestNetStatsLayoutMatchesKernelAndZig pins the SAME offsets and size that
// kernel/src/syscall.zig's NetStats doc and user/src/lib/netstats.zig's host
// test pin. A Go-side field reorder that silently shifts a counter would
// otherwise turn a dashboard into fiction.
func TestNetStatsLayoutMatchesKernelAndZig(t *testing.T) {
	got, want := netStatsLayout(), netStatsWanted()
	if got != want {
		t.Fatalf("layout drift:\n got  %+v\n want %+v", got, want)
	}
	if unsafe.Sizeof(NetStats{}) != NetStatsBytes {
		t.Fatalf("NetStats is %d bytes, want %d", unsafe.Sizeof(NetStats{}), NetStatsBytes)
	}
}

// emitNetStats writes a synthetic slot-62 snapshot: the counters carry their
// index so a mis-offset decode cannot pass by coincidence.
func emitNetStats() []byte {
	b := make([]byte, NetStatsBytes)
	copy(b[0:6], []byte{0x52, 0x54, 0x00, 0x12, 0x34, 0x56})
	copy(b[6:10], []byte{10, 0, 0, 1})
	copy(b[10:14], []byte{10, 0, 0, 254})
	b[14] = 3 // dhcp bound
	copy(b[15:19], []byte{10, 0, 0, 1})
	copy(b[20:24], []byte{255, 255, 255, 0})
	putU32(b[28:], 3600)
	b[32] = 2 // tcp established
	copy(b[33:37], []byte{10, 0, 0, 9})
	putU16(b[38:], 8080)
	b[40] = 2
	putU16(b[42:], 53)
	putU16(b[44:], 67)
	// counters: each distinct so a shifted read shows up
	putU64(b[96:], 11)
	putU64(b[104:], 22)
	putU64(b[112:], 33)
	putU64(b[120:], 44)
	putU64(b[128:], 55)
	putU64(b[136:], 66)
	for i := 0; i < 8; i++ {
		putU64(b[144+8*i:], uint64(100+i))
	}
	for i := 0; i < 4; i++ {
		putU64(b[208+8*i:], uint64(200+i))
	}
	return b
}

// TestNetStatsDecode exercises the single decode site against a synthesised
// snapshot: every field read back is the one written at that offset.
func TestNetStatsDecode(t *testing.T) {
	s := decodeNetStats(emitNetStats())
	if s.DHCPState != 3 || s.LeaseSecs != 3600 {
		t.Fatalf("dhcp decode: state=%d secs=%d", s.DHCPState, s.LeaseSecs)
	}
	if s.TCPState != 2 || s.TCPPeerPort != 8080 {
		t.Fatalf("tcp decode: state=%d port=%d", s.TCPState, s.TCPPeerPort)
	}
	if s.UDPCount != 2 || s.UDPPorts[0] != 53 || s.UDPPorts[1] != 67 {
		t.Fatalf("udp decode: n=%d ports=%v", s.UDPCount, s.UDPPorts)
	}
	if s.TXFrames != 11 || s.TXBytes != 22 || s.RXFrames != 33 || s.RXBytes != 44 ||
		s.RXFiltered != 55 || s.RXOverflow != 66 {
		t.Fatalf("counter decode: %+v", s)
	}
	if s.TCPSegs[0] != 100 || s.TCPSegs[7] != 107 || s.UDPDgrams[3] != 203 {
		t.Fatalf("vector decode: segs0=%d segs7=%d dgrams3=%d", s.TCPSegs[0], s.TCPSegs[7], s.UDPDgrams[3])
	}
	if s.OwnIP != [4]byte{10, 0, 0, 1} || s.Gateway != [4]byte{10, 0, 0, 254} {
		t.Fatalf("interface decode: ip=%v gw=%v", s.OwnIP, s.Gateway)
	}
	if s.MAC != [6]byte{0x52, 0x54, 0x00, 0x12, 0x34, 0x56} {
		t.Fatalf("mac decode: %v", s.MAC)
	}
}

// TestNetStatsSnapshotContract pins the kernel's two return shapes: the full
// size means "copied, decode it", anything else (0 for a short buffer, a
// negative errno, or -ENOSYS off the guest) means "keep the previous view".
func TestNetStatsSnapshotContract(t *testing.T) {
	installHook(t, func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
		if num != SlotNetStats {
			t.Fatalf("unexpected slot %d", num)
		}
		if a1 != NetStatsBytes {
			t.Fatalf("buffer size %d, want %d", a1, NetStatsBytes)
		}
		buf := unsafe.Slice((*byte)(unsafe.Pointer(a0)), a1)
		copy(buf, emitNetStats())
		return int64(NetStatsBytes)
	})
	s, ok := NetStatsSnapshot()
	if !ok || s.RXBytes != 44 {
		t.Fatalf("snapshot ok=%v rx=%d", ok, s.RXBytes)
	}
	installHook(t, func(num uintptr, a0, a1, a2, a3 uintptr) int64 { return 0 })
	if _, ok := NetStatsSnapshot(); ok {
		t.Fatal("a 0 return (short buffer) must report not-ok")
	}
	installHook(t, func(num uintptr, a0, a1, a2, a3 uintptr) int64 { return -ErrENOSYS })
	if _, ok := NetStatsSnapshot(); ok {
		t.Fatal("ENOSYS must report not-ok")
	}
}
