// Command sh is GOSH — the M68a (issue #1449) Go shell: the M49 daily-use
// bar (exec, line editing, history, jobs/fg, and the pipes / redirection /
// env / variables scripting subset) running as a full-viewport tabapp on
// the /dev/tty seam, the same presentation TERM.BIN used for the Zig shell
// core ("a different front-end owner over the same core").
//
// Shape, matching GOTERM's attach path:
//  1. tabapp.Init (win_open + kind-8 declare_fullscreen)
//  2. sys_file_open("/dev/tty")
//  3. sys_tty_attach(2, window_id)
//  4. the startup contract: /host/STARTUP.SH then /host/PROFILE.SH,
//     silent when missing, then the first prompt
//  5. typed bytes go through the editor; submitted lines run through the
//     shell engine; children exec on the M64b-fixed slot-28 seam
//  6. WIN_CLOSE / `monitor` / Ctrl-D -> detach, close
//
// Every marker is printed in a single console write (SMP-heartbeat safe)
// and only AFTER its syscall returned, so the class-B gate's asserts can
// only pass if the shell actually ran. `GOSH.ELF -c LINE` runs one line
// headless (no window, no tty, no startup) and exits with its status —
// the composable child form the gate and scripts use.
package main

import (
	"strings"

	"virelai/tabapp"
	"virelai/vi"
)

const (
	appName  = "GOSH.ELF"
	appTitle = "Sh"
	natW     = 512
	natH     = 384

	ttyPath         = "/dev/tty"
	defaultPrompt   = "gosh> "
	settingsPath    = "/host/SETTINGS.TXT"
	startupPath     = "/host/STARTUP.SH"
	profilePath     = "/host/PROFILE.SH"
	maxStartupBytes = 2048 // the startup contract's per-file cap
	ticksPerSecond  = 100  // the scheduler tick is ~10 ms (kernel timer @ ~100 Hz)
	ttyWriteMax     = 1024 // under the kernel's 2048-byte file-write stage cap

	markerReady    = "gosh: ready"
	markerOpen     = "gosh: open id="
	markerDeclare  = "gosh: declare accepted"
	markerTty      = "gosh: tty"
	markerAttach   = "gosh: attached"
	markerPrompt   = "gosh: prompt"
	markerLine     = "gosh: line "
	markerClose    = "gosh: close"
	markerOK       = "gosh OK"
	markerOpenErr  = "gosh: error open "
	markerTtyErr   = "gosh: no /dev/tty"
	markerAttachEr = "gosh: attach failed"
)

func main() {
	if line, headless := headlessLine(vi.Args()); headless {
		runHeadless(line)
		return
	}
	runTab()
}

// argvEnvpGuard pads the writable segment's bss so its end keeps at least
// 0x908 bytes of distance to the segment's page end. The kernel packs the
// argv+envp block (256 + 2048 bytes) into the image tail and extends the
// data aperture's mmap-collision bound through it (kernel/src/process.zig
// mmap_collides, issue #1214) — and the GOOS=virelai sbrk break starts at
// memRound(moduledata.end), so a bss end that lands inside that bound
// refuses the runtime's very first mmap and kills mallocinit before main
// runs (observed on this exact binary: `runtime: cannot allocate memory`
// during mheap.init). The build script asserts the invariant from the
// linked ELF; adjust this array's size when it trips.
var argvEnvpGuard [0x9b0]byte

func init() {
	// A store with a runtime-computed value keeps the pad in the bss (the
	// linker dead-codes an unreferenced, constant-folded package var).
	argvEnvpGuard[len(argvEnvpGuard)-1] = byte(len(argvEnvpGuard) & 0xff)
}

// headlessLine recognizes the `-c LINE` child form. argv[0] is the program
// name when the spawner supplied one, so check both positions.
func headlessLine(args []string) (string, bool) {
	if len(args) >= 2 && args[0] == "-c" {
		return args[1], true
	}
	if len(args) >= 3 && args[1] == "-c" {
		return args[2], true
	}
	return "", false
}

// runHeadless executes one line with console output and exits with its
// status. No window, no tty attach, no startup scripts.
func runHeadless(line string) {
	h := &goshHost{}
	sh := NewShell(h, &History{})
	st, _ := sh.RunLine(line)
	h.flushOut()
	vi.Exit(st)
}

