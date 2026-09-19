// GOSH's execution engine: the environment table, the job table (real
// background jobs — the M65c goroutine-to-guest-thread mapping makes the
// EL1 monitor's `exec &`/`jobs`/`fg` machine available at EL0 for the first
// time), the builtin set, and the pipe/redirect execution paths. Pure code:
// every kernel touch goes through the Host seam that main.go implements.
package main

import (
	"errors"
	"sort"
	"strings"

	"virelai/vsys"
)

// maxPipeBytes mirrors the kernel's single 4 KiB pipe buffer: a pipeline
// hand-off carries at most that much (kernel/src/pipe.zig pipe_capacity).
const maxPipeBytes = 4096

// maxJobs is the background-job table bound (the EL1 monitor's bg_jobs
// table holds 4; GOSH allows 8 — still bounded, honest refusal past it).
const maxJobs = 8

// maxRedirectBytes bounds one `>` capture. The engine must not import vi,
// so this mirrors vi.MaxFileBytes (256 KiB): past it the line fails loudly
// instead of growing the guest heap without bound.
const maxRedirectBytes = 256 * 1024

// boundedCapture collects a command's output up to lim bytes and records
// whether the producer ran past it, so the caller can fail the line loudly
// rather than write a silently clipped file or hand a pipe stage short
// input (the kernel's atomic pipe refusal would never fire).
type boundedCapture struct {
	buf  []byte
	lim  int
	over bool
}

func (c *boundedCapture) write(b []byte) {
	if c.over {
		return
	}
	if len(c.buf)+len(b) > c.lim {
		c.over = true
		return
	}
	c.buf = append(c.buf, b...)
}

// errTooLarge is the bounded-read refusal: silent truncation is worse than
// an error, because the command would compute on short input and still
// exit 0.
var errTooLarge = errors.New("input exceeds the 4096-byte buffer")

// openError is a file-ABI refusal that carries the KERNEL's errno name. The
// M50 trust boundary makes the difference load-bearing: an ownership denial
// (EACCES) and an absent file (ENOENT) are different facts, and a shell that
// prints "not found" for both hides the whole trust surface from the user
// (and from the gate that asserts it).
type openError struct {
	path string
	name string
}

func (e *openError) Error() string { return e.name }

// deniedAs reports err as an openError when it is one.
func deniedAs(err error) (*openError, bool) {
	var oe *openError
	if errors.As(err, &oe) {
		return oe, true
	}
	return nil, false
}

// readBounded reads at most maxPipeBytes of path, refusing a larger file.
func (s *Shell) readBounded(path string) ([]byte, error) {
	b, err := s.host.ReadFile(path, maxPipeBytes+1)
	if err != nil {
		return nil, err
	}
	if len(b) > maxPipeBytes {
		return nil, errTooLarge
	}
	return b, nil
}

// readInput reads one redirect's input file, printing its own refusal.
func (s *Shell) readInput(path string) ([]byte, bool) {
	b, err := s.readBounded(path)
	switch {
	case err == errTooLarge:
		s.host.Out([]byte("gosh: " + path + ": " + errTooLarge.Error() + "\n"))
		return nil, false
	case err != nil:
		s.host.Out([]byte(openDenial(path, err)))
		return nil, false
	}
	return b, true
}

// openDenial renders a failed open the way the shell reports one: the
// kernel's errno name when the seam supplied one, and the plain "not found"
// fallback otherwise.
func openDenial(path string, err error) string {
	if oe, ok := deniedAs(err); ok {
		return "gosh: cannot open " + oe.path + ": " + oe.name + "\n"
	}
	return "gosh: " + path + ": not found\n"
}

// action tells the glue what to do after the current line.
type action int

const (
	actionContinue action = iota
	actionExit            // exit [n]: leave the shell with the line's status
	actionMonitor         // monitor: detach the front-end and return to the kernel monitor
)

