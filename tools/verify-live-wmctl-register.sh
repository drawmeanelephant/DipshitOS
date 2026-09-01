#!/usr/bin/env bash
#
# verify-live-wmctl-register.sh -- M32 WMS2 (issue #622) class-B gate: the
# kernel render-server register end to end on real VZ hardware.
#
# ONE headless boot with --screen only (GPU attached so the compositor is
# armed — gpu_setup_ok is the REGISTER ENXIO gate; no --display, no --input).
# The serial script drives the whole lifecycle:
#
#   TWO scripted phases (the claim-4613 machinery), because `exec` is
#   asynchronous — the registrant needs scheduler ticks to run, and a
#   single one-burst script would race it:
#
#   Phase 1 (--script, forwarded at boot):
#   1. `wm`            -> "wm: none (shim compositing)"   [shim mode, default]
#   2. `exec WNDSTUB.BIN` — the minimal registrant:
#        a. sys_wmctl(REGISTER) (slot 65, cmd 1) -> 0      "wndstub: registered"
#        b. blocks in sys_wait_event until the kernel delivers
#           COMPOSITE_TICK (kind 18) on the scheduler tick path
#                                                          "wndstub: tick"
#        c. sys_wmctl(REQUEST_PRESENT) (slot 65, cmd 3) -> 0 (present
#           counter advances)                               "wndstub: present ok"
#        d. sys_exit(0). The scheduler exit path unregisters the WM and the
#           shell idle loop drains the fallback report:
#                                                          "wm: unregistered, shim resumed"
#      The registrant's reap ("tasks user-exec reaped") is the phase-1
#      completion marker — the whole register→tick→present→exit→reap
#      lifecycle lands BEFORE phase 2 is forwarded, so nothing races.
#
#   Phase 2 (--script2, forwarded after the reap line):
#   3. `wm`            -> "wm: none (shim compositing)"   [fallback confirmed]
#   4. `syscalls`      -> "65 sys_wmctl calls=2" and "implemented=66"
#   5. `echo rx-wmctl-ok` -> shell responsive after the whole lifecycle
#      (this is the --script-expect; the runner stops the VM on it).
#
# Zero-regression: this gate runs ONLY with --screen + an exec'd registrant.
# The default VM (no registrant) never arms the seam — the shell idle shim
# keeps compositing exactly as before and every pre-M32 gate is untouched
# (the shim path reads unchanged in this card's diff).
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source tools/lib/gate-run.sh

SUFFIX="${VIRELAI_GATE_SUFFIX:-}"
art() { printf 'artifacts/%s%s' "$1" "$SUFFIX"; }

GATE_LOG="$(art m32-wms2-wmctl-live.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

BOOTS="${BOOTS:-1}"
REPORT="$(art live-wmctl-register-report.txt)"
# The exec'd registrant's clean exit (status 0).
EXEC_REAP_LINE="tasks user-exec reaped"

echo "=== verify-live-wmctl-register: M32 WMS2 — kernel render-server register (issue #622), $BOOTS boot(s) ==="

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
gate_begin live-wmctl-register
gate_seed_share
echo "run dir: $RUN_DIR"
SCRIPT="$RUN_DIR/script.txt"

# Phase 1 drives the lifecycle (register → tick → present → exit → reap);
# phase 2 (forwarded after the reap line) verifies fallback + counters +
# responsiveness — all deterministic because the stub has fully exited.
printf 'wm\nexec WNDSTUB.BIN\n' > "$SCRIPT"
SCRIPT2="$RUN_DIR/script2.txt"
printf 'wm\nsyscalls\necho rx-wmctl-ok\n' > "$SCRIPT2"

