// Command term is the M58c (issue #1307) Go terminal front-end: a full-
// viewport tabapp window bound to the existing /dev/tty seam (ADR 0020
// selector 2). Zig TERM.BIN / SH.BIN stay in place. The kernel paints the
// tty grid into the bound window (A4) and feeds focused-window keys into
// the terminal input queue (A5) — this binary draws no pixels and does
// not port lib/tty.zig or lib/shell.zig.
//
// Shape, matching TERM.BIN's attach path:
//  1. tabapp.Init (win_open + kind-8 declare_fullscreen)
//  2. sys_file_open("/dev/tty")
//  3. sys_tty_attach(2, window_id)
//  4. write a prompt through the tty (the kernel-painted "shell" marker)
//  5. read typed bytes, echo them back through the tty, print a line marker
//  6. WIN_CLOSE -> detach, close
//
// Every marker below is printed only AFTER its syscall returned, so the
// go-term VZ gate's asserts can only pass if the app actually ran.
package main

import (
	"virelai/tabapp"
	"virelai/vi"
)

const (
	appName  = "GOTERM.ELF"
	appTitle = "Term"
	natW     = 512
	natH     = 384

	ttyPath = "/dev/tty"
	prompt  = "goterm> "

	markerOpen    = "goterm: open id="
	markerDeclare = "goterm: declare accepted"
	markerTty     = "goterm: tty"
	markerAttach  = "goterm: attached"
	markerPrompt  = "goterm: prompt"
	markerLine    = "goterm: line "
	markerClose   = "goterm: close"
	markerOK      = "goterm OK"
	markerOpenErr = "goterm: error open "
	markerTtyErr  = "goterm: no /dev/tty"
	markerAttErr  = "goterm: attach failed"
)

func main() {
	ta := tabapp.Init(tabapp.Config{
		Name:  appName,
		Title: appTitle,
		X:     32,
		Y:     32,
		W:     natW,
		H:     natH,
	})
	if ta == nil {
		vi.ConsoleLine(markerOpenErr + "-1")
		vi.Exit(1)
	}
	vi.ConsoleLine(markerOpen + vi.Itoa64(int64(ta.Win)))
	if ta.TabAware {
		vi.ConsoleLine(markerDeclare)
	} else {
		vi.ConsoleLine("goterm: declare refused")
	}

	h, rc := vi.FileOpen(ttyPath, vi.ModeRead|vi.ModeWrite)
	if rc < 0 {
		vi.ConsoleLine(markerTtyErr)
		ta.CloseAndExit(1)
	}
	fd := uint32(h)
	vi.ConsoleLine(markerTty)

	if r := vi.TtyAttachWindow(ta.Win); r != 0 {
		vi.FileClose(fd)
		vi.ConsoleLine(markerAttErr)
		ta.CloseAndExit(2)
	}
	vi.ConsoleLine(markerAttach)

	if _, wr := vi.FileWrite(fd, []byte(prompt)); wr >= 0 {
		vi.ConsoleLine(markerPrompt)
	}

	var line lineBuf
	var readBuf [64]byte
	for {
		n, _ := vi.FileRead(fd, readBuf[:])
		if n > 0 {
			chunk := readBuf[:n]
			_, _ = vi.FileWrite(fd, chunk)
			for i := 0; i < n; i++ {
				if s, ok := line.feed(chunk[i]); ok {
					vi.ConsoleLine(markerLine + s)
				}
			}
		}

		ev, r, ok := vi.PollEventRaw()
		if !ok {
			if r < 0 {
				shutdown(ta, fd, 1)
			}
			if n <= 0 {
				vi.Sleep(1)
			}
			continue
		}
		switch ta.Dispatch(ev) {
		case tabapp.ActionClosed:
			shutdown(ta, fd, 0)
		}
	}
}

func shutdown(ta *tabapp.TabApp, fd uint32, status int) {
	_ = vi.TtyAttach(vi.TtyDetach)
	vi.FileClose(fd)
	vi.ConsoleLine(markerClose)
	vi.ConsoleLine(markerOK)
	ta.CloseAndExit(status)
}

// lineBuf accumulates tty input until a line terminator. It is the only
// editing this app does — not a port of lib/tty.zig.
type lineBuf struct {
	buf [128]byte
	n   int
}

func (l *lineBuf) feed(b byte) (string, bool) {
	if b == '\n' || b == '\r' {
		s := string(l.buf[:l.n])
		l.n = 0
		return s, true
	}
	if l.n < len(l.buf) {
		l.buf[l.n] = b
		l.n++
	}
	return "", false
}
