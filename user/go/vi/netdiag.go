package vi

// M71n (issue #1573): the Go twin of user/src/lib/netstatus.zig — the N13/N14
// offline/no-route preflight. PING.BIN (Zig) and FETCH.BIN (Zig) got their
// verdict from that file; GOPING.ELF is a Go program, so it needs the same
// classifier on its side of the boundary, and this is it.
//
// The classification itself is pure (a snapshot in, a verdict out), which is
// what makes it host-testable: only NetPreflight touches the kernel, with one
// sys_net_stats snapshot. The message shapes are byte-identical to the Zig
// originals because live-net-offline.spec greps them.

import "virelai/vsys"

// NetDiagnosis is the preflight verdict, named as the Zig enum is.
type NetDiagnosis int

const (
	// NetUnknown is "the kernel refused the snapshot" — never a guess.
	NetUnknown NetDiagnosis = iota
	// NetOfflineNoIP means no own IP is configured (device absent and
	// unconfigured look the same on the wire, and both are offline).
	NetOfflineNoIP
	// NetNoRoute means an own IP exists but the destination is not in the
	// ARP table (and is not the own address).
	NetNoRoute
	// NetReady means the destination is ARP-resolvable (or is the own IP,
	// the UDP-loopback precedent: no ARP entry is needed).
	NetReady
)

// ClassifyNet admits or diagnoses one snapshot against a destination IP.
// Pure. The order matters and mirrors netstatus.zig::classify: no own IP
// first, then own-IP loopback, then the ARP table.
func ClassifyNet(snap NetStats, dest [4]byte) NetDiagnosis {
	if snap.OwnIP == [4]byte{} {
		return NetOfflineNoIP
	}
	if dest == snap.OwnIP {
		return NetReady
	}
	for i := 0; i < int(snap.ARPCount) && i < 4; i++ {
		if snap.ARPIPs[i] == dest {
			return NetReady
		}
	}
	return NetNoRoute
}

// NetPreflight fetches one snapshot and classifies it. It is the only
// impure function here. A refused snapshot (short buffer, or -ENOSYS off the
// guest) is NetUnknown, never a fabricated verdict.
func NetPreflight(dest [4]byte) (NetDiagnosis, NetStats) {
	snap, ok := NetStatsSnapshot()
	if !ok {
		return NetUnknown, NetStats{}
	}
	return ClassifyNet(snap, dest), snap
}

// FormatIPv4 renders a dotted quad (the stdlib strconv/net is not ported to
// this GOOS). Pure.
func FormatIPv4(ip [4]byte) string {
	buf := make([]byte, 0, 16)
	for i, o := range ip {
		if i > 0 {
			buf = append(buf, '.')
		}
		buf = append(buf, vsys.Itoa64(int64(o))...)
	}
	return string(buf)
}

// NetDiagnosisMessage renders the N14 one-liner for a verdict, with prog as
// the prefix ("ping", "fetch") — byte-for-byte the Zig format_message shape,
// including the em dash. NetReady/NetUnknown are never printed through this
// by a caller that checked first; they still get an honest sentence.
func NetDiagnosisMessage(prog string, d NetDiagnosis, dest [4]byte) string {
	switch d {
	case NetOfflineNoIP:
		return prog + ": offline — no IP address (set one: net ip <a.b.c.d> or net dhcp)\n"
	case NetNoRoute:
		return prog + ": no route to " + FormatIPv4(dest) + " (resolve first: net arp <a.b.c.d>)\n"
	case NetReady:
		return prog + ": network ready\n"
	default:
		return prog + ": network status unavailable\n"
	}
}