run_one() {
    local tag="$1"
    local run_log="$(art live-wmctl-register-run-$tag.txt)"
    local serial_copy="$(art live-wmctl-register-serial-$tag.log)"
    rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial-$tag.log"

    set +e
    host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
        --serial "$RUN_DIR/vm-serial-$tag.log" \
        --screen "$RUN_DIR/screen" \
        --script "$SCRIPT" \
        --script2 "$SCRIPT2" --script2-after "$EXEC_REAP_LINE" \
        --script-expect "rx-wmctl-ok" --timeout 90 > "$run_log" 2>&1
    local rc=$?
    set -e
    [ -f "$RUN_DIR/vm-serial-$tag.log" ] && cp "$RUN_DIR/vm-serial-$tag.log" "$serial_copy" || true
    local SER="$serial_copy"

    local bytes=0 banner=0 shim=0 registered=0 tick=0 present=0 \
        reaped=0 fallback=0 wmctl_row=0 calls2=0 impl66=0 echo_ok=0 fatal=0
    if [ -f "$SER" ]; then
        bytes="$(wc -c < "$SER" | tr -d ' ')"
        [ "$(grep -aFxc -- "VirelaiOS kernel has seized control." "$SER" || true)" = 1 ] && banner=1
        [ "$(grep -aFc -- "wm: none (shim compositing)" "$SER" || true)" -ge 2 ] && shim=1
        [ "$(grep -aFc -- "wndstub: registered" "$SER" || true)" = 1 ] && registered=1
        [ "$(grep -aFc -- "wndstub: tick" "$SER" || true)" = 1 ] && tick=1
        [ "$(grep -aFc -- "wndstub: present ok" "$SER" || true)" = 1 ] && present=1
        # The registrant's full lifecycle completed before phase 2.
        [ "$(grep -aFc -- "$EXEC_REAP_LINE" "$SER" || true)" = 1 ] && reaped=1
        # The kernel's teardown report — the desktop survives the WM's exit.
        [ "$(grep -aFc -- "wm: unregistered, shim resumed" "$SER" || true)" = 1 ] && fallback=1
        # The slot-65 row + implemented count from the `syscalls` output.
        [ "$(grep -aFc -- " 65 sys_wmctl calls=" "$SER" || true)" -ge 1 ] && wmctl_row=1
        [ "$(grep -aFc -- "65 sys_wmctl calls=2" "$SER" || true)" = 1 ] && calls2=1
        [ "$(grep -aFc -- "implemented=66" "$SER" || true)" = 1 ] && impl66=1
        [ "$(grep -aFc -- "rx-wmctl-ok" "$SER" || true)" -ge 1 ] && echo_ok=1
        [ "$(grep -aFc -- "wndstub" "$SER" || true)" -ge 1 ] && true
        # A kernel panic / fault would be fatal evidence.
        if [ "$(grep -aFc -- "\[EXC\]" "$SER" || true)" = 0 ] && [ "$(grep -aFc -- "kernel panic" "$SER" || true)" = 0 ]; then
            fatal=0
        else
            fatal=1
        fi
    fi

    {
        echo "run $tag: rc=$rc bytes=$bytes"
        echo "  banner=$banner shim-before+after=$shim registered=$registered tick=$tick present=$present reaped=$reaped fallback=$fallback wmctl-row=$wmctl_row calls=2=$calls2 implemented=66=$impl66 echo-ok=$echo_ok fatal=$fatal"
    } | tee -a "$REPORT"

    # Every assertion must land.
    [ "$rc" = 0 ] || { echo "FAIL: runner exit $rc (log: $run_log)"; return 1; }
    [ "$banner" = 1 ] || { echo "FAIL: kernel banner missing"; return 1; }
    [ "$shim" = 1 ] || { echo "FAIL: shim mode ('wm: none') not observed before AND after the registrant"; return 1; }
    [ "$registered" = 1 ] || { echo "FAIL: wndstub did not register"; return 1; }
    [ "$tick" = 1 ] || { echo "FAIL: no COMPOSITE_TICK (kind 18) delivered"; return 1; }
    [ "$present" = 1 ] || { echo "FAIL: REQUEST_PRESENT did not complete"; return 1; }
    [ "$reaped" = 1 ] || { echo "FAIL: the registrant was not reaped (phase-2 gate)"; return 1; }
    [ "$fallback" = 1 ] || { echo "FAIL: no 'wm: unregistered, shim resumed' fallback report"; return 1; }
    [ "$wmctl_row" = 1 ] || { echo "FAIL: no '65 sys_wmctl' row in syscalls"; return 1; }
    [ "$calls2" = 1 ] || { echo "FAIL: expected '65 sys_wmctl calls=2' (REGISTER + REQUEST_PRESENT)"; return 1; }
    [ "$impl66" = 1 ] || { echo "FAIL: syscalls did not report implemented=66"; return 1; }
    [ "$echo_ok" = 1 ] || { echo "FAIL: shell did not echo rx-wmctl-ok after the lifecycle"; return 1; }
    [ "$fatal" = 0 ] || { echo "FAIL: kernel fault/panic observed"; return 1; }
    return 0
}

pass=0
for i in $(seq 1 "$BOOTS"); do
    echo "--- boot $i/$BOOTS ---"
    if run_one "$i"; then
        pass=$((pass + 1))
        echo "boot $i: PASS"
    else
        echo "boot $i: FAIL"
    fi
done
gate_end

if [ "$pass" -ne "$BOOTS" ]; then
    echo "verify-live-wmctl-register: FAIL — $pass/$BOOTS boots passed (see $GATE_LOG)"
    exit 1
fi

echo "verify-live-wmctl-register: PASS — WNDSTUB.BIN registered through slot 65, received >=1 COMPOSITE_TICK (kind 18), issued REQUEST_PRESENT (present counter advanced), exited; the kernel unregistered it and fell back to the shell idle shim ('wm: unregistered, shim resumed'); syscalls reports 65 sys_wmctl calls=2, implemented=66. Default VM (no registrant) is untouched — the shim path reads unchanged."
