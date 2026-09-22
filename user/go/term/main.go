// Command term is the M58c (issue #1307) Go terminal front-end: a full-
// viewport tabapp window bound to the existing /dev/tty seam (ADR 0020
// selector 2). Zig TERM.BIN / SH.BIN stay in place. The kernel paints the
// tty grid into the bound window (A4) and feeds focused-window keys into
// the terminal input queue (A5) — this binary draws no pixels and does
// not port lib/tty.zig or lib/shell.zig.
//
// M73c (issue #1627): the stub's hand-rolled prompt/echo/lineBuf is gone.
// The window now hosts a REAL gosh session: virelai/shlib's editor and
// engine own the prompt, editing, line execution and history, exactly as
// GOSH does over selector 1/2/3. Sequence, matching the card:
//
//  1. tabapp.Init (win_open + kind-8 declare_fullscreen)
//  2. sys_file_open("/dev/tty")
//  3. sys_tty_attach(2, window_id)
//  4. startup block through the tty: the startup contract banner
//     (STARTUP.SH, PROFILE.SH — silent, no marker: nobody typed them),
//     the SETTINGS-driven prompt load, the history load, `goterm: ready`,
//     and the first prompt paint
//  5. key loop: editor.Feed / EvSubmit -> marker -> Shell.RunLine
//  6. WIN_CLOSE (or EOF / exit / monitor) -> detach, close
//
// The prompt comes from the shell's own loader (SETTINGS.TXT `prompt`,
// falling back to the gosh default), not a hand-written constant: this is
// the same shell GOSH runs, in a window.
//
// Every marker below is printed only AFTER its syscall returned, so the
// go-term VZ gate's asserts can only pass if the app actually ran.
package main

import (
	"strings"

	"virelai/shlib"
	"virelai/tabapp"
	"virelai/vi"
)

const (
	appName  = "GOTERM.ELF"
	appTitle = "Term"
	// M73d (#1628): the classic terminal rect — 640x400 at 64,48 is
	// 80 grid columns, exactly the kernel grid's default, so
	// syncWindowCols never reflows (Screen.reflow early-outs when
	// cols is unchanged). A narrower window (512) forced an 80->64
	// reflow of live history; observed 2026-09-22: the window kept
	// showing pre-clear rows after a typed line while the grid itself
	// had the fresh content — repaint gap that retired TERM.BIN
	// (always 640) never hit and every 512px tabapp client did.
	natW = 640
	natH = 400

	ttyPath = "/dev/tty"

	// The shell's own startup contract (same files, same caps as GOSH).
	defaultPrompt   = "gosh> "
	settingsPath    = "/host/SETTINGS.TXT"
	startupPath     = "/host/STARTUP.SH"
	profilePath     = "/host/PROFILE.SH"
	maxStartupBytes = 2048 // the startup contract's per-file cap
	ticksPerSecond  = 100  // the scheduler tick is ~10 ms (kernel timer @ ~100 Hz)
	ttyWriteMax     = 1024 // under the kernel's 2048-byte file-write stage cap

	markerOpen    = "goterm: open id="
	markerDeclare = "goterm: declare accepted"
	markerReady   = "goterm: ready"
	markerTty     = "goterm: tty"
	markerAttach  = "goterm: attached"
	markerPrompt  = "goterm: prompt"
	markerLine    = "goterm: line "
	// markerDone is printed AFTER Shell.RunLine returned, carrying the
	// engine's own status: it is go-term.spec's execution proof. In a
	// window the tty grid's bytes never reach serial (ADR 0020 selector 2
	// paints the window; only ConsoleLine lines are serial-observable), so
	// output text cannot vouch for execution -- but a status only the real
	// engine computes can: `cd /data` returns 0 only after host.Chdir
	// verified the directory, `cd /nosuchdir` returns nonzero.
	markerDone    = "goterm: done status="
	markerClose   = "goterm: close"
	markerOK      = "goterm OK"
	markerMonitor = "goterm: monitor"
	markerMonErr  = "goterm: monitor failed"
	markerOpenErr = "goterm: error open "
	markerTtyErr  = "goterm: no /dev/tty"
	markerAttErr  = "goterm: attach failed"
)

