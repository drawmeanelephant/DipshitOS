//go:build virelai

package tea

// listenForResize: VirelaiOS delivers no SIGWINCH - the terminal window is a
// fixed TABWM geometry. The resize channel therefore only ever ends with the
// program context; geometry is supplied up front via tea.WithWindowSize.
func (p *Program) listenForResize(done chan struct{}) {
	defer close(done)
	<-p.ctx.Done()
}
