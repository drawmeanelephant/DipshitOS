// GOOS=virelai argv proof (issue #1163 B2, phase 0b round 1).
//
// os is not ported until phase 2, so the fixture reads the argument vector
// through the runtime's VirelaiArgs accessor (function linkname — the same
// state os.Args will expose once os lands). Proves the whole chain: exec
// argv packing in the gap loader, the rt0 SysV conversion, args to
// argslice — end to end.
package main

import (
	_ "unsafe"
)

//go:linkname goargs runtime.VirelaiArgs
func goargs() []string

func main() {
	args := goargs()
	out := "go-args n=" + itoa(len(args))
	for _, a := range args {
		out += " [" + a + "]"
	}
	println(out)
}

// itoa: the fixture's only dependency-free positive-int formatter (one
// string keeps the serial assertion exact).
func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var buf [20]byte
	i := len(buf)
	for n > 0 {
		i--
		buf[i] = byte('0' + n%10)
		n /= 10
	}
	return string(buf[i:])
}