// Host is the engine's single seam to the system (implemented over vi in
// main.go, faked in host tests).
type Host interface {
	// Marker prints a gate-observable lifecycle line (single write).
	Marker(line string)
	// Principal gives the calling process's identity (slot 68), or ok=false
	// when the seam cannot answer. `whoami`/`id` print it.
	Principal() (uid uint32, caps uint32, ok bool)
	// Chmod applies the owner-only mode change (slot 69). The kernel is the
	// authority; the shell only forwards the octal mode.
	Chmod(path string, mode uint16) error
	// SecretNames lists the CALLER's entry names from the secret store
	// (slot 70). Values are deliberately not part of this seam: the shell
	// prints names only (ADR 0024 D8).
	SecretNames() ([]string, bool)
	// Out writes command output (the tty grid in the glue's tab mode).
	Out(b []byte)
	// RunExternal tries the SH.BIN candidate names for name against the
	// exec seam and returns the new pid, or an error when none loads.
	RunExternal(name string, args []string) (int64, error)
	// WaitExternal blocks until pid exits and returns its status.
	WaitExternal(pid int64) (int64, error)
	// ProbeExternal scans the registry once: (status, state) with state
	// ProbeRunning/ProbeExited/ProbeAbsent (vi.Probe semantics).
	ProbeExternal(pid int64) (int64, int)
	// SleepTick parks the caller for one scheduler tick.
	SleepTick()
	// PipeWrite stores b in the kernel pipe (at most maxPipeBytes).
	PipeWrite(b []byte) error
	// PipeReadAll drains the kernel pipe (never blocks past what is in it).
	PipeReadAll() ([]byte, error)
	// ReadFile reads at most max bytes of path.
	ReadFile(path string, max int) ([]byte, error)
	// WriteFile writes b to path (truncating, or appending when appendMode).
	WriteFile(path string, b []byte, appendMode bool) error
	// Chdir validates that path is enterable (a directory).
	Chdir(path string) error
	// ListDir lists the share root (completion candidates).
	ListDir() []string
	// ReadTTYLine reads one line from the terminal (`read VAR` unbound).
	ReadTTYLine() (string, bool)
	// SleepSeconds parks the caller for about n seconds.
	SleepSeconds(n int)
}

// Env is the shell-local variable table: insertion-ordered, with the
// exported flag kept for `export`'s honesty (nothing reads it — the EL0
// exec seam carries argv only, exactly as SH.BIN documents its own table).
type Env struct {
	vars []envVar
}

type envVar struct {
	name     string
	val      string
	exported bool
}

// NewEnv seeds the table with PWD (SH.BIN seeds the same one variable).
func NewEnv() *Env {
	return &Env{vars: []envVar{{name: "PWD", val: "/", exported: true}}}
}

func (e *Env) Get(name string) (string, bool) {
	for i := range e.vars {
		if e.vars[i].name == name {
			return e.vars[i].val, true
		}
	}
	return "", false
}

func (e *Env) Set(name, val string) {
	if name == "" {
		return
	}
	for i := range e.vars {
		if e.vars[i].name == name {
			e.vars[i].val = val
			return
		}
	}
	e.vars = append(e.vars, envVar{name: name, val: val})
}

func (e *Env) Unset(name string) bool {
	for i := range e.vars {
		if e.vars[i].name == name {
			e.vars = append(e.vars[:i], e.vars[i+1:]...)
			return true
		}
	}
	return false
}

func (e *Env) Export(name string) bool {
	for i := range e.vars {
		if e.vars[i].name == name {
			e.vars[i].exported = true
			return true
		}
	}
	return false
}

// List returns the table in insertion order (env/set print it).
func (e *Env) List() []envVar { return e.vars }

// Job is one background child. Reaping is main-loop polling (the EL1
// monitor's idle-path reaper shape): ReapJobs probes each live pid once
// per shell loop tick, and fg blocks by polling between ticks — no waiter
// thread, so a job's exec never races a sibling thread spawn.
type Job struct {
	N       int
	PID     int64
	Display string
	Done    bool
	Seen    bool // the child was observed running at least once
	Status  int64
}

// Probe states mirrored from vi (the engine must not import vi).
const (
	probeAbsent  = 0
	probeRunning = 1
	probeExited  = 2
)

// cmdCtx is one builtin/tool invocation.
type cmdCtx struct {
	sh    *Shell
	name  string   // the command word (tools like `[` branch on it)
	args  []string // after the command word
	stdin []byte
	out   func([]byte)
}

// Shell is the interpreter state for one GOSH process.
type Shell struct {
	env       *Env
	hist      *History
	host      Host
	status    int // $?
	jobs      []*Job
	nextN     int
	exitReq   bool
	monitorRq bool
}

// NewShell wires a fresh interpreter; hist may be shared with the editor.
func NewShell(host Host, hist *History) *Shell {
	return &Shell{env: NewEnv(), hist: hist, host: host}
}

// Status reports the last line's exit status ($?).
func (s *Shell) Status() int { return s.status }

