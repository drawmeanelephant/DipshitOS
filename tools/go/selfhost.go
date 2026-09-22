// M70c-S2 (issue #1544): the in-guest build loop, in one guest process.
//
// This is the driver the card asks for: compile the pinned fixture with the
// guest's OWN cmd/compile, link it with the guest's OWN cmd/link, and run the
// result — sequenced by spawn-and-wait (ADR 0007 slot 28 plus the wait slot),
// NOT by a new kernel slot. The spike that chose this shape, and the reasons
// option (b) was rejected, are ADR 0035 amendment 6; nothing here invents a
// seam.
//
// "GOTOOLCHAIN=local" is literal for a guest that has no `go` command at all:
// nothing in this loop fetches anything. The two toolchain images, the pinned
// source and the import config that names the package archives are staged in
// the share by the host (tools/go/build-gotool.sh, tools/go/stage-selfhost.sh),
// and every byte the loop reads comes from /host.
//
// Why a driver and not three boots: the monitor's `exec` returns immediately
// (tools/gate/SPEC.md), so compile -> link in order is either two boots
// (go-hello runs 06-07 take exactly that route, one `exec` each) or one
// program that can wait. This is the second shape, and it is the shape a real
// build loop needs — cmd/go cannot be the driver on this GOOS until os/exec
// has a spawn-and-inherit story, which is why the loop lives here.
//
// The loop is TWO children, and that is now a CONSERVATIVE shape rather than a
// forced one. A third sequential child died once (a level-3 data abort in the
// child: `fault: HELLO2.ELF far=0x47c29000 ec=0x24 esr=0x9200004f`, status
// 139) -- the wall go-sh.spec documents against Go children ("A THIRD
// sequential exec from one EL0 parent currently dies in the Go runtime's own
// schedinit ... follow-up owed to the runtime/kernel owners", issue #1449),
// with a different symptom. The argv-gated `--spawn` measurement below then
// FAILED TO REPRODUCE it: three children of either kind survived 3/3, and the
// exact failing configuration (the loop's two children, then the product as the
// third) came back status=0 (four boots; ADR 0035 amendment 8 has the matrix,
// issue #1449 the report). So the RUN step stays the gate's second boot (one
// monitor `exec` of the product this loop built, which is also how go-hello run
// 08 executes it) because this shape is proven green -- NOT because a third
// child is known to be broken. The narrow, defensible statement is: a third
// child died once and has not died again; the wall is uncharacterised, not
// eliminated. A one-boot three-child loop is feasible and is the first thing to
// try once #1449 has an owner.
//
// One consequence of the above for anyone reading the driver's own output: a
// `status=0` on a step is a liveness observation, not proof.
// vi.WaitBudget counts a pid that was seen running and then left the registry as
// status 0 (reaped and recycled, vi/proc.go), which is also what a child that
// crashed and was reaped before a poll looks like. The driver therefore reports
// what it observed -- the child left the registry and the status it left -- and
// the proof that the step really worked is the gate's product checks: HELLO.o
// is a virelai object, HELLO2.ELF satisfies every loader rule, its pinned lines
// run.
//
// Every argv line below is checked against the kernel's 8 x 256-byte argv block
// (kernel/src/exec.zig max_exec_args / arg_slot_bytes) by
// tools/go/stage-selfhost.sh, so an over-long flag fails on the host instead of
// failing here as a truncated path.
package main

import (
	"virelai/vi"
	"virelai/vsys"
)

// The loop's inputs. Paths are share paths because that is where the host
// stages them; the object and the product are written back into the share, so
// the gate can check them from macOS afterwards.
const (
	compileImage = "GOCMDCOMPILE.ELF"
	linkImage    = "GOCMDLINK.ELF"
	source       = "/host/HELLO.GO"
	object       = "/host/HELLO.o"
	imports      = "/host/GOIMPORT.CFG"
	product      = "/host/HELLO2.ELF"
	workdir      = "/host"
)

