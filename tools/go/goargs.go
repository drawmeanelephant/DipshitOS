// GOOS=virelai argv + envp proof (issue #1163 B2, issue #1226 envp half).
//
// os is not ported until phase 2, so the fixture reads the argument and
// environment vectors through the runtime's VirelaiArgs / VirelaiEnvs
// accessors (function linknames — the same state os.Args / os.Environ
// will expose once os lands). Proves the whole chain: exec argv+envp
// packing in the gap loader, the rt0 SysV conversion, args/envs slices,
// and the GOMAXPROCS env override — end to end.
package main

import (
	_ "unsafe"

	"runtime"
)

//go:linkname goargs runtime.VirelaiArgs
func goargs() []string

//go:linkname goenvs runtime.VirelaiEnvs
func goenvs() []string

func main() {
	args := goargs()
	out := "go-args n=" + itoa(len(args))
	for _, a := range args {
		out += " [" + a + "]"
	}
	println(out)

	envs := goenvs()
	eout := "go-args env n=" + itoa(len(envs))
	for _, e := range envs {
		eout += " [" + e + "]"
	}
	println(eout)
	println("go-args procs=" + itoa(runtime.GOMAXPROCS(0)))
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
