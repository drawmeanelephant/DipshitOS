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
	toks, err := tokenize(line)
	if err != nil {
		s.fail(err.Error())
		return 1, actionContinue
	}
	p, err := parsePlan(toks, s.env, s.status)
	if err != nil {
		s.fail(err.Error())
		return 1, actionContinue
	}
	if len(p.left) == 0 {
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
		b, err := s.host.ReadFile(p.in.path, maxPipeBytes)
		if err != nil {
			s.host.Out([]byte("gosh: " + p.in.path + ": not found\n"))
			return 1, actionContinue
		}
		stdin = b
	}
	var capture []byte
	sink := func(b []byte) { s.host.Out(b) }
	if p.out != nil {
		sink = func(b []byte) { capture = append(capture, b...) }
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
		if err := s.host.WriteFile(p.out.path, capture, p.out.append); err != nil {
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
		b, err := s.host.ReadFile(p.in.path, maxPipeBytes)
		if err != nil {
			s.host.Out([]byte("gosh: " + p.in.path + ": not found\n"))
			return 1, actionContinue
		}
		stdin = b
	}
	var capture []byte
	fn := builtins[lname]
	if fn == nil {
		fn = tools[lname]
	}
	st, act := s.runBuiltin(lname, &cmdCtx{sh: s, args: p.left[1:], stdin: stdin, out: func(b []byte) {
		if len(capture)+len(b) <= maxPipeBytes {
			capture = append(capture, b...)
		}
	}})
	if act != actionContinue {
		return st, act
	}
	if err := s.host.PipeWrite(capture); err != nil {
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
	var rcapture []byte
	rsink := func(b []byte) { s.host.Out(b) }
	if p.out != nil {
		rsink = func(b []byte) { rcapture = append(rcapture, b...) }
	}
	rst, ract := s.runBuiltin(rname, &cmdCtx{sh: s, args: p.right[1:], stdin: rightStdin, out: rsink})
	if ract != actionContinue {
		return rst, ract
	}
	if p.out != nil {
		if err := s.host.WriteFile(p.out.path, rcapture, p.out.append); err != nil {
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
