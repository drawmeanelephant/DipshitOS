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
// `GOSH.ELF serial` takes the SERIAL front-end instead (step 3 becomes
// `sys_tty_attach(1)`, no window and no tabapp — the console the kernel
// monitor hands over). `GOSH.ELF net [port] [open]` takes the NET front-end
// (selector 3) with the delegated HMAC challenge-response handshake, the
// last SH.BIN surface M68b (#1450) ports. The engine, editor and startup
// contract are identical; only the front-end owner changes.
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
	// M69f1 (#1537): the shell's own persistent history. NOT the monitor's
	// HISTORY.TXT -- mixing the kernel actor's `virelai>` verbs into GOSH's
	// Up-arrow recall would be worse than no persistence at all.
	histPath       = "/host/GOSH-HISTORY.TXT"
	ticksPerSecond = 100  // the scheduler tick is ~10 ms (kernel timer @ ~100 Hz)
	ttyWriteMax    = 1024 // under the kernel's 2048-byte file-write stage cap

	markerReady    = "gosh: ready"
	markerOpen     = "gosh: open id="
	markerDeclare  = "gosh: declare accepted"
	markerDogfood  = "dogfood: gosh" // M69a (#1528): go-dogfood.spec's marker
	markerTty      = "gosh: tty"
	markerAttach   = "gosh: attached"
	markerPrompt   = "gosh: prompt"
	markerLine     = "gosh: line "
	markerMonitor  = "gosh: monitor"
	markerMonErr   = "gosh: monitor failed"
	markerClose    = "gosh: close"
	markerOK       = "gosh OK"
	markerOpenErr  = "gosh: error open "
	markerTtyErr   = "gosh: no /dev/tty"
	markerAttachEr = "gosh: attach failed"
	markerRemote   = "gosh: remote on "
	markerAuthOpen = "gosh: remote auth=open"
	markerAuthHMAC = "gosh: remote auth=hmac-sha256"
	markerAuthEd   = "gosh: remote auth=ed25519"
	markerNetRefus = "gosh: net refused: no credential (pass 'open' for the insecure mode)"
	markerNetFail  = "gosh: remote attach failed"
	markerNetBad   = "gosh: net refused: "
	// M69f1 (#1537) D3: persistence is best-effort. ONE line, once, and the
	// session continues -- a share that refuses the write must not end a
	// shell.
	markerHistFail = "gosh: history not persisted"
)

func main() {
	args := vi.Args()
	if line, headless := headlessLine(args); headless {
		runHeadless(line)
		return
	}
	if na, ok, err := parseNetArgs(args); ok {
		runNet(na)
		return
	} else if err != "" {
		vi.ConsoleLine(markerNetBad + err)
		vi.Exit(2)
	}
	if hasArg(args, "serial") {
		runSerial()
		return
	}
	runTab()
}

// hasArg reports whether the argv carries word. The exec seam may supply
// argv[0] at either position (see headlessLine), so both are searched.
func hasArg(args []string, word string) bool {
	for _, a := range args {
		if a == word {
			return true
		}
	}
	return false
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
		// M69a (#1528): the dogfood beat's ordered marker, printed only on the
		// accepted-declare path, so it means "a WM seat hosts this shell" and
		// never fires on the shim/refused path.
		vi.ConsoleLine(markerDogfood)
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
	runSession(fd, ta, nil)
}

// runSerial attaches the SERIAL front-end (ADR 0020 selector 1) instead of a
// window: the same session over the console the kernel monitor hands over,
// which is the presentation SH.BIN had and what the M68b shell gates assert
// against. No tabapp, no declare, no /host share for a window.
func runSerial() {
	vi.ConsoleLine(markerReady)

	h, rc := vi.FileOpen(ttyPath, vi.ModeRead|vi.ModeWrite)
	if rc < 0 {
		vi.ConsoleLine(markerTtyErr)
		vi.Exit(1)
	}
	fd := uint32(h)
	vi.ConsoleLine(markerTty)

	if r := vi.TtyAttach(vi.TtySerial); r != 0 {
		vi.FileClose(fd)
		vi.ConsoleLine(markerAttachEr)
		vi.Exit(2)
	}
	vi.ConsoleLine(markerAttach)
	runSession(fd, nil, nil)
}