func main() {
	ta := tabapp.Init(tabapp.Config{
		Name:  appName,
		Title: appTitle,
		X:     64,
		Y:     48,
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
	runSession(ta, fd)
}

// runSession is the startup block + editor loop over the attached tty.
// The card's order, through the tty: banner (startup contract lines run
// by the engine, output painted by the kernel — they print no marker,
// because go-wm-hid asserts `goterm: line ` is ABSENT when nobody typed),
// prompt load, history load, ready, first prompt.
func runSession(ta *tabapp.TabApp, fd uint32) {
	hst := &termHost{fd: fd}
	hist := &shlib.History{}
	sh := shlib.NewShell(hst, hist)

	for _, ln := range startupLines() {
		_, act := sh.RunLine(ln)
		if act != shlib.ActionContinue {
			leave(ta, fd, sh, act)
		}
	}

	editor := shlib.NewEditor(loadPrompt(), hist)
	editor.Complete = completeFn(hst)

	// M69f1 (#1537): seed recall from the share AFTER the startup banner
	// and BEFORE the first prompt, so the startup lines never enter recall.
	sink := &shlib.HistorySink{}
	shlib.LoadHistory(hst, hist, sink)

	vi.ConsoleLine(markerReady)
	_, _ = vi.FileWrite(fd, editor.Repaint())
	vi.ConsoleLine(markerPrompt)

	// handle applies one editor outcome. Feed returns at most one event per
	// call and holds the remainder of its chunk, so the loop below keeps
	// feeding until the editor has nothing left: the kernel's input queue
	// can deliver several whole lines in a single read.
	handle := func(out []byte, ev shlib.EditEvent) {
		if len(out) > 0 {
			writeTTY(fd, out)
		}
		switch ev.Kind {
		case shlib.EvSubmit:
			vi.ConsoleLine(markerLine + ev.Line)
			shlib.SaveHistory(hst, hist, ev.Line, sink)
			st, act := sh.RunLine(ev.Line)
			// Only AFTER the engine answered: the gate sequences on this,
			// so it can never claim an execution that did not happen.
			vi.ConsoleLine(markerDone + vi.Itoa64(int64(st)))
			if act != shlib.ActionContinue {
				leave(ta, fd, sh, act)
			}
			// M73d (#1628): the editor's submit echo is a bare \r\n; the
			// fresh prompt is this post-execution write — the reference
			// shell loop's order (SH.BIN/TERM.BIN printed after running),
			// without which a screen-clearing command (`ESC[2J`) erased
			// the pre-painted prompt with nothing to repaint it:
			// observed 2026-09-22 the steady-state grid held RED/box/TC
			// rows but no prompt (fg=16 against the gate's threshold 20).
			// At the cursor, no CR — a CR repaint would overwrite the
			// truecolour row's cells (the M73h assert scans x64..79 of
			// grid row 2), where the shell loop's bare prompt lands at
			// x>=80 as the original gate observed.
			_, _ = vi.FileWrite(fd, []byte(loadPrompt()))
		case shlib.EvEOF:
			shutdown(ta, fd, 0)
		case shlib.EvCancel:
			// The editor already painted ^C and the fresh prompt.
		}
	}

	var readBuf [64]byte
	for {
		n, _ := vi.FileRead(fd, readBuf[:])
		if n > 0 {
			handle(editor.Feed(readBuf[:n]))
		}
		for editor.Pending() {
			handle(editor.Feed(nil))
		}

		sh.ReapJobs()

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

// leave ends the session for the line that asked to leave. The monitor
// handover is reported only AFTER the detach syscall returned, same
// contract as GOSH's `gosh: monitor` (live-sh-monitor sequences on GOSH's;
// no gate sequences on these, but the fact must still not be claimed
// before it happened).
func leave(ta *tabapp.TabApp, fd uint32, sh *shlib.Shell, act shlib.Action) {
	if act == shlib.ActionMonitor {
		if r := vi.TtyAttach(vi.TtyDetach); r == 0 {
			vi.ConsoleLine(markerMonitor)
		} else {
			vi.ConsoleLine(markerMonErr)
		}
	}
	shutdown(ta, fd, sh.Status())
}

func shutdown(ta *tabapp.TabApp, fd uint32, status int) {
	// Detach again when leave already did it for the monitor handover: the
	// kernel's selector 0 is idempotent (it just clears the front-end), so
	// the second call only keeps this the single exit path.
	_ = vi.TtyAttach(vi.TtyDetach)
	vi.FileClose(fd)
	vi.ConsoleLine(markerClose)
	vi.ConsoleLine(markerOK)
	ta.CloseAndExit(status)
}

func writeTTY(fd uint32, b []byte) {
	for len(b) > 0 {
		n := len(b)
		if n > ttyWriteMax {
			n = ttyWriteMax
		}
		if _, r := vi.FileWrite(fd, b[:n]); r < 0 {
			return
		}
		b = b[n:]
	}
}

// loadPrompt adopts the SETTINGS.TXT `prompt` key (SH.BIN's SH8 behavior,
// the same loader GOSH uses — the prompt is the shell's, not this
// front-end's).
func loadPrompt() string {
	b, r := vi.ReadFileAll(settingsPath, maxStartupBytes)
	if r < 0 {
		return defaultPrompt
	}
	return promptFromSettings(string(b), defaultPrompt)
}

// promptFromSettings is loadPrompt's pure parsing half (host-testable):
// the first `prompt=` key wins, its value is trimmed and separated from
// the line by one space; a missing or empty value falls back.
func promptFromSettings(body, def string) string {
	for _, line := range strings.Split(body, "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "prompt=") {
			if v := strings.TrimSpace(line[len("prompt="):]); v != "" {
				return v + " "
			}
		}
	}
	return def
}

// startupLines reads the startup contract files (CRLF-aware, bounded,
// silent when missing) and returns their non-empty lines in order.
func startupLines() []string {
	var out []string
	for _, path := range []string{startupPath, profilePath} {
		b, r := vi.ReadFileAll(path, maxStartupBytes)
		if r < 0 || len(b) == 0 {
			continue
		}
		out = append(out, startupLinesFrom(string(b))...)
	}
	return out
}

// startupLinesFrom is startupLines' pure parsing half (host-testable):
// CRLF and CR are folded to LF, blank lines dropped, order kept.
func startupLinesFrom(body string) []string {
	var out []string
	body = strings.ReplaceAll(body, "\r\n", "\n")
	for _, line := range strings.Split(body, "\n") {
		line = strings.TrimRight(line, "\r")
		if strings.TrimSpace(line) != "" {
			out = append(out, line)
		}
	}
	return out
}

// completeFn builds the Tab completer: the command word matches builtins
// and tools; every word also matches the share listing.
func completeFn(host *termHost) func(string, bool) []string {
	return func(word string, first bool) []string {
		var cands []string
		if first {
			for _, n := range append(append([]string{}, shlib.BuiltinNames()...), shlib.ToolNames()...) {
				if strings.HasPrefix(n, word) {
					cands = append(cands, n+" ")
				}
			}
		}
		seen := map[string]bool{}
		for _, n := range host.ListDir() {
			if !strings.HasPrefix(n, word) || seen[n] {
				continue
			}
			seen[n] = true
			cands = append(cands, n)
		}
		return cands
	}
}

// termHost is the Host seam for this windowed front-end: the same vi
// syscall surface as GOSH's goshHost, always bound to the attached tty
// (term has no headless and no serial presentation). It lives here, not
// in shlib, because shlib stays host-agnostic; a later card can share one
// seam between the two front-ends when the Touches allow touching both.
type termHost struct {
	fd uint32
}

func (g *termHost) Marker(line string) { vi.ConsoleLine(line) }

// Out writes command output to the attached tty; the kernel paints it
// into the window (ADR 0020 A4).
func (g *termHost) Out(b []byte) { writeTTY(g.fd, b) }

// candidateNames expands name the way SH.BIN's resolver did: bare, .ELF
// and .BIN suffixes, uppercase variants, in that order.
func candidateNames(name string) []string {
	up := strings.ToUpper(name)
	var out []string
	add := func(n string) {
		for _, e := range out {
			if e == n {
				return
			}
		}
		out = append(out, n)
	}
	for _, base := range []string{name, up} {
		add(base)
		add(base + ".ELF")
		add(base + ".BIN")
	}
	return out
}

func (g *termHost) RunExternal(name string, args []string) (int64, error) {
	for _, cand := range candidateNames(name) {
		if pid, err := vi.Exec(cand, args...); err == nil {
			return pid, nil
		}
	}
	return 0, shlib.ErrNotFound
}

func (g *termHost) WaitExternal(pid int64) (int64, error) { return vi.Wait(pid) }

func (g *termHost) ProbeExternal(pid int64) (int64, int) {
	st, state := vi.Probe(pid)
	return st, state
}

func (g *termHost) SleepTick() { vi.Sleep(1) }

func (g *termHost) PipeWrite(b []byte) error {
	_, err := vi.PipeWrite(b)
	return err
}

func (g *termHost) PipeReadAll() ([]byte, error) {
	var all []byte
	buf := make([]byte, 512)
	for len(all) < shlib.MaxPipeBytes {
		n, err := vi.PipeRead(buf)
		if err != nil {
			return all, err
		}
		if n == 0 {
			return all, nil
		}
		all = append(all, buf[:n]...)
	}
	return all, nil
}

func (g *termHost) ReadFile(path string, max int) ([]byte, error) {
	b, r := vi.ReadFileAll(path, max)
	if r < 0 {
		// Carry the kernel's own errno name: an ownership denial (EACCES)
		// and an absent file (ENOENT) are different facts, and the M50
		// trust gates assert which one the shell reported.
		if name := vi.ErrnoName(r); name != "" {
			return nil, shlib.NewOpenError(path, name)
		}
		return nil, shlib.ErrNotFound
	}
	return b, nil
}

// Principal is the caller's identity (slot 68) for `whoami`/`id`.
func (g *termHost) Principal() (uint32, uint32, bool) { return vi.Principal() }

// Chmod is the owner-only mode change (slot 69).
func (g *termHost) Chmod(path string, mode uint16) error {
	r := vi.FileMode(path, mode)
	if r < 0 {
		if name := vi.ErrnoName(r); name != "" {
			return shlib.NewOpenError(path, name)
		}
		return shlib.ErrNotFound
	}
	return nil
}

// SecretNames reads the caller's store entry NAMES (slot 70). The values are
// deliberately not carried through this seam.
func (g *termHost) SecretNames() ([]string, bool) {
	var recs [vi.SecretEntriesMax]vi.SecretRecord
	n, r := vi.SecretList(recs[:])
	if r < 0 {
		return nil, false
	}
	out := make([]string, 0, n)
	for i := 0; i < n; i++ {
		out = append(out, recs[i].KeyString())
	}
	return out, true
}

func (g *termHost) WriteFile(path string, b []byte, appendMode bool) error {
	flags := vi.ModeWrite | vi.ModeCreate
	if appendMode {
		flags |= vi.ModeAppend
	}
	h, r := vi.FileOpen(path, flags)
	if r < 0 {
		return shlib.ErrNotFound
	}
	defer vi.FileClose(uint32(h))
	written, r := vi.FileWriteAll(uint32(h), b)
	if r < 0 || written != len(b) {
		return shlib.ErrWriteFailed
	}
	return nil
}

func (g *termHost) Chdir(path string) error {
	var entries [1]vi.DirEntry
	if _, r := vi.DirList(path, entries[:]); r < 0 {
		// Carry the kernel's errno for the same reason ReadFile does: a
		// missing directory, a path that is a file, and an ownership denial
		// on the share's list gate are three different facts, and folding
		// them into one "not a directory" message hides two of them.
		if name := vi.ErrnoName(r); name != "" {
			return shlib.NewOpenError(path, name)
		}
		return shlib.ErrNotFound
	}
	return nil
}

func (g *termHost) ListDir() []string {
	var entries [vi.MaxDirEntries]vi.DirEntry
	n, r := vi.DirList("", entries[:])
	if r < 0 {
		return nil
	}
	out := make([]string, 0, n)
	for i := 0; i < n; i++ {
		if !entries[i].Dir() {
			out = append(out, entries[i].NameString())
		}
	}
	return out
}

func (g *termHost) ReadTTYLine() (string, bool) {
	var acc []byte
	buf := make([]byte, 32)
	for len(acc) < 256 {
		n, _ := vi.FileRead(g.fd, buf)
		if n == 0 {
			vi.Sleep(1)
			continue
		}
		for i := 0; i < n; i++ {
			if buf[i] == '\r' || buf[i] == '\n' {
				return string(acc), true
			}
			acc = append(acc, buf[i])
		}
	}
	return string(acc), true
}

func (g *termHost) SleepSeconds(n int) {
	vi.Sleep(uint64(n) * ticksPerSecond)
}
