//go:build virelai

package tea

import "github.com/charmbracelet/x/term"

// initInput mirrors tty_unix.go's shape without POSIX termios. VirelaiOS has no
// termios: the guest console arrives over the /dev/tty seam via the GOOS=virelai
// fork's os/syscall layer, so there is no terminal state to capture or restore.
func (p *Program) initInput() error {
	if f, ok := p.input.(term.File); ok && term.IsTerminal(f.Fd()) {
		p.ttyInput = f
	}
	if f, ok := p.output.(term.File); ok && term.IsTerminal(f.Fd()) {
		p.ttyOutput = f
	}
	return nil
}

const suspendSupported = false

func suspendProcess() {}