// runNet attaches the NET front-end (ADR 0020 selector 3): LISTEN on the
// asked port, with the delegated challenge-response handshake unless `open`
// was explicit. The engine, editor and startup contract are the serial
// path's; only the front-end owner changes. Fail closed: no credential and
// no `open` refuses to listen.
func runNet(na netArgs) {
	vi.ConsoleLine(markerReady)

	h, rc := vi.FileOpen(ttyPath, vi.ModeRead|vi.ModeWrite)
	if rc < 0 {
		vi.ConsoleLine(markerTtyErr)
		vi.Exit(1)
	}
	fd := uint32(h)
	vi.ConsoleLine(markerTty)

	scheme := vi.NetSchemeOpen
	var auth *netAuth
	if !na.open {
		sch, ok := selectScheme(storeGet)
		if !ok {
			vi.FileClose(fd)
			vi.ConsoleLine(markerNetRefus)
			vi.Exit(2)
		}
		scheme = sch
	}
	if r := vi.TtyAttachNet(na.port, scheme, 0); r != 0 {
		vi.FileClose(fd)
		vi.ConsoleLine(markerNetFail)
		vi.Exit(2)
	}
	if scheme != vi.NetSchemeOpen {
		auth = sysNetAuth(scheme)
	}
	vi.ConsoleLine(markerRemote + vi.Itoa64(int64(na.port)))
	switch scheme {
	case vi.NetSchemeOpen:
		vi.ConsoleLine(markerAuthOpen)
	case vi.NetSchemeHMAC:
		vi.ConsoleLine(markerAuthHMAC)
	default:
		vi.ConsoleLine(markerAuthEd)
	}
	runSession(fd, nil, auth)
}

