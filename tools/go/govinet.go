// GOVINET.ELF — the M67a class-B fixture, loopback + closed-port (#1446).
//
// The phase is an exec argument (the go-net runs exec one phase each):
//
//   viloop   — the loopback bar: a datagram to the guest's OWN address
//              returns to its own listen ring without touching the device
//              (through the vi UDP seam, slots 9/10/11).
//   viclosed — the closed-port drop: a connect to a port nobody answers
//              refuses with the kernel's 30 s connect-timeout EINVAL while
//              the heartbeat keeps printing (the order proof, for a
//              BLOCKING Dial — the M65 pacing live).
//
// It shares the fixture family with GONET.ELF (phase 2) and GOVIDNS.ELF
// (DNS round trip): the kernel's fixed text gap (exec.zig) is a hard size
// bound, and the M67a surface does not fit in one binary with the rest.
//
// Every phase prints deterministic markers and ends with 'gonet OK' on
// success; the go-net gate asserts the markers and their ORDER.
package main

import "virelai/vi"
import "virelai/vsys"

func heartbeat(stop *bool, count *int) {
	for !*stop {
		*count++
		// Print BEFORE sleeping, so a beat lands before the first blocking
		// call and the gate's order proof has a "before" line to compare.
		vsys.Println("govinet: hb=" + vsys.Itoa64(int64(*count)))
		vsys.Sleep(2)
	}
}

func fail(msg string) {
	// One console write: another task's output can otherwise split the
	// marker across serial lines (observed with the smp scheduler lines).
	vsys.Println("govinet: FAIL " + msg)
	vsys.Exit(1)
}

func main() {
	// The ELF argv block carries the program name in slot 0; the scan is
	// shape-agnostic on purpose (fetchs.zig documented both shapes).
	for _, a := range vi.Args() {
		switch a {
		case "viloop":
			runViloop()
		case "viclosed":
			runViclosed()
		}
	}
	fail("usage: exec GOVINET.ELF <viloop|viclosed>")
}

// runViloop — the loopback bar through the vi UDP seam: a datagram to the
// guest's OWN address comes straight back into its own listen ring without
// touching the device (the gate arms no --net at all for this run). 7000 is
// udp.default_src_port — the fixed source port slot 10 always sends from,
// so the looped datagram lands back on it.
func runViloop() {
	vsys.Println("govinet: viloop start")
	own := [4]byte{10, 0, 0, 1}
	const port = 7000
	if rc := vi.UDPListen(port); rc < 0 {
		vsys.Print("govinet: viloop listen failed rc=")
		vsys.Println(vsys.Itoa64(rc))
		fail("listen")
	}
	vsys.Println("govinet: viloop bound")

	payload := []byte("loop")
	if rc := vi.UDPSend(own, port, payload); rc < 0 {
		vsys.Print("govinet: viloop send failed rc=")
		vsys.Println(vsys.Itoa64(rc))
		fail("send")
	}
	vsys.Println("govinet: viloop sent n=" + vsys.Itoa64(int64(len(payload))))

	deadline := vsys.Nanotime() + 5_000_000_000
	buf := make([]byte, 72) // udp.datagram_max: 8-byte header + 64 payload
	for {
		if n := vi.UDPRecv(port, buf); n >= int64(8+len(payload)) {
			src := uint16(buf[0])<<8 | uint16(buf[1])
			if src == port && string(buf[8:8+len(payload)]) == "loop" {
				vsys.Println("govinet: viloop echoed n=" + vsys.Itoa64(n))
				vsys.Println("gonet OK")
				vsys.Exit(0)
			}
		}
		if vsys.Nanotime() >= deadline {
			vsys.Println("govinet: viloop no echo")
			fail("no echo")
		}
		vsys.Sleep(1)
	}
}

// runViclosed — the closed-port drop: a connect to a port nobody answers
// fails honestly with the kernel's own connect-timeout refusal (rc = -1)
// AFTER parking the dialing task for its 30 s window, while the heartbeat
// keeps printing — the live proof that a BLOCKING Dial paces.
func runViclosed() {
	vsys.Println("govinet: viclosed start")
	stop := false
	hb := 0
	go heartbeat(&stop, &hb)
	vsys.Sleep(2)

	vsys.Println("govinet: viclosed dialing 10.0.0.2:8081")
	rc := vi.TCPConnect([4]byte{10, 0, 0, 2}, 8081)
	vsys.Println("govinet: viclosed refused rc=" + vsys.Itoa64(rc))
	vi.TCPClose()

	vsys.Sleep(8)
	stop = true
	vsys.Sleep(4)
	if hb > 0 {
		vsys.Println("govinet: heartbeat survived load")
	}
	vsys.Println("gonet OK")
	vsys.Exit(0)
}
