# Exercise 3 — Goroutines on two cores

**Goal:** watch Go concurrency run on VirelaiOS's two vCPUs: 8 goroutines
(N > GOMAXPROCS=2) complete through kernel slot-73 threads (`sys_thread`),
park on the slot-74 futex, and the monitor's `smp` report names the Go
binary running on a **secondary core**.

**Time:** ~3 minutes.

## Steps

From the repository root:

```bash
just gate go-goroutines
```

The gate boots the OS, execs `GOROUT.ELF`, waits for the program's done
line, then runs the monitor's `syscalls` and `smp` reports while holding
the window open.

## Expected output (key lines)

The gate's assertion summary — every row with `=1` was observed:

```
serial-contains [exec: loaded GOROUT.ELF]=1
serial-contains [go-goroutines procs=2]=1
serial-contains [go-goroutines done n=8 counter=8]=1
serial-contains [task=GOROUT.ELF]=1
serial-contains [smp: secondary runs=]=1
go-goroutines python asserts OK: sys_thread=3 sys_futex=13
vgate go-goroutines: PASS (1/1 runs)
```

(The exact `sys_thread`/`sys_futex` counts vary per run; the gate asserts
`sys_thread >= 2` and at least one futex park.)

## Pass/fail check

- **PASS** if `go-goroutines: PASS` is printed (the gate also asserts
  `sys_thread` ≥ 2 calls, `sys_futex` present, and the cross-core
  `task=GOROUT.ELF` smp line — a green run proves all of them).
- **FAIL** if the gate prints `FAILED` — capture the gate output and see
  Troubleshooting in the [README](README.md).

## What this proves

| Observed | Capability |
|---|---|
| `done n=8 counter=8` | M:N scheduler: 8 goroutines on 2 Ps, atomic counter correct |
| `sys_thread` ≥ 2 | kernel slot-73: Ms mapped onto same-process kernel tasks (sysmon + GC Ms) |
| `sys_futex` present | slot-74: scheduler locks park in the kernel instead of spinning |
| `task=GOROUT.ELF` on a secondary core | cross-core migration of a Go M |
