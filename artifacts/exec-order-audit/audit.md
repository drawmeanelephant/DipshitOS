# exec-order audit — the fleet's `exec` ordering (claim #1193)

Class-A only: no VM was needed for the audit, the guard, or the self-test.
Every number below is reproduced by `fleet-sweep.py` (same directory) and
`guard-evidence.txt` was generated from this branch, not transcribed.

## Why this exists

`exec` **loads a program, spawns it as an EL0 task, and returns**. It does not
wait. The console echoes command lines, so a boot script that launches a
program and then does anything else looks fine in the log while the ordering it
assumed is already gone.

That is not hypothetical: it cost a full gate run in #1188, where
`live-oliver`'s first spec drove a second invocation and a `vf rm` between them
while the first program was still writing — the `vf rm` reported the file
missing because the write had not landed yet.

## Method

Parse `tools/gate/specs/*.spec` exactly as the guard does (heredoc bodies by
name; logical `vgate_run` lines with backslash continuations joined; flag
values in single, double, or bare spelling), then classify every run whose
scripts launch a program by *how the run ends* and *whether anything anchors it
on guest output*:

- **no `--script-expect`** — the run is bounded by `--timeout` (idiom 3).
- **ends on a program marker** — no marker the scripts could have supplied, so
  the VM stops on the program's own output (idiom 1).
- **anchor gate, ends on a script marker** — a stage gate waits on a marker no
  script supplies (usually the guest's, e.g. `calc: ready`), so the run is
  sequenced even though its stop trigger is a script line.
- **ends on a script marker, unanchored** — flagged: the run can go green while
  the program it launched is still starting.

## Measured

```
specs scanned                        : 211
specs whose scripts launch a program : 142
runs whose scripts launch a program  : 198
   no-expect (timeout-ordered)         : 16
   anchor gate, ends on script marker  : 82
   ends on script marker, unanchored   : 3      <- flagged
   ends on program marker (graded)     : 97
   (sum check 198)

scripts launching >1 program (one boot) : 38  across 32 specs
vf file-channel op after an exec        : 0
```

So the multi-exec concern the sweep started from is real and widespread — 32
specs launch two or more programs from a single script, five of them nine or
more (`live-m16-resources`, `live-scale` ×9; `live-ipc` ×7, `live-m16-composition` ×7,
`live-wasm` ×5, `live-wm1` ×5). What makes them safe is not the number of
programs: it is the end trigger. 97 runs end on program output, 82 are anchored
by a guest marker, 16 lean on `--timeout`, and exactly **3** had nothing.

## The 3 flagged runs, and their verdicts

| spec | shape | verdict |
|---|---|---|
| `go-hello.spec` | `exec GOHELLO.ELF` then `echo go-hello-done`; run ends on it | **declared `assert-proven`** — the asserts read four markers only the Go program prints (`heap: wrote 1048576 bytes`, `gc: cycle completed`, `virelai-go OK`), so a program that never ran still fails the run. Residual risk recorded: the whole program runtime sits inside the 1.5 s `--script-expect-tail` window, so a loaded host gives a flaky FAIL, never a false pass. Observed in `artifacts/go-hello/go-hello-serial-01.log`: the echoed `echo go-hello-done` at line 71, the program's own markers at 78–81. |
| `live-jobs.spec` | `exec … &` ×2 + `fg 1`/`fg 2`, ends on `echo jobs-done` | **declared `self-sequenced`** — `fg 2` reaps `STATUS43.BIN` before the closing marker is echoed, and the python assert counts exactly that `Done: … (exit=43)` line. Verified against `artifacts/claim-1751-m19-p7/live-jobs-serial-01.log`: `[2] Done` at line 71, `jobs-done` at line 75. `fg 1` returns early by design (bounded wait on the eternal child) and nothing asserted after it needs `COUNTER.BIN` output. |
| `live-chain.spec` | `exec NOTEXIST.BIN ; echo exit=$?`, ends on `echo chain-done` | **declared `intentional`** — the only `exec` in the script targets a binary that is not staged, so it fails synchronously and no program is ever running when the marker is echoed. The gate is asserting the refusal (`not found on the host share`, `exit=1`). |

Three declarations, no spec rewritten. All three are printed by the guard on
every run, so the promises stay visible rather than buried.

## Findings that are not declarations

1. **`live-wm3-taskbar.spec` gates on a marker its own script supplies.**
   Runs B1 and B2 pass `--script3-after 'taskbar-go'` and
   `--pointer-virtio-after 'taskbar-go'`, but `taskbar-go` is `echo`ed by the
   spec's own `s2-B1.txt` / `s2-B2.txt`. Those two gates therefore fire on the
   script's own echo — they are pacing delays, not readiness gates. The run's
   real guest anchor is `--script2-after 'calc: ready'`, so the run is still
   anchored and the guard does not flag it. This is what the guard's anchor
   rule is for, and it is why a gate marker now has to come from outside the
   scripts to count (fixture: `vacuous-gate.spec`). Reported on #972 (the WM3
   card) rather than silently "fixed": the semantics are the spec author's call.
2. **The same spec launches `NOTEPAD.BIN` with no readiness gate** while its
   asserts need the notepad window (`dui: windows=… focused=2`). `CALC` is
   gated (`calc: ready`), `NOTEPAD` is not. Same report.
3. **The `--script-expect-tail` window is a fleet-wide assumption.** Any run
   that ends on a marker the program prints *after* it is fully done is relying
   on the default 1.5 s tail to capture the reap line. `go-hello` is the one
   spec where the whole program runtime fits inside that window; that is
   recorded in its declaration rather than left implicit.

## Limits of the guard — stated, not papered over

- Only two shapes are mechanically detectable: a run that ends on a
  script-supplied marker with no anchor gate, and a `vf` operation following an
  `exec` in one script. A spec that launches two programs from one script and
  sequences them some other way is the author's to prove.
- A stage gate counts as an anchor when at least one of its markers is not
  supplied by any script the run forwards. The shell prompt (`virelai>`) counts
  — the guest prints it. That is deliberately lenient: it is the fleet's
  dominant `--script-after` idiom.
- Declarations are trusted once the class name is valid. They are printed, not
  verified, because the property they assert ("these asserts read program
  output") is not decidable from spec text.
- The 38 multi-exec scripts are *not* individually proven correct. The audit
  says what their end trigger is; it does not claim every assert inside them is
  order-independent.

## One correction to the first pass

The first cut of the classifier reported 96 runs with no `--script-expect` and
32 multi-exec scripts. That was wrong, and the cause is worth keeping: the
marker parser required a leading single quote, so every `--script-expect "…"`
(double-quoted) read as *no marker at all*. Corrected: 16 no-expect runs, 38
multi-exec scripts. The guard had the same bug; both now accept single-quoted,
double-quoted, and bare values, and `vacuous-gate.spec` plus the four `fail/`
fixtures pin the shapes the fixed parser must still catch.

## Evidence

| file | what |
|---|---|
| `fleet-sweep.txt` | the numbers above, as produced by `fleet-sweep.py` |
| `fleet-sweep.py` | the classifier (tracked so the numbers are reproducible) |
| `guard-evidence.txt` | the guard over the real fleet, over `fail/`, over `pass/`, and the mutation run proving the self-test has teeth |
| `artifacts/go-hello/go-hello-serial-01.log` | the go-hello tail-window observation |
| `artifacts/claim-1751-m19-p7/live-jobs-serial-01.log` | the `fg 2` ordering observation |
