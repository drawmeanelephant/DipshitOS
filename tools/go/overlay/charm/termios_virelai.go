//go:build virelai

package tea

import "github.com/charmbracelet/x/term"

// Virelai has no host termios or job-control surface. The M72c app supplies
// its own bound /dev/tty bytes, so Bubble Tea's Program plumbing must not try
// to put a host file descriptor into raw mode.
func (p *Program) initInput() error {
	if f, ok := p.input.(term.File); ok {
		p.ttyInput = f
	}
	if f, ok := p.output.(term.File); ok {
		p.ttyOutput = f
	}
	return nil
}

func (*Program) checkOptimizedMovements(*term.State) {}

const suspendSupported = false

func suspendProcess() {}
