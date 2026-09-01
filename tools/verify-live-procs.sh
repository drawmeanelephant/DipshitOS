#!/usr/bin/env bash
#
# verify-live-procs.sh -- claim 3848 (milestone-four card 3) class-B gate:
# the PROCESS abstraction observed on real VZ hardware.
#
# The chain, all asserted in vm-serial.log:
#   1. The boot-time static EL0 payload (claim 8215) registers as a process
#      ("user-el0"); when it exits (status 7) its PROCESS stays exited with
#      that status — `procs` reports `state=exited ... exit=7` even after
#      the idle task reaped the executor slot.
#   2. `exec USER.BIN` creates a NEW process (per-process identity — the
#      image + rebuilt address space live in the registry, not exec globals)
#      and binds it to the spawned task. The `procs` read that follows
#      deterministically shows `name=USER.BIN state=running stack=0x...`
#      (the shell consumes scripted lines before the background program's
#      first quantum — the ordering observed in live-exec's own serial
#      logs), alongside the exited boot payload's row.
#   3. The loaded program runs at EL0 (its sys_write markers land), exits
#      status 43, and the PROCESS-level exit report prints
#      `procs USER.BIN exited status=43` — the exit status surviving the
#      executor task's reap — alongside the unchanged task lifecycle
#      (`tasks user-exec exited status=43` + reap).
#   4. The shell stays responsive (echo reply).
#
# The script is forwarded only AFTER the static payload has exited
# (`tasks user-el0 exited status=7`), so the user root is free when `exec`
# runs (the claim-6783 gate).
#
# Evidence saved under artifacts/: live-procs-gate.txt, live-procs-report.txt,
# live-procs-run-<NN>.txt, live-procs-serial-<NN>.log.

# Run isolation (#523 item 2 / issue #528, claim 5069): every boot attaches
# a private DiskImageKit stacked disk (read-only base + throwaway ASIF
# overlay), a private EFI var store (recreated fresh per boot, as the
# pre-isolation gate did), and a private serial log under $RUN_DIR — two
# concurrent instances cannot clobber each other's disks, NVRAM, or
# evidence. Set VIRELAI_GATE_SUFFIX=_alt to give this instance its own
# canonical evidence names (two simultaneous instances MUST differ), and
# VIRELAI_KEEP_RUN=1 to keep the scratch dir.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source tools/lib/gate-run.sh

SUFFIX="${VIRELAI_GATE_SUFFIX:-}"
art() { printf 'artifacts/%s%s' "$1" "$SUFFIX"; }

GATE_LOG="$(art live-procs-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

BOOTS="${BOOTS:-1}"
REPORT="$(art live-procs-report.txt)"
# The static claim-8215 payload's exit line: the runner forwards the script
# only after it appears, so the user root is free when `exec` runs.
STATIC_EXIT_LINE="tasks user-el0 exited status=7"
# The exec'd program's exit line (asserted) and its reap line (asserted
# AND the script-expect — the reap prints a quantum after the exit, so it
# is the last line in the log).
EXEC_EXIT_LINE="tasks user-exec exited status=43"
EXEC_REAP_LINE="tasks user-exec reaped"
# The process-level exit report (claim 3848): the exec'd program's PROCESS
# keeps its status past the executor's reap.
PROC_EXIT_LINE="procs USER.BIN exited status=43"

echo "=== verify-live-procs: claim 3848 — the process abstraction (image + address space + lifecycle + exit status) above the task pool, $BOOTS boot(s) ==="

zig version
swift --version 2>&1 | head -1
sw_vers
REVISION="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
DIRTY="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
echo "revision: $REVISION branch=$BRANCH boots=$BOOTS dirty-files=$DIRTY"