// runSession is the shared startup contract + editor loop. ta is nil on the
// serial and net front-ends: there is no window, so no window events are
// polled — the console's own input path (serial) or the kernel's net pump
// (selector 3) delivers the bytes FileRead returns. auth is the delegated
// handshake, live only in net mode and only when a credential is in force;
// one step per loop turn, including idle, because the challenge is not a
// tty byte.
func runSession(fd uint32, ta *tabapp.TabApp, auth *netAuth) {
	hst := &goshHost{fd: fd, tty: true}
	hist := &History{}
	sh := NewShell(hst, hist)
	editor := NewEditor(loadPrompt(), hist)
	editor.Complete = completeFn(hst)

	// The startup contract (M49 SD2): STARTUP.SH, then PROFILE.SH, silent
	// when either is missing, every line through the same engine.
	for _, ln := range startupLines() {
		vi.ConsoleLine(markerLine + ln)
		_, act := sh.RunLine(ln)
		if act != actionContinue {
			leave(ta, fd, sh, act)
		}
	}

	// M69f1 (#1537): seed recall from the share AFTER the startup contract
	// and BEFORE the first prompt, so the startup lines never enter recall
	// and the first Up arrow lands on the last line the user really typed.
	sink := &historySink{}
	loadHistory(hst, hist, sink)

	_, _ = vi.FileWrite(fd, editor.Repaint())
	vi.ConsoleLine(markerPrompt)

	// handle applies one editor outcome. Feed returns at most one event per
	// call and holds the remainder of its chunk, so the loop below keeps
	// feeding until the editor has nothing left: the serial front-end can
	// deliver several whole lines in a single read, and a burst that stops
	// after its first line would leave the rest typed but never run.
	handle := func(out []byte, ev EditEvent) {
		if len(out) > 0 {
			writeTTY(fd, out)
		}
		switch ev.Kind {
		case evSubmit:
			vi.ConsoleLine(markerLine + ev.Line)
			saveHistory(hst, hist, ev.Line, sink)
			_, act := sh.RunLine(ev.Line)
			if act != actionContinue {
				leave(ta, fd, sh, act)
			}
		case evEOF:
			shutdown(ta, fd, 0)
		case evCancel:
			// The editor already painted ^C and the fresh prompt.
		}
	}

	var readBuf [64]byte
	for {
		auth.step()
		n, _ := vi.FileRead(fd, readBuf[:])
		if n > 0 {
			handle(editor.Feed(readBuf[:n]))
		}
		for editor.Pending() {
			handle(editor.Feed(nil))
		}

		sh.ReapJobs()

		if ta == nil {
			if n <= 0 {
				vi.Sleep(1)
			}
			continue
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

// leave ends the session for the line that asked to leave. The monitor
// handover is reported only AFTER the detach syscall returned, so the console
// log says why the shell gave the console back rather than only that it
// closed, and a marker can never claim a handover that did not happen — the
// gate sequences its `version` type on `gosh: monitor`, so a failed detach
// would otherwise type into a shell still holding the console. SH.BIN printed
// the same marker; live-sh-monitor sequences on it.
func leave(ta *tabapp.TabApp, fd uint32, sh *Shell, act action) {
	if act == actionMonitor {
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
	if ta == nil {
		// Serial: the detach handed the console back to the kernel monitor,
		// and there is no window to close — exiting IS the handover.
		vi.Exit(status)
	}
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

// --- M69f1 (#1537): persistent recall -------------------------------------
//
// The monitor's HISTORY.TXT (M18 T4) belongs to the kernel actor; GOSH's
// recall was session-only, so a reboot cost the Up arrow. This is the
// shell's own file on the same share: a different name, the same
// one-line-per-entry LF shape, so a human can cat it and neither writer can
// clobber the other.

// maxHistoryBytes bounds the load. The writer keeps the file inside the ring
// bound, so a larger file is not ours: refuse it whole instead of parsing a
// prefix of somebody else's data. historyMax lines of maxLineBytes is the
// worst case the ring can produce.
const maxHistoryBytes = historyMax * maxLineBytes

// histStore is the slice of the host seam persistence needs. *goshHost is
// the real one; the host tests drive saveHistory/loadHistory with their
// fakeHost through this interface.
type histStore interface {
	ReadFile(path string, max int) ([]byte, error)
	WriteFile(path string, b []byte, appendMode bool) error
}

// historySink is the write side's state: the last line appended (the ring's
// dup rule, carried across boots) and how many appends have landed since the
// file was last rewritten whole.
type historySink struct {
	last     string
	appended int
	warned   bool // the one-line failure report is emitted at most once
}

// loadHistory seeds the ring from the share. A missing file is an empty
// ring, not an error; a read failure is treated the same way (D3: the file
// is a convenience, and a share that cannot answer must not stop the boot).
func loadHistory(st histStore, h *History, s *historySink) {
	b, err := st.ReadFile(histPath, maxHistoryBytes)
	if err != nil || len(b) == 0 {
		return
	}
	h.Load(b)
	if e := h.Entries(); len(e) > 0 {
		s.last = e[len(e)-1]
	}
}

// saveHistory appends one submitted line and keeps the file inside the ring
// bound (D2). Runs AFTER the editor pushed the line into the ring, so the
// ring is the writer's source of truth: once the appends alone would push
// the file past the bound, it is rewritten whole from the ring, which has
// already dropped the oldest lines.
func saveHistory(st histStore, h *History, line string, s *historySink) {
	// Idempotent: the editor already pushed this line when it submitted, so
	// this is a no-op in the shell and the reason the function is honest on
	// its own in a test.
	h.Push(line)
	if line == "" || line == s.last {
		return
	}
	if s.appended >= historyMax {
		// The ring already holds this line (the editor pushes on submit), so
		// the rewrite IS the append: compact and stop. From here the file is
		// rewritten to the ring's own contents, which is the bound D2 asks
		// for -- at most historyMax lines, never an unbounded append log.
		if err := writeHistoryFile(st, h); err != nil {
			s.warn()
			return
		}
		s.last = line
		s.appended = len(h.Entries())
		return
	}
	if err := st.WriteFile(histPath, []byte(line+"\n"), true); err != nil {
		s.warn()
		return
	}
	s.last = line
	s.appended++
}

// writeHistoryFile replaces the file with the ring's contents (write-open
// truncates, kernel/src/file_table.zig: "a fresh write-open truncates").
func writeHistoryFile(st histStore, h *History) error {
	var b []byte
	for _, ln := range h.Entries() {
		b = append(b, ln...)
		b = append(b, '\n')
	}
	return st.WriteFile(histPath, b, false)
}

// warn reports a persistence failure ONCE, on one serial line, and never
// ends the session (D3).
func (s *historySink) warn() {
	if s.warned {
		return
	}
	s.warned = true
	vi.ConsoleLine(markerHistFail)
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

// goshHost is the Host seam over vi. When tty is set, Out writes the
// attached /dev/tty (serial, window, or net — the kernel pumps the right
// front-end). Headless, Out buffers console lines. fd 0 is a valid kernel
// file handle (the first open), so it cannot mean "no tty".
type goshHost struct {
	fd      uint32
	tty     bool
	lineBuf []byte
}

func (g *goshHost) Marker(line string) { vi.ConsoleLine(line) }

func (g *goshHost) Out(b []byte) {
	if g.tty {
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
	if !g.tty && len(g.lineBuf) > 0 {
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
		// Carry the kernel's own errno name: an ownership denial (EACCES)
		// and an absent file (ENOENT) are different facts, and the M50
		// trust gates assert which one the shell reported.
		if name := vi.ErrnoName(r); name != "" {
			return nil, &openError{path: path, name: name}
		}
		return nil, errNotFound
	}
	return b, nil
}

// Principal is the caller's identity (slot 68) for `whoami`/`id`.
func (g *goshHost) Principal() (uint32, uint32, bool) { return vi.Principal() }

// Chmod is the owner-only mode change (slot 69).
func (g *goshHost) Chmod(path string, mode uint16) error {
	r := vi.FileMode(path, mode)
	if r < 0 {
		if name := vi.ErrnoName(r); name != "" {
			return &openError{path: path, name: name}
		}
		return errNotFound
	}
	return nil
}

// SecretNames reads the caller's store entry NAMES (slot 70). The values are
// deliberately not carried through this seam.
func (g *goshHost) SecretNames() ([]string, bool) {
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
		// Carry the kernel's errno for the same reason ReadFile does: a
		// missing directory, a path that is a file, and an ownership denial
		// on the share's list gate are three different facts, and folding
		// them into one "not a directory" message hides two of them.
		if name := vi.ErrnoName(r); name != "" {
			return &openError{path: path, name: name}
		}
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
	if !g.tty {
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
