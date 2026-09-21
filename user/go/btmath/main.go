package main

import (
	"os"
	"strconv"
	"strings"
	"time"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/colorprofile"

	"virelai/vi"
)

// main wires Bubble Tea to the VirelaiOS seams and reports the outcome through
// console markers. With --selftest it then checks its own results and prints a
// machine-readable verdict to the guest console, so the proof is produced
// inside the guest rather than on the machine that built it.
func main() {
	rounds, seed := defaultRounds, int64(defaultSeed)
	keys, out := defaultKeys, defaultOut
	width, height := 80, 24
	sinkStdout, selfTest := false, false

	args := os.Args[1:]
	for i := 0; i < len(args); i++ {
		next := func() string {
			if i+1 < len(args) {
				i++
				return args[i]
			}
			return ""
		}
		switch args[i] {
		case "--rounds":
			if n, err := strconv.Atoi(next()); err == nil && n > 0 {
				rounds = n
			}
		case "--seed":
			if n, err := strconv.ParseInt(next(), 10, 64); err == nil {
				seed = n
			}
		case "--keys":
			keys = next()
		case "--out":
			out = next()
		case "--w":
			if n, err := strconv.Atoi(next()); err == nil && n > 0 {
				width = n
			}
		case "--h":
			if n, err := strconv.Atoi(next()); err == nil && n > 0 {
				height = n
			}
		case "--sink":
			sinkStdout = next() == "stdout"
		case "--selftest":
			selfTest = true
		}
	}

	sink := consoleWriter{}
	if sinkStdout {
		sink.alt = os.Stdout
		mirror = os.Stdout
	}

	note(markerStart)

	// A VirelaiOS console is not a POSIX tty, so Bubble Tea cannot ioctl it for
	// a size, and it cannot detect colour support either. Both are declared.
	program := tea.NewProgram(
		newModel(seed, rounds),
		tea.WithInput(&keyScript{keys: parseKeys(keys), delay: 90 * time.Millisecond}),
		tea.WithOutput(sink),
		tea.WithColorProfile(colorprofile.TrueColor),
		tea.WithWindowSize(width, height),
	)

	final, err := program.Run()
	if err != nil {
		note("btmath: run error " + err.Error())
		vi.Exit(1)
	}

	played, _ := final.(model)

	n, ok := save(out, played)
	if ok {
		note(markerSave + out + " " + strconv.Itoa(n) + "B")
	} else {
		note(markerSaveNo + out)
	}
	note(markerRound + "played=" + strconv.Itoa(played.correct+played.incorrect) +
		" score=" + strconv.Itoa(played.score) +
		" correct=" + strconv.Itoa(played.correct) +
		" wrong=" + strconv.Itoa(played.incorrect))
	note(markerQuit)

	if selfTest {
		rc := runSelfTest(played, ok)
		if rc == 0 {
			note(markerOK)
		}
		vi.Exit(rc)
	}
	if !ok {
		vi.Exit(2)
	}
	note(markerOK)
	vi.Exit(0)
}

// runSelfTest checks the session the guest just played against the documented
// outcome and prints one line per check. It runs IN the guest: the console is
// the evidence, and a reviewer reads the verdict without leaving the OS.
//
// Exit status: 0 all checks passed, 1 any failed. Nothing here needs a shell,
// a Unix tool, or any host-side script.
func runSelfTest(m model, saved bool) int {
	type check struct {
		name string
		got  string
		want string
		ok   bool
	}
	frames := strings.Join(m.frames, "\n")
	has := func(s string) bool { return strings.Contains(frames, s) }

	checks := []check{
		{"rounds", strconv.Itoa(m.correct + m.incorrect), strconv.Itoa(defaultRounds), m.correct+m.incorrect == defaultRounds},
		{"score", strconv.Itoa(m.score), "65", m.score == 65},
		{"correct", strconv.Itoa(m.correct), "3", m.correct == 3},
		{"incorrect", strconv.Itoa(m.incorrect), "2", m.incorrect == 2},
		{"frames", strconv.Itoa(len(m.frames)), ">0", len(m.frames) > 0},
		{"frame-header", "Bubble Math", "present", has("Bubble Math")},
		{"frame-correct", "Correct. +10 points", "present", has("Correct. +10 points")},
		{"frame-wrong", "Not quite: 5, not 6.", "present", has("Not quite: 5, not 6.")},
		{"frame-skip", "Skipped.", "present", has("Skipped.")},
		{"frame-final", "Session over. Final score 65.", "present", has("Session over. Final score 65.")},
		{"frame-tiers", "Times & divide", "present", has("Times & divide")},
		{"record-written", "SESSION.TXT", "written", saved},
	}

	failed := 0
	note("btmath: selftest begin checks=" + strconv.Itoa(len(checks)))
	for _, c := range checks {
		verdict := "PASS"
		if !c.ok {
			verdict = "FAIL"
			failed++
		}
		note("btmath: selftest " + c.name + " got=" + c.got + " want=" + c.want + " " + verdict)
	}

	result := "PASS"
	if failed > 0 {
		result = "FAIL"
	}
	note("btmath: selftest RESULT " + result +
		" checks=" + strconv.Itoa(len(checks)) + " failed=" + strconv.Itoa(failed))
	if failed > 0 {
		return 1
	}
	return 0
}
