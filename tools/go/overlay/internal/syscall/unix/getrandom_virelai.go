// GetRandom for GOOS=virelai.
//
// crypto/internal/sysrand's rand_getrandom.go is the std random source for
// this GOOS, and it calls unix.GetRandom — which the stock Linux file
// implements with a raw `syscall.Syscall(SYS_GETRANDOM, ...)` and a per-arch
// trap number this GOOS has neither of. The port already reaches the
// kernel's random slot through `syscall.Getrandom` (ADR 0007 slot 72, the
// same one the guest SDK uses for key material), so this is a forward, not a
// stub: `crypto/rand` in the guest draws from the kernel's own generator.
//
// flags is accepted and ignored: the slot has one mode (blocking fill), and
// there is no GRND_NONBLOCK/GRND_INSECURE distinction to honour.
package unix

import "syscall"

func GetRandom(p []byte, flags uint32) (n int, err error) {
	return syscall.Getrandom(p)
}
