//go:build virelai

package tea

// There is no POSIX signal or terminal-resize stream in the guest. A bound
// tty's window lifecycle remains available through the Virelai event queue,
// which the M72c app polls directly.
func (*Program) listenForResize(done chan struct{}) {
	close(done)
}
