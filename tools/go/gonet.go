// GONET.ELF — the phase-2 class-B fixture (issue #1163).
//
// It exercises the fresh virelai syscall/os/net binding (user/go/vsys) the
// way an app would, and it is the on-target proof that a blocked read no
// longer wedges the program:
//
//  1. os.File path:    vsys.ReadFile("/host/GONET.SHARE")
//  2. net.Conn path:   vsys.Dial("10.0.0.2", <port>) -> Write(short GET) ->
//     Read(pinned body)
//  3. A SECOND goroutine keeps a serial heartbeat running the whole time.
//  4. When the peer goes away mid-read, the Read FAILS CLOSED (ErrPeerClosed)
//     while the heartbeat keeps printing — the exact behaviour the old
//     vi.TCPRecv-in-the-window-loop apps could not get.
//
// The program prints one deterministic marker per event; the go-net gate
// asserts their ORDER, which is what proves "the heartbeat continued while
// the read was failing".
//
// Port: the runner's deterministic TCP responder (--net-tcp-respond
// 10.0.0.2:<port>) answers the SYN, replies to a request with the pinned
// payload file, and FINs — the "peer dies" edge.
package main

import "virelai/vsys"

func heartbeat(stop *bool, count *int) {
	for !*stop {
		*count++
		// Print BEFORE sleeping, so a beat lands before the first blocking
		// read and the gate's order proof has a "before" line to compare.
		vsys.Print("gonet: hb=")
		vsys.Println(vsys.Itoa64(int64(*count)))
		vsys.Sleep(2)
	}
}

func main() {
	vsys.Println("gonet: start")

	// Clock proof (phase 2.1): the EL0 counter must read > 0 and never go
	// backwards. The gate asserts 'gonet: clock ok' and the ABSENCE of
	// 'gonet: clock DEAD', so a clock that silently reads 0 fails the gate
	// instead of quietly disabling every deadline.
	n0 := vsys.Nanotime()
	n1 := n0
	// One tick is ~42 ns at 24 MHz, so two back-to-back reads can legitimately
	// return the same value. Spin (bounded) until the counter ADVANCES: a
	// frozen counter would silently disable every wall-clock deadline, so it
	// must fail this gate rather than pass it.
	for i := 0; i < 200000 && n1 <= n0; i++ {
		n1 = vsys.Nanotime()
	}
	if n0 > 0 && n1 > n0 {
		vsys.Println("gonet: clock ok")
	} else {
		vsys.Print("gonet: clock DEAD n0=")
		vsys.Print(vsys.Itoa64(n0))
		vsys.Print(" n1=")
		vsys.Println(vsys.Itoa64(n1))
	}

	// 1. os.File path: read the host-share file to completion.
	body, err := vsys.ReadFile("/host/GONET.SHARE")
	if err != nil {
		vsys.Print("gonet: readfile failed err=")
		vsys.Println(err.Error())
	} else {
		vsys.Print("gonet: readfile n=")
		vsys.Println(vsys.Itoa64(int64(len(body))))
	}

	// 2. Two goroutines: the heartbeat must survive everything below.
	stop := false
	hb := 0
	go heartbeat(&stop, &hb)
	// Let the heartbeat take its first step BEFORE the load starts: the order
	// proof compares a heartbeat line against the fail-closed line, so at
	// least one beat must precede the first blocking read.
	vsys.Sleep(2)

	// 3. net.Conn path over slots 30-33.
	conn, err := vsys.Dial("10.0.0.2", 8080)
	if err != nil {
		vsys.Print("gonet: dial failed err=")
		vsys.Println(err.Error())
		stop = true
		vsys.Println("gonet: FAIL")
		vsys.Exit(1)
		return
	}
	vsys.Println("gonet: connected")

	req := "GET / HTTP/1.0\r\nHost: 10.0.0.2\r\n\r\n"
	if n, err := conn.Write([]byte(req)); err != nil {
		vsys.Print("gonet: write failed err=")
		vsys.Println(err.Error())
	} else {
		vsys.Print("gonet: wrote GET n=")
		vsys.Println(vsys.Itoa64(int64(n)))
	}

	// 4. Read the pinned body. The deadline makes a peer that goes dark
	//    (run 02 of the gate: SYN-ACK then silence) FAIL CLOSED instead of
	//    parking the goroutine forever.
	conn.SetReadDeadline(2_000_000_000) // 2 s
	total := 0
	for i := 0; i < 8; i++ {
		buf := make([]byte, vsys.TCPPayloadMax)
		n, err := conn.Read(buf)
		if err != nil {
			vsys.Print("gonet: read failed closed err=")
			vsys.Println(err.Error())
			break
		}
		total += n
		vsys.Print("gonet: body chunk n=")
		vsys.Println(vsys.Itoa64(int64(n)))
		if n < vsys.TCPPayloadMax {
			break
		}
	}
	vsys.Print("gonet: body total=")
	vsys.Println(vsys.Itoa64(int64(total)))

	// 5. The peer is gone; a further Read must fail closed, not hang and not
	//    spin the window loop.
	// The deadline set above is already in the past, so the wall-clock
	// check must fail this read on its FIRST probe (no wasted tick). The
	// elapsed count is printed as on-target evidence.
	goneStart := vsys.Nanotime()
	if _, err := conn.Read(make([]byte, 16)); err != nil {
		vsys.Print("gonet: peer gone err=")
		vsys.Println(err.Error())
	}
	vsys.Print("gonet: failclosed ms=")
	vsys.Println(vsys.Itoa64((vsys.Nanotime() - goneStart) / 1_000_000))
	_ = conn.Close()

	// 6. Close-then-Dial is the legal reconnect path; a second LIVE Dial is not.
	if c2, err := vsys.Dial("10.0.0.2", 8080); err == nil {
		vsys.Println("gonet: redial ok")
		_ = c2.Close()
	} else {
		vsys.Print("gonet: redial failed err=")
		vsys.Println(err.Error())
	}

	// 7. Let the heartbeat prove it is still alive, then stop it.
	vsys.Sleep(8)
	stop = true
	vsys.Sleep(4)
	if hb > 0 {
		vsys.Println("gonet: heartbeat survived load")
	}
	vsys.Println("gonet OK")
	vsys.Exit(0)
}
