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
// The loop is TWO children, not three, and that is a wall rather than a
// choice: a third sequential exec from one EL0 parent currently dies in the
// guest (observed here as a level-3 data abort in the child, `fault:
// HELLO2.ELF far=0x47c29000 ec=0x24 esr=0x9200004f`, status 139). The same
// wall is already documented against Go children in go-sh.spec, which stays at
// two children for it: "A THIRD sequential exec from one EL0 parent currently
// dies in the Go runtime's own schedinit (observed twice: refill of span with
// reusable pointers -> fatal exit 2) ... follow-up owed to the runtime/kernel
// owners" (issue #1449). The symptom here differs from that one, so this file
// claims only what it saw. The RUN step is therefore the gate's second boot
// (one monitor `exec` of the product this loop built), which is also how
// go-hello run 08 executes it.
//
// Every argv line below is checked against the kernel's 8 x 32-byte argv block
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

// stepBudgetNs bounds one child's wait. vi.Wait's own budget (vi/proc.go) is
// 120 s and is the SHELL's foreground-child contract; a linker that reads
// ~15 MiB of archives out of the share at the 2048-byte EL0 read cap is not
// that workload, and reporting its budget as a failure would be wrong. This is
// a ceiling, not a prediction: each step's real elapsed time is printed, so
// the number that matters is in the log either way.
const stepBudgetNs = int64(900) * int64(1e9)

type step struct {
	label string
	image string
	args  []string
}

func main() {
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
			vsys.Println("selfhost: FAIL " + s.label + " err=" + err.Error())
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

// runStep spawns one child, waits for it, and reports its exit status and how
// long it took. A spawn failure and a non-zero status are different facts, so
// they are reported differently by the caller.
func runStep(s step) (status int64, ms int64, err error) {
	start := vsys.Nanotime()
	pid, err := vi.Exec(s.image, s.args...)
	if err != nil {
		return -1, 0, err
	}
	status, err = waitFor(pid)
	if err != nil {
		return -1, 0, err
	}
	return status, (vsys.Nanotime() - start) / 1000000, nil
}

// errWaitBudget is what a step returns when its child outlives the budget.
// Distinct from a non-zero status on purpose: "it never finished" and "it
// finished badly" are different findings about the guest.
type budgetError struct{}

func (budgetError) Error() string { return "wait budget expired" }

// waitFor is vi.Wait's contract with a budget that can hold a linker: poll the
// registry, and count a pid that was seen running and then left it as status 0
// (reaped and recycled), which is the same rule the shell's waits pin.
func waitFor(pid int64) (int64, error) {
	deadline := vsys.Nanotime() + stepBudgetNs
	seen := false
	for vsys.Nanotime() < deadline {
		status, state := vi.Probe(pid)
		switch state {
		case vi.ProbeExited:
			return status, nil
		case vi.ProbeRunning:
			seen = true
		case vi.ProbeAbsent:
			if seen {
				return 0, nil
			}
		}
		vsys.Sleep(1)
	}
	return -1, budgetError{}
}