// stepBudgetNs bounds one child's wait. It is a CEILING, not a prediction: each
// step's real elapsed time is printed, so the number that matters is in the log
// either way. Measured on the reference host: compile 2,000 ms, link 14,016 ms
// (the link reads 14.82 MiB of archives out of the share at the 2048-byte EL0
// read cap). This is 40x the measured link and stays strictly inside the gate's
// own budget for the boot (`live-selfhost-go.spec` runs it with --timeout 900),
// so the driver's ceiling is the one that fires and it fires with a diagnostic
// rather than in a race with the harness's kill -- the 900 s this used to be
// was exactly the run timeout, i.e. two deadlines expiring together.
const stepBudgetNs = int64(600) * int64(1e9)

type step struct {
	label string
	image string
	args  []string
}

// The #1449 EXPERIMENT, off unless asked for:
//
//	exec GOSELFHOST.ELF --spawn <image> <count> [expected-status] [--after-loop]
//
// spawns that image count times, SEQUENTIALLY, from this one EL0 parent and
// reports each child's status; with --after-loop the build loop's two children
// run first, i.e. the spawns become the THIRD child of the same parent. It
// exists because both observed third-child deaths used a GO child (go-sh's
// children are GOSH.ELF; this loop's third was the linked product), so "a third
// sequential exec from one EL0 parent" and "a third live Go runtime" predict
// the same tombstone and the record could not tell them apart. A non-Go child
// that returns its own status discriminates: the seeded Zig STATUS43.BIN exits
// 43.
//
// Measured 2026-09-20, and it REFUTED the simple reading of the wall: three
// small children of EITHER kind survive (Zig STATUS43.BIN 3/3 status=43; Go
// GOHELLO.ELF 3/3 status=0), so "the third child dies" is not the rule. --after-loop
// is what isolates the real difference: the loop's first two children are
// cmd/compile (24 MiB image, 23 MiB mapped) and cmd/link.
//
// It is a MEASUREMENT, not a gate: no spec asserts its verdict, because
// pinning a bug's present shape into a class-B gate would freeze it.
const (
	spawnFlag     = "--spawn"
	afterLoopFlag = "--after-loop"
)

func main() {
	rest := vi.Args()
	if len(rest) > 0 {
		rest = rest[1:] // argv[0] is this program's name
	}
	spawnArgs, afterLoop := splitExperimentArgs(rest)
	// The normal path (no --spawn) is the loop alone; --spawn alone is the
	// standalone baseline; --spawn --after-loop puts the spawns behind the
	// loop's two children, which is the configuration that failed.
	if len(spawnArgs) == 0 || afterLoop {
		buildLoop()
	}
	if len(spawnArgs) > 0 {
		runSpawnExperiment(spawnArgs)
	}
}

// splitExperimentArgs pulls the argv-gated experiment out of the program's own
// arguments. Everything between --spawn and the next flag is the experiment's
// ((image), (count), optional (expected-status)).
func splitExperimentArgs(args []string) (spawn []string, afterLoop bool) {
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case spawnFlag:
			for i+1 < len(args) && args[i+1] != afterLoopFlag {
				i++
				spawn = append(spawn, args[i])
			}
		case afterLoopFlag:
			afterLoop = true
		}
	}
	return spawn, afterLoop
}

// buildLoop is the card's deliverable: compile -> link, in this process, with
// the guest's own toolchain, then the marker the gate waits on.
func buildLoop() {
	steps := []step{
		// cmd/compile: source -> object. No -p flag: the default package
		// path is what the linker needs to find main.main, verified on the
		// host twin and in-guest (go-hello run 06).
		{label: "compile", image: compileImage,
			args: []string{"-o", object, "-importcfg", imports, source}},
		// cmd/link: object -> ELF, resolving symbols out of the staged
		// archives. -tmpdir is explicit because the port has no /tmp.
		{label: "link", image: linkImage,
			args: []string{"-importcfg", imports, "-tmpdir", workdir, "-o", product, object}},
		// NO third step. The product is built here and RUN by the gate's
		// second boot, because a third sequential child dies on this GOOS
		// today — see the header, and go-sh.spec / issue #1449.
	}

	for _, s := range steps {
		status, ms, err := runStep(s)
		if err != nil {
			// The ceiling travels with the failure: "it never finished" and "it
			// finished badly" are different findings about the guest.
			vsys.Println("selfhost: FAIL " + s.label + " err=" + err.Error() +
				" budget_s=" + vsys.Itoa64(stepBudgetNs/1000000000))
			vsys.Exit(1)
		}
		vsys.Println("selfhost: " + s.label + " " + s.image +
			" status=" + vsys.Itoa64(status) + " ms=" + vsys.Itoa64(ms))
		if status != 0 {
			vsys.Println("selfhost: FAIL " + s.label + " status=" + vsys.Itoa64(status))
			vsys.Exit(1)
		}
	}
	// The marker the gate waits on: both steps of the build ran, in the
	// guest, with the guest's own toolchain.
	vsys.Println("selfhost: build loop OK")
}

