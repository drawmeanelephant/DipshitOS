// Package main — GOTOP's network tab (the pure, host-testable half).
//
// TOP.BIN's N4 tab reported the device counters from `sys_net_stats` (slot 62)
// at 1 Hz; SYSMON's dashboard reported the interface and DHCP state. GOTOP
// keeps both in one view, because after M71g there is one app and two specs
// (live-n4-top-net) that assert the seam is really called. The counters here
// are bytes over the LAST interval, so the numbers mean "now", not "since boot".
package main

import "virelai/vi"

// NetView is the network-tab state.
type NetView struct {
	Stats vi.NetStats
	OK    bool
	// Rates are the deltas since the previous sample (bytes / interval).
	RXRate, TXRate uint64
	prevRX, prevTX uint64
	seen           bool
}

// NewNetView builds an empty view (Safe defaults: counters zero, no sample).
func NewNetView() *NetView { return &NetView{} }

// Refresh samples slot 62 and updates the byte-rate deltas. It returns false
// when the kernel refused (a short buffer / off the guest), in which case the
// previous view is kept — the caller does not paint a zeroed snapshot as if it
// were real.
func (v *NetView) Refresh() bool {
	s, ok := vi.NetStatsSnapshot()
	if !ok {
		return false
	}
	if v.seen {
		v.RXRate = rateDelta(v.prevRX, s.RXBytes)
		v.TXRate = rateDelta(v.prevTX, s.TXBytes)
	} else {
		v.RXRate, v.TXRate = 0, 0
	}
	v.prevRX, v.prevTX = s.RXBytes, s.TXBytes
	v.seen = true
	v.Stats = s
	v.OK = true
	return true
}

// rateDelta is one interval's delta: a counter that went backwards (a device
// reset) reports 0 rather than a huge bogus spike — the same rule top.zig's
// refresh_net_stats applies.
func rateDelta(prev, cur uint64) uint64 {
	if cur >= prev {
		return cur - prev
	}
	return 0
}

// Lines is the tab's text, one entry per row.
func (v *NetView) Lines() []string {
	if !v.OK {
		return []string{"net: no snapshot (slot 62 refused)"}
	}
	s := v.Stats
	out := []string{
		"iface mac=" + macString(s.MAC) + " ip=" + ipString(s.OwnIP) + " gw=" + ipString(s.Gateway),
		"dhcp " + dhcpName(s.DHCPState) + " lease=" + vi.Itoa64(int64(s.LeaseSecs)) + "s server=" + ipString(s.LeaseServer),
		"tcp " + tcpName(s.TCPState) + " peer=" + ipString(s.TCPPeerIP) + ":" + vi.Itoa64(int64(s.TCPPeerPort)),
		"udp listeners=" + vi.Itoa64(int64(s.UDPCount)) + " arp entries=" + vi.Itoa64(int64(s.ARPCount)),
		"",
		"rx " + vi.Itoa64(int64(s.RXBytes)) + " B in " + vi.Itoa64(int64(s.RXFrames)) + " frames",
		"tx " + vi.Itoa64(int64(s.TXBytes)) + " B in " + vi.Itoa64(int64(s.TXFrames)) + " frames",
		"rx/s " + vi.Itoa64(int64(v.RXRate)) + " B   tx/s " + vi.Itoa64(int64(v.TXRate)) + " B",
		"",
		"tcp segs syn=" + vi.Itoa64(int64(s.TCPSegs[0])) + " ack=" + vi.Itoa64(int64(s.TCPSegs[2])) +
			" data=" + vi.Itoa64(int64(s.TCPSegs[3])) + "/" + vi.Itoa64(int64(s.TCPSegs[4])),
		"udp dgrams rx=" + vi.Itoa64(int64(s.UDPDgrams[0])) + " tx=" + vi.Itoa64(int64(s.UDPDgrams[1])),
		"drop rx_filtered=" + vi.Itoa64(int64(s.RXFiltered)) + " overflow=" + vi.Itoa64(int64(s.RXOverflow)),
	}
	return out
}

// dhcpName mirrors the kernel's DhcpState naturals.
func dhcpName(state byte) string {
	switch state {
	case 1:
		return "selecting"
	case 2:
		return "requesting"
	case 3:
		return "bound"
	case 4:
		return "renewing"
	case 5:
		return "rebinding"
	}
	return "idle"
}

// tcpName mirrors the kernel's TcpState naturals.
func tcpName(state byte) string {
	switch state {
	case 1:
		return "SYN-SENT"
	case 2:
		return "ESTABLISHED"
	case 3:
		return "FIN-WAIT"
	case 4:
		return "CLOSED"
	}
	return "IDLE"
}

// ipString renders a raw network-order address (guest-safe: no fmt).
func ipString(ip [4]byte) string {
	return vi.Itoa64(int64(ip[0])) + "." + vi.Itoa64(int64(ip[1])) + "." +
		vi.Itoa64(int64(ip[2])) + "." + vi.Itoa64(int64(ip[3]))
}

// macString renders a raw MAC as two hex digits per byte.
func macString(mac [6]byte) string {
	const digits = "0123456789abcdef"
	out := ""
	for i, b := range mac {
		if i > 0 {
			out += ":"
		}
		out += string([]byte{digits[b>>4], digits[b&0xf]})
	}
	return out
}
