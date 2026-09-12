#!/usr/bin/env python3
"""Apply the GOOS=virelai scheduler gates to the fork's proc.go
(issue #1163, phase 0a). Idempotent; called by tools/go/apply.sh.

Phase 0a has no kernel thread_create (slot 73 lands in phase 0b; slot 72 is
sys_getrandom, #1166), so every
path that funnels into newosproc must be gated, and the single M must never
park (nothing else exists to wake it). One const, canCreateM, carries the
thread-creation delta; these deltas disappear in phase 0b.
"""
import sys

p = sys.argv[1]
s = open(p).read()

if "canCreateM" in s:
    print("patch_proc: already applied")
    sys.exit(0)

anchor = 'const haveSysmon = GOARCH != "wasm" && GOOS != "virelai"'
assert anchor in s, "haveSysmon anchor missing (apply the haveSysmon patch first)"
s = s.replace(
    anchor,
    anchor + '\nconst canCreateM = GOARCH != "wasm" && GOOS != "virelai"',
    1,
)

# 1. The lazy template thread.
old = '''func startTemplateThread() {
	if GOARCH == "wasm" { // no threads on wasm yet
		return
	}'''
new = '''func startTemplateThread() {
	if GOARCH == "wasm" || GOOS == "virelai" { // no threads on wasm or virelai yet
		return
	}'''
assert old in s, "startTemplateThread anchor missing"
s = s.replace(old, new, 1)

# 2. startTheWorld's spare-M handoff.
old = '''		} else {
			// Start M to run P.  Do not start another M below.
			newm(nil, p, -1)
		}'''
new = '''		} else if canCreateM {
			// Start M to run P.  Do not start another M below.
			newm(nil, p, -1)
		} else {
			// issue #1163 phase 0a: no kernel thread_create yet; the
			// single-P invariant keeps this path unreachable.
			p.m = 0
		}'''
assert old in s, "startTheWorld anchor missing"
s = s.replace(old, new, 1)

# 3. startm's no-M fallback.
old = '''	nmp := mget()
	if nmp == nil {
		// No M is available, we must drop sched.lock and call newm.'''
new = '''	nmp := mget()
	if nmp == nil && !canCreateM {
		// issue #1163 phase 0a: no kernel thread_create yet. Drop the
		// handoff; the single-M scheduler retries on its next pass.
		releasem(mp)
		return
	}
	if nmp == nil {
		// No M is available, we must drop sched.lock and call newm.'''
assert old in s, "startm anchor missing"
s = s.replace(old, new, 1)

# 4. LockOSThread bookkeeping must never actually bind the main G to the
# single M: a locked main G wedges stoplockedm (its P holds runnable
# goroutines — gcenable's bgsweep/bgscavenge — that only the locked M could
# run, and nothing can wake a parked M). The wasm pattern: keep the
# lockedExt accounting (so the deferred unlock stays balanced), skip the
# binding.
old = '''func dolockOSThread() {
	if GOARCH == "wasm" {
		return // no threads on wasm yet
	}'''
new = '''func dolockOSThread() {
	if GOARCH == "wasm" || GOOS == "virelai" {
		return // no threads on wasm or virelai yet (issue #1163 phase 0a)
	}'''
assert old in s, "dolockOSThread anchor missing"
s = s.replace(old, new, 1)

old = '''func dounlockOSThread() {
	if GOARCH == "wasm" {
		return // no threads on wasm yet
	}'''
new = '''func dounlockOSThread() {
	if GOARCH == "wasm" || GOOS == "virelai" {
		return // no threads on wasm or virelai yet (issue #1163 phase 0a)
	}'''
assert old in s, "dounlockOSThread anchor missing"
s = s.replace(old, new, 1)

# 5. stopm must never park the only M.
old = '''func stopm() {
	gp := getg()'''
new = '''func stopm() {
	if GOOS == "virelai" {
		// issue #1163 phase 0a: the single M must never park — nothing
		// else exists to wake it (no sysmon, no second thread). Yield to
		// the kernel scheduler and let the caller retry findRunnable.
		// Removed with slot 73 (thread_create).
		osyield()
		return
	}
	gp := getg()'''
assert old in s, "stopm anchor missing"
s = s.replace(old, new, 1)

open(p, "w").write(s)
print("patch_proc: thread gates applied")