// runSpawnExperiment is the #1449 discriminator (see spawnFlag). It is a small
// argv-driven measurement, so it deliberately shares runStep — the same exec
// slot, the same wait rule and the same ceiling as the build loop, because the
// question is about THIS parent's third child, not about a fresh one.
func runSpawnExperiment(args []string) {
	if len(args) < 2 {
		vsys.Println("selfhost: spawn needs <image> <count> [expected-status]")
		vsys.Exit(2)
	}
	image := args[0]
	count, ok := parseInt(args[1])
	if !ok || count < 1 {
		vsys.Println("selfhost: spawn count must be a positive integer: " + args[1])
		vsys.Exit(2)
	}
	expect := int64(-1) // -1 = no expectation, report whatever came back
	if len(args) > 2 {
		if expect, ok = parseInt(args[2]); !ok {
			vsys.Println("selfhost: spawn expected-status must be an integer: " + args[2])
			vsys.Exit(2)
		}
	}
	for i := int64(1); i <= count; i++ {
		prefix := "selfhost: spawn " + vsys.Itoa64(i) + "/" + vsys.Itoa64(count) +
			" " + image
		status, ms, err := runStep(step{label: "spawn", image: image})
		if err != nil {
			// No status at all: the child never left the registry with one.
			vsys.Println(prefix + " NO-STATUS err=" + err.Error() +
				" budget_s=" + vsys.Itoa64(stepBudgetNs/1000000000))
			vsys.Println("selfhost: spawn verdict=" + vsys.Itoa64(i-1) + "-of-" +
				vsys.Itoa64(count) + "-survived")
			vsys.Exit(1)
		}
		vsys.Println(prefix + " status=" + vsys.Itoa64(status) +
			" ms=" + vsys.Itoa64(ms))
		if expect >= 0 && status != expect {
			// The child that dies is the one whose status does not match; a
			// tombstone arrives here as the kernel's own 139.
			vsys.Println(prefix + " unexpected status (expected " + vsys.Itoa64(expect) + ")")
			vsys.Println("selfhost: spawn verdict=" + vsys.Itoa64(i-1) + "-of-" +
				vsys.Itoa64(count) + "-survived")
			vsys.Exit(1)
		}
	}
	vsys.Println("selfhost: spawn verdict=" + vsys.Itoa64(count) + "-of-" +
		vsys.Itoa64(count) + "-survived")
}

// parseInt is the tiny decimal reader the experiment's argv needs; vsys has
// Itoa64 but no Atoi, and this file is not going to grow a strconv.
func parseInt(s string) (int64, bool) {
	if s == "" {
		return 0, false
	}
	n := int64(0)
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			return 0, false
		}
		n = n*10 + int64(s[i]-'0')
	}
	return n, true
}

// runStep spawns one child, waits for it, and reports its exit status and how
// long it took. A spawn failure and a non-zero status are different facts, so
// they are reported differently by the caller.
func runStep(s step) (status int64, ms int64, err error) {
	start := vsys.Nanotime()
	pid, err := vi.Exec(s.image, s.args...)
	if err != nil {
		return -1, 0, err
	}
	// vi.WaitBudget, not vi.Wait: this is Wait's contract with a ceiling that
	// can hold a linker, and it is the ONE copy of that rule (vi/proc.go) -- a
	// fix there reaches this driver instead of silently missing a second copy.
	status, err = vi.WaitBudget(pid, stepBudgetNs)
	if err != nil {
		return -1, 0, err
	}
	return status, (vsys.Nanotime() - start) / 1000000, nil
}
