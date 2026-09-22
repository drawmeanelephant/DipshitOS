package vi

// M71n (issue #1573): the Go binding for the M26 N1 ICMP syscall seam —
// slots 59 `sys_ping_send` and 60 `sys_ping_poll`.
//
// The kernel owns the semantics (kernel/src/syscall.zig handle_ping_send /
// handle_ping_poll); this file only marshals the argument word. It is the
// exact shape Zig's `ui.ping_send` / `ui.ping_poll` have, so GOPING.ELF
// speaks the same ICMP path the monitor's `net ping` does, and PING.BIN (the
// Zig predecessor this card retires) did.
//
// Off the guest the calls are -ENOSYS through the syscallHook seam, so the
// marshalling is host-testable without a NIC.

// PingSend sends one ICMP echo request to ip (dotted-quad order). The kernel
// resolves through ARP and refuses with EINVAL when there is no own IP, the
// peer is not in the ARP table, or the transport is not ready — the caller
// is expected to have run its offline/no-route preflight first.
func PingSend(ip [4]byte) error {
	word := uintptr(uint32(ip[0])<<24 | uint32(ip[1])<<16 | uint32(ip[2])<<8 | uint32(ip[3]))
	r := svc1(SlotPingSend, word)
	if r < 0 {
		return errno(-r)
	}
	return nil
}

// PingPoll drains RX and returns the last echo-reply sequence seen, or 0 when
// no reply has landed yet. 0 is a "nothing yet", not an error: the caller
// sends, then polls until the expected sequence appears.
func PingPoll() uint64 {
	r := svc0(SlotPingPoll)
	if r < 0 {
		return 0
	}
	return uint64(r)
}