// RunLine interprets one command line and returns (status, action). An
// empty or comment-only line is a no-op that leaves $? alone.
func (s *Shell) RunLine(line string) (int, action) {
	line = strings.Map(func(r rune) rune {
		if r == escMark {
			return -1
		}
		return r
	}, line)
	if len(line) > maxLineBytes {
		s.fail("line exceeds " + vsys.Itoa64(maxLineBytes) + " bytes")
		return 1, actionContinue
	}
	toks, err := tokenize(line)
	if err != nil {
		s.fail(err.Error())
		return 1, actionContinue
	}
	if len(toks) == 0 {
		// Blank, whitespace-only, or comment-only: a no-op that leaves $?
		// alone, exactly as this function documents. The guard has to live
		// here — parsePlan reports zero tokens as an empty command, so the
		// error would fire before the p.left check below could catch it.
		return s.status, actionContinue
	}
	p, err := parsePlan(toks, s.env, s.status)
	if err != nil {
		s.fail(err.Error())
		return 1, actionContinue
	}
	if len(p.left) == 0 {
		// Unreachable as the code stands (a zero-token line returned above,
		// and parsePlan refuses a plan with no command word); kept because
		// it is what makes the p.left[0] reads below safe.
		return s.status, actionContinue
	}
	if p.left[0] == "exec" && len(p.left) > 1 {
		// The monitor's vocabulary: `exec NAME args...` runs NAME. It does
		// not replace this process (GOSH keeps its job table) — it is the
		// same seam as typing NAME directly, kept so monitor-style scripts
		// run unmodified.
		p.left = p.left[1:]
	}
	s.exitReq = false
	s.monitorRq = false
	var st int
	var act action
	if p.background {
		st, act = s.runBackground(p)
	} else if len(p.right) > 0 {
		st, act = s.runPipeline(p)
	} else {
		st, act = s.runSingle(p)
	}
	s.status = st
	return st, act
}

func (s *Shell) fail(msg string) {
	s.host.Out([]byte("gosh: " + strings.TrimPrefix(msg, "gosh: ") + "\n"))
}

// classify: 0 builtin, 1 toolbox tool, 2 external.
func classify(name string) int {
	if _, ok := builtins[name]; ok {
		return 0
	}
	if _, ok := tools[name]; ok {
		return 1
	}
	return 2
}

// runBuiltin dispatches name to the builtin/tool table, translating the
// exit/monitor requests into the returned action.
func (s *Shell) runBuiltin(name string, c *cmdCtx) (int, action) {
	fn := builtins[name]
	if fn == nil {
		fn = tools[name]
	}
	c.name = name
	st := fn(c)
	switch {
	case s.exitReq:
		s.exitReq = false
		return st, actionExit
	case s.monitorRq:
		s.monitorRq = false
		return st, actionMonitor
	}
	return st, actionContinue
}

func (s *Shell) runSingle(p *plan) (int, action) {
	name := p.left[0]
	args := p.left[1:]
	var stdin []byte
	if p.in != nil {
		b, ok := s.readInput(p.in.path)
		if !ok {
			return 1, actionContinue
		}
		stdin = b
	}
	var cap boundedCapture
	cap.lim = maxRedirectBytes
	sink := func(b []byte) { s.host.Out(b) }
	if p.out != nil {
		sink = cap.write
	}
	var st int
	var act action
	switch classify(name) {
	case 0, 1:
		st, act = s.runBuiltin(name, &cmdCtx{sh: s, args: args, stdin: stdin, out: sink})
	default:
		stv, err := s.runExternal(name, args)
		st = stv
		if err != nil {
			act = actionContinue
		}
	}
	if act != actionContinue {
		return st, act
	}
	if p.out != nil {
		if cap.over {
			s.host.Out([]byte("gosh: " + p.out.path + ": output exceeds the " + vsys.Itoa64(maxRedirectBytes) + "-byte redirect buffer\n"))
			return 1, actionContinue
		}
		if err := s.host.WriteFile(p.out.path, cap.buf, p.out.append); err != nil {
			s.host.Out([]byte("gosh: " + p.out.path + ": write failed\n"))
			return 1, actionContinue
		}
	}
	return st, act
}

// runExternal spawns name in the foreground and waits, returning its exit
// status (127 when nothing loads or the wait fails).
func (s *Shell) runExternal(name string, args []string) (int, error) {
	pid, err := s.host.RunExternal(name, args)
	if err != nil {
		s.host.Out([]byte("gosh: " + name + ": not found\n"))
		return 127, err
	}
	st, err := s.host.WaitExternal(pid)
	if err != nil {
		s.host.Out([]byte("gosh: " + name + ": wait failed\n"))
		return 127, err
	}
	return int(st), nil
}