// runTab is the window presentation: tabapp + /dev/tty + editor loop.
func runTab() {
	vi.ConsoleLine(markerReady)
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
		vi.ConsoleLine("gosh: declare refused")
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
		vi.ConsoleLine(markerAttachEr)
		ta.CloseAndExit(2)
	}
	vi.ConsoleLine(markerAttach)

	hist := &History{}
	host := &goshHost{fd: fd}
	sh := NewShell(host, hist)
	editor := NewEditor(loadPrompt(), hist)
	editor.Complete = completeFn(host)

	// The startup contract (M49 SD2): STARTUP.SH, then PROFILE.SH, silent
	// when either is missing, every line through the same engine.
	for _, ln := range startupLines() {
		vi.ConsoleLine(markerLine + ln)
		_, act := sh.RunLine(ln)
		if act != actionContinue {
			shutdown(ta, fd, sh.Status())
		}
	}

	_, _ = vi.FileWrite(fd, editor.Repaint())
	vi.ConsoleLine(markerPrompt)

	var readBuf [64]byte
	for {
		n, _ := vi.FileRead(fd, readBuf[:])
		if n > 0 {
			out, ev := editor.Feed(readBuf[:n])
			if len(out) > 0 {
				writeTTY(fd, out)
			}
			switch ev.Kind {
			case evSubmit:
				vi.ConsoleLine(markerLine + ev.Line)
				_, act := sh.RunLine(ev.Line)
				if act != actionContinue {
					shutdown(ta, fd, sh.Status())
				}
			case evEOF:
				shutdown(ta, fd, 0)
			case evCancel:
				// The editor already painted ^C and the fresh prompt.
			}
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

func shutdown(ta *tabapp.TabApp, fd uint32, status int) {
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

// loadPrompt adopts the SETTINGS.TXT `prompt` key (SH.BIN's SH8 behavior).
func loadPrompt() string {
	b, r := vi.ReadFileAll(settingsPath, maxStartupBytes)
	if r < 0 || len(b) == 0 {
		return defaultPrompt
	}
	for _, line := range strings.Split(string(b), "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "prompt=") {
			if v := strings.TrimSpace(line[len("prompt="):]); v != "" {
				return v + " "
			}
		}
	}
	return defaultPrompt
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
		body := strings.ReplaceAll(string(b), "\r\n", "\n")
		for _, line := range strings.Split(body, "\n") {
			line = strings.TrimRight(line, "\r")
			if strings.TrimSpace(line) != "" {
				out = append(out, line)
			}
		}
	}
	return out
}

// completeFn builds the Tab completer: the command word matches builtins
// and tools; every word also matches the share listing.
func completeFn(host *goshHost) func(string, bool) []string {
	return func(word string, first bool) []string {
		var cands []string
		if first {
			for _, n := range append(append([]string{}, builtinNames()...), toolNames()...) {
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

// goshHost is the Host seam over vi. In tab mode fd is the tty handle and
// Out paints the grid; headless it is 0 and Out buffers console lines.
type goshHost struct {
	fd      uint32
	lineBuf []byte
}

func (g *goshHost) Marker(line string) { vi.ConsoleLine(line) }

func (g *goshHost) Out(b []byte) {
	if g.fd != 0 {
		writeTTY(g.fd, b)
		return
	}
	g.lineBuf = append(g.lineBuf, b...)
	for {
		i := indexByte(g.lineBuf, '\n')
		if i < 0 {
			return
		}
		vi.ConsoleLine(string(g.lineBuf[:i]))
		g.lineBuf = g.lineBuf[i+1:]
	}
}

// flushOut drains a trailing partial line at headless exit.
func (g *goshHost) flushOut() {
	if g.fd == 0 && len(g.lineBuf) > 0 {
		vi.ConsoleLine(string(g.lineBuf))
		g.lineBuf = nil
	}
}

func indexByte(b []byte, c byte) int {
	for i, x := range b {
		if x == c {
			return i
		}
	}
	return -1
}

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

func (g *goshHost) RunExternal(name string, args []string) (int64, error) {
	for _, cand := range candidateNames(name) {
		if pid, err := vi.Exec(cand, args...); err == nil {
			return pid, nil
		}
	}
	return 0, errNotFound
}

func (g *goshHost) WaitExternal(pid int64) (int64, error) { return vi.Wait(pid) }

func (g *goshHost) ProbeExternal(pid int64) (int64, int) {
	st, state := vi.Probe(pid)
	return st, state
}

func (g *goshHost) SleepTick() { vi.Sleep(1) }

func (g *goshHost) PipeWrite(b []byte) error {
	_, err := vi.PipeWrite(b)
	return err
}

func (g *goshHost) PipeReadAll() ([]byte, error) {
	var all []byte
	buf := make([]byte, 512)
	for len(all) < maxPipeBytes {
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

func (g *goshHost) ReadFile(path string, max int) ([]byte, error) {
	b, r := vi.ReadFileAll(path, max)
	if r < 0 {
		return nil, errNotFound
	}
	return b, nil
}

func (g *goshHost) WriteFile(path string, b []byte, appendMode bool) error {
	flags := vi.ModeWrite | vi.ModeCreate
	if appendMode {
		flags |= vi.ModeAppend
	}
	h, r := vi.FileOpen(path, flags)
	if r < 0 {
		return errNotFound
	}
	defer vi.FileClose(uint32(h))
	written, r := vi.FileWriteAll(uint32(h), b)
	if r < 0 || written != len(b) {
		return errWriteFailed
	}
	return nil
}

func (g *goshHost) Chdir(path string) error {
	var entries [1]vi.DirEntry
	if _, r := vi.DirList(path, entries[:]); r < 0 {
		return errNotFound
	}
	return nil
}

func (g *goshHost) ListDir() []string {
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

func (g *goshHost) ReadTTYLine() (string, bool) {
	if g.fd == 0 {
		return "", false
	}
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

func (g *goshHost) SleepSeconds(n int) {
	vi.Sleep(uint64(n) * ticksPerSecond)
}

// argvEnvpGuard pads the writable segment's bss so its end keeps at least
// 0x908 bytes of distance to the segment's page end. The kernel packs the
// argv+envp block (256 + 2048 bytes) into the image tail and extends the
// data aperture's mmap-collision bound through it (kernel/src/process.zig
// mmap_collides, issue #1214) — and the GOOS=virelai sbrk break starts at
// memRound(moduledata.end), so a bss end that lands inside that bound
// refuses the runtime's very first mmap and kills mallocinit before main
// runs (observed on this exact binary: `runtime: cannot allocate memory`
// during mheap.init). The build script asserts the invariant from the
// linked ELF; adjust this array's size when it trips.

// host errors (the engine only reports them, so plain sentinels suffice).
var errNotFound = &shellError{"not found"}
var errWriteFailed = &shellError{"write failed"}

type shellError struct{ s string }

func (e *shellError) Error() string { return e.s }
