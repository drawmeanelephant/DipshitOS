// GOVIDNS.ELF — the M67a class-B fixture, DNS round trip (#1446).
//
// It resolves a NAME against the host DNS responder over the UDP seam
// (slots 9/10/11) through the vi surface (user/go/vi), then Dials the
// resolved literal, Sends a GET, and Recvs the pinned body over the
// kernel's TCP slots 30-33 — the live DNS + TCP round trip. (The pacing
// proof lives in the sibling runs: GONET's heartbeat-through-failed-read
// and GOVINET's heartbeat-through-refused-Dial.)
//
// It is a SEPARATE program from GONET.ELF on purpose: GONET sits within a
// few KiB of the kernel's fixed text gap (exec.zig), and this program's
// sibling fixture (GOVINET.ELF) covers the other M67a bars so no single
// binary outgrows the gap.
//
// The program prints deterministic markers and ends with 'gonet OK' on
// success; the go-net gate asserts the markers.
package main

import "virelai/vi"
import "virelai/vsys"

// die reports a failed stage and exits non-zero — one helper instead of a
// print pair per stage, to stay inside the fixed text gap.
func die(stage string, err error) {
	vsys.Print("govinet: vidns ")
	vsys.Print(stage)
	vsys.Print(" failed err=")
	vsys.Println(err.Error())
	vsys.Println("govinet: FAIL")
	vsys.Exit(1)
}

// ipText renders an IPv4 address as dotted quad for the markers.
func ipText(ip [4]byte) string {
	out := vsys.Itoa64(int64(ip[0]))
	out += "."
	out += vsys.Itoa64(int64(ip[1]))
	out += "."
	out += vsys.Itoa64(int64(ip[2]))
	out += "."
	out += vsys.Itoa64(int64(ip[3]))
	return out
}

func main() {
	vsys.Println("govinet: vidns start")

	ip, err := vi.ResolveDNS("myhost.local", vi.DefaultDNSServer, 0)
	if err != nil {
		die("resolve", err)
	}
	vsys.Println("govinet: vidns resolved myhost.local -> " + ipText(ip))

	// Dial the RESOLVED literal (not the name): the marker proves the
	// resolved address is what actually dials.
	conn, err := vi.Dial(ipText(ip), 8080)
	if err != nil {
		die("dial", err)
	}
	vsys.Println("govinet: vidns connected")

	n, err := conn.Send([]byte("GET / HTTP/1.0\r\nHost: myhost.local\r\n\r\n"))
	if err != nil {
		die("send", err)
	}
	vsys.Println("govinet: vidns sent n=" + vsys.Itoa64(int64(n)))

	// No explicit deadline: Recv's DefaultRecvBudgetNs (30 s) bounds a dark
	// peer — and every byte of text matters inside the kernel's fixed gap.
	total := 0
	buf := make([]byte, vi.TCPPayloadMax)
	for {
		n, err := conn.Recv(buf)
		if err != nil {
			die("recv", err)
		}
		total += n
		if n < vi.TCPPayloadMax {
			break
		}
	}
	vsys.Println("govinet: vidns body total=" + vsys.Itoa64(int64(total)))
	_ = conn.Close()

	vsys.Println("gonet OK")
	vsys.Exit(0)
}