func (s *Shell) runPipeline(p *plan) (int, action) {
	lname := p.left[0]
	if classify(lname) == 2 {
		s.host.Out([]byte("gosh: cannot capture an external app's output yet\n"))
		return 1, actionContinue
	}
	var stdin []byte
	if p.in != nil {
		b, ok := s.readInput(p.in.path)
		if !ok {
			return 1, actionContinue
		}
		stdin = b
	}
	var stage boundedCapture
	stage.lim = maxPipeBytes
	fn := builtins[lname]
	if fn == nil {
		fn = tools[lname]
	}
	st, act := s.runBuiltin(lname, &cmdCtx{sh: s, args: p.left[1:], stdin: stdin, out: stage.write})
	if act != actionContinue {
		return st, act
	}
	if stage.over {
		// Writing the clipped capture would hand the right stage short
		// input that still reports success, so the line fails instead.
		s.host.Out([]byte("gosh: pipe stage output exceeds the " + vsys.Itoa64(maxPipeBytes) + "-byte pipe buffer\n"))
		return 1, actionContinue
	}
	if err := s.host.PipeWrite(stage.buf); err != nil {
		s.host.Out([]byte("gosh: pipe write failed\n"))
		return 1, actionContinue
	}
	rightStdin, err := s.host.PipeReadAll()
	if err != nil {
		s.host.Out([]byte("gosh: pipe read failed\n"))
		return 1, actionContinue
	}
	rname := p.right[0]
	if classify(rname) == 2 {
		s.host.Out([]byte("gosh: a piped command must be a builtin or tool (an external app would not read the pipe)\n"))
		return 1, actionContinue
	}
	var rcap boundedCapture
	rcap.lim = maxRedirectBytes
	rsink := func(b []byte) { s.host.Out(b) }
	if p.out != nil {
		rsink = rcap.write
	}
	rst, ract := s.runBuiltin(rname, &cmdCtx{sh: s, args: p.right[1:], stdin: rightStdin, out: rsink})
	if ract != actionContinue {
		return rst, ract
	}
	if p.out != nil {
		if rcap.over {
			s.host.Out([]byte("gosh: " + p.out.path + ": output exceeds the " + vsys.Itoa64(maxRedirectBytes) + "-byte redirect buffer\n"))
			return 1, actionContinue
		}
		if err := s.host.WriteFile(p.out.path, rcap.buf, p.out.append); err != nil {
			s.host.Out([]byte("gosh: " + p.out.path + ": write failed\n"))
			return 1, actionContinue
		}
	}
	return rst, actionContinue
}

func (s *Shell) runBackground(p *plan) (int, action) {
	name := p.left[0]
	if classify(name) != 2 {
		// A builtin has nothing to background (it runs inside this
		// process); say so and run it in the foreground instead.
		s.host.Out([]byte("gosh: " + name + " is a builtin; & runs external apps only\n"))
		return s.runSingle(&plan{left: p.left, in: p.in, out: p.out})
	}
	if len(s.jobs) >= maxJobs {
		s.host.Out([]byte("gosh: too many background jobs\n"))
		return 1, actionContinue
	}
	pid, err := s.host.RunExternal(name, p.left[1:])
	if err != nil {
		s.host.Out([]byte("gosh: " + name + ": not found\n"))
		return 127, actionContinue
	}
	s.nextN++
	j := &Job{N: s.nextN, PID: pid, Display: strings.Join(p.left, " ")}
	s.jobs = append(s.jobs, j)
	s.host.Marker("gosh: job " + vsys.Itoa64(int64(j.N)) + " pid=" + vsys.Itoa64(pid))
	return 0, actionContinue
}

// ReapJobs probes every live background job once and reports finished ones
// exactly once (the serial marker is the gate's evidence of the cycle).
// The shell loop calls it every tick; jobs/fg call it before reading.
func (s *Shell) ReapJobs() {
	for _, j := range append([]*Job{}, s.jobs...) {
		if j.Done {
			continue
		}
		st, state := s.host.ProbeExternal(j.PID)
		switch state {
		case probeRunning:
			j.Seen = true
		case probeExited:
			s.finishJob(j, st)
		case probeAbsent:
			if j.Seen {
				s.finishJob(j, 0) // reaped and recycled: status 0
			}
		}
	}
}

func (s *Shell) finishJob(j *Job, st int64) {
	j.Done = true
	j.Status = st
	s.host.Marker("gosh: job " + vsys.Itoa64(int64(j.N)) + " done exit=" + vsys.Itoa64(st))
}

// jobByN finds job n, or nil.
func (s *Shell) jobByN(n int) *Job {
	for _, j := range s.jobs {
		if j.N == n {
			return j
		}
	}
	return nil
}

func (s *Shell) removeJob(j *Job) {
	for i := range s.jobs {
		if s.jobs[i] == j {
			s.jobs = append(s.jobs[:i], s.jobs[i+1:]...)
			return
		}
	}
}

// errNoJob is fg's refusal when the id names nothing.
var errNoJob = errors.New("fg: no such job")

// names lists builtin and tool names (completion + help).
func builtinNames() []string { return tableNames(builtins) }
func toolNames() []string    { return tableNames(tools) }

func tableNames(m map[string]func(*cmdCtx) int) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}