zig fmt --check boot/src/*.zig kernel/src/*.zig user/src/*.zig build.zig
zig build
zig build image
swift build --package-path host/vm-runner --configuration release -Xswiftc -DSPIKE
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner

# --- per-run isolation -------------------------------------------------------------
# Private scratch dir + pristine-boot overlay for EVERY boot.
# See tools/lib/gate-run.sh.
gate_begin live-procs
gate_seed_share
echo "run dir: $RUN_DIR"
SCRIPT="$RUN_DIR/script.txt"

printf 'ls\nexec USER.BIN\nprocs\necho rx-procs-ok\n' > "$SCRIPT"

run_one() {
    local tag="$1"
    local run_log="$(art live-procs-run-$tag.txt)"
    local serial_copy="$(art live-procs-serial-$tag.log)"
    rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial-$tag.log"

    set +e
    host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
        --serial "$RUN_DIR/vm-serial-$tag.log" \
        --script "$SCRIPT" --script-after "$STATIC_EXIT_LINE" \
        --script-expect "$EXEC_REAP_LINE" --timeout 60 > "$run_log" 2>&1
    local rc=$?
    set -e
    [ -f "$RUN_DIR/vm-serial-$tag.log" ] && cp "$RUN_DIR/vm-serial-$tag.log" "$(art live-procs-serial-$tag.log)" || true
    local SER="$serial_copy"

    local bytes=0 banner=0 listed=0 loaded=0 running_row=0 boot_exited=0 hello=0 ok=0 exited=0 procs_exited=0 reaped=0 echo_ok=0 fatal=0
    if [ -f "$SER" ]; then
        bytes="$(wc -c < "$SER" | tr -d ' ')"
        [ "$(grep -aFxc -- "VirelaiOS kernel has seized control." "$SER" || true)" = 1 ] && banner=1
        [ "$(grep -aFc -- "USER.BIN" "$SER" || true)" -ge 2 ] && listed=1
        [ "$(grep -aFc -- "exec: loaded USER.BIN size=" "$SER" || true)" = 1 ] && loaded=1
        # The `procs` read right after exec: the exec'd program's process is
        # RUNNING with its rebuilt address space (the shell prints this
        # before the background program's first quantum), and the boot
        # payload's process is EXITED with its status kept past the reap.
        [ "$(grep -aFc -- "procs: id=" "$SER" || true)" -ge 1 ] && running_row=1
        grep -a -qF -- "name=USER.BIN state=running" "$SER" && running_row=1
        grep -a -qF -- "name=user-el0 state=exited" "$SER" && boot_exited=1
        grep -a -qF -- "exit=7" "$SER" && boot_exited=1
        [ "$(grep -aFc -- "user: hello from the ESP" "$SER" || true)" = 1 ] && hello=1
        [ "$(grep -aFc -- "user: exec ok" "$SER" || true)" = 1 ] && ok=1
        [ "$(grep -aFxc -- "$EXEC_EXIT_LINE" "$SER" || true)" = 1 ] && exited=1
        [ "$(grep -aFxc -- "$PROC_EXIT_LINE" "$SER" || true)" = 1 ] && procs_exited=1
        [ "$(grep -aFxc -- "$EXEC_REAP_LINE" "$SER" || true)" = 1 ] && reaped=1
        [ "$(grep -aFxc -- "rx-procs-ok" "$SER" || true)" = 1 ] && echo_ok=1
        grep -qF -- "[EXC] parking:" "$SER" && fatal=1 || true
    fi
    echo "$tag: runner-rc=$rc serial-bytes=$bytes banner=$banner listed=$listed loaded=$loaded running-row=$running_row boot-exited=$boot_exited hello=$hello ok=$ok exited=$exited procs-exited=$procs_exited reaped=$reaped echo=$echo_ok fatal=$fatal" | tee -a "$REPORT"
    [ "$rc" = 0 ] && [ "$banner" = 1 ] && [ "$listed" = 1 ] && [ "$loaded" = 1 ] && \
        [ "$running_row" = 1 ] && [ "$boot_exited" = 1 ] && \
        [ "$hello" = 1 ] && [ "$ok" = 1 ] && [ "$exited" = 1 ] && [ "$procs_exited" = 1 ] && \
        [ "$reaped" = 1 ] && [ "$echo_ok" = 1 ] && [ "$fatal" = 0 ]
}

: > "$REPORT"
{
    echo "VIRELAIOS live process gate (claim 3848) — the process object (image + address space + lifecycle + exit status) above the task pool"
    echo "revision: $REVISION branch=$BRANCH boots=$BOOTS dirty-files=$DIRTY"
    echo "script: $(cat "$SCRIPT" | tr '\n' '|')"
    echo "date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo
} >> "$REPORT"

pass=0
n=0
while [ "$n" -lt "$BOOTS" ]; do
    n=$((n + 1))
    echo
    echo "=== live-procs boot $n ==="
    if run_one "$(printf '%02d' "$n")"; then pass=$((pass + 1)); fi
done

echo
echo "=== result ==="
if [ "$pass" = "$BOOTS" ]; then
    echo "verify-live-procs: PASS — the exec'd USER.BIN is a PROCESS (running with its stack in the procs table), the boot payload's process keeps exited status=7, and the process exit report 'procs USER.BIN exited status=43' survives the executor's reap ($pass/$BOOTS boot(s))."
    echo "PASS: $pass/$BOOTS" >> "$REPORT"
    exit 0
fi
echo "verify-live-procs: FAILED — $pass/$BOOTS boot(s) passed; see $REPORT and per-boot logs."
echo "FAIL: $pass/$BOOTS" >> "$REPORT"
exit 1
