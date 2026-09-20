package main

import (
	"os"
	"strconv"
	"time"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/colorprofile"

	"virelai/vi"
)

// main wires Bubble Tea to the VirelaiOS seams and reports the outcome through
// console markers the gate asserts on.
func main() {
	rounds, seed := defaultRounds, int64(defaultSeed)
	keys, out := defaultKeys, defaultOut
	width, height := 80, 24
	sinkStdout := false

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
		}
	}

	sink := consoleWriter{}
	if sinkStdout {
		sink.alt = os.Stdout
		mirror = os.Stdout
	}

	note(markerStart)

	// A VirelaiOS console is not a POSIX tty, so Bubble Tea cannot ioctl it for
	// a size. The geometry is declared instead; Bubble Tea still delivers it to
	// the model as a WindowSizeMsg, and still delivers every later resize the
	// same way.
	program := tea.NewProgram(
		newModel(seed, rounds),
		tea.WithInput(&keyScript{keys: parseKeys(keys), delay: 90 * time.Millisecond}),
		tea.WithOutput(sink),
		// A VirelaiOS console is not a tty, so Bubble Tea cannot detect colour
		// support and would normalise our SGR sequences away. The app renders in
		// colour; say so explicitly.
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

	if !ok {
		vi.Exit(2)
	}
	note(markerOK)
	vi.Exit(0)
}
