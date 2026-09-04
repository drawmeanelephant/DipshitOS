#!/usr/bin/env bash
#
# verify-live-tabwm.sh -- M39 TWM3 (issue #930) class-B gate: the browser-style
# tabbed window manager server (TABWM.BIN) end to end on real VZ hardware.
#
# ONE headless boot with --screen only (GPU attached so the compositor is
# armed). The serial script drives the whole tabbed desktop lifecycle:
#
#   Phase 1 (--script, forwarded at boot):
#   1. `tabwm`          -> "tabwm: none (shim compositing)"   [shim mode, default]
#   2. `tabwm start`    -> launches TABWM.BIN:
#        a. sys_wmctl(REGISTER) (slot 65, cmd 1) -> "tabwm: registered"
#        b. maps scanout surface via M33 Seam B
#        c. renders left sidebar and canvas backdrop -> "tabwm: sidebar-rendered"
#        d. advances present sequence -> "tabwm: present"
#   3. `exec WINLOOP.BIN` -> opens user window id=2:
#        a. "winloop: open id=2"
#        b. kernel notifies TABWM via wm_window_kind (kind 20)
#        c. TABWM dynamically adds tab, computes viewport, sets window rect,
#           and switches active tab -> "tabwm: tab-switch"
#        d. "winloop: loop ok"
#
#   Phase 2 (--script2, forwarded after "winloop: loop ok" appears):
#   4. `tabwm`          -> "tabwm: registered pid=..."
#   5. `echo rx-tabwm-ok` -> shell responsive after complete lifecycle
#      (--script-expect; the runner stops the VM on it).
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source tools/lib/gate-run.sh

SUFFIX="${VIRELAI_GATE_SUFFIX:-}"
art() { printf 'artifacts/%s%s' "$1" "$SUFFIX"; }

GATE_LOG="$(art m39-twm3-tabwm-live.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

BOOTS="${BOOTS:-1}"
REPORT="$(art live-tabwm-report.txt)"
WINLOOP_READY_LINE="winloop: loop ok"

echo "=== verify-live-tabwm: M39 TWM3 — tabbed desktop WM server lifecycle (issue #930), $BOOTS boot(s) ==="

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
gate_begin live-tabwm
gate_seed_share
echo "run dir: $RUN_DIR"
SCRIPT="$RUN_DIR/script.txt"

# Phase 1: verify default state, launch TABWM.BIN server, launch WINLOOP.BIN app
printf 'tabwm\ntabwm start\nexec WINLOOP.BIN\n' > "$SCRIPT"
SCRIPT2="$RUN_DIR/script2.txt"
# Phase 2: verify registered server state after app has settled into loop, then echo ok
printf 'tabwm\necho rx-tabwm-ok\n' > "$SCRIPT2"

run_one() {
    local tag="$1"
    local run_log="$(art live-tabwm-run-$tag.txt)"
    local serial_copy="$(art live-tabwm-serial-$tag.log)"
    rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial-$tag.log"

    set +e
    host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
        --serial "$RUN_DIR/vm-serial-$tag.log" \
        --screen "$RUN_DIR/screen" \
        --script "$SCRIPT" \
        --script2 "$SCRIPT2" --script2-after "$WINLOOP_READY_LINE" \
        --script-expect "rx-tabwm-ok" --timeout 90 > "$run_log" 2>&1
    local rc=$?
    set -e
    [ -f "$RUN_DIR/vm-serial-$tag.log" ] && cp "$RUN_DIR/vm-serial-$tag.log" "$serial_copy" || true
    local SER="$serial_copy"

    local bytes=0 banner=0 shim=0 starting=0 registered=0 sidebar=0 present=0 \
        tabwm_pid=0 winloop=0 tab_switch=0 echo_ok=0 fatal=0
    if [ -f "$SER" ]; then
        bytes="$(wc -c < "$SER" | tr -d ' ')"
        [ "$(grep -aFxc -- "VirelaiOS kernel has seized control." "$SER" || true)" = 1 ] && banner=1
        [ "$(grep -aFc -- "tabwm: none (shim compositing)" "$SER" || true)" -ge 1 ] && shim=1
        [ "$(grep -aFc -- "tabwm: starting TABWM.BIN" "$SER" || true)" -ge 1 ] && starting=1
        [ "$(grep -aFc -- "tabwm: registered" "$SER" || true)" -ge 1 ] && registered=1
        [ "$(grep -aFc -- "tabwm: sidebar-rendered" "$SER" || true)" -ge 1 ] && sidebar=1
        [ "$(grep -aFc -- "tabwm: present" "$SER" || true)" -ge 1 ] && present=1
        [ "$(grep -aFc -- "tabwm: registered pid=" "$SER" || true)" -ge 1 ] && tabwm_pid=1
        [ "$(grep -aFc -- "winloop: open id=2" "$SER" || true)" -ge 1 ] && winloop=1
        [ "$(grep -aFc -- "tabwm: tab-switch" "$SER" || true)" -ge 1 ] && tab_switch=1
        [ "$(grep -aFc -- "rx-tabwm-ok" "$SER" || true)" -ge 1 ] && echo_ok=1

        # A kernel panic / fault would be fatal evidence.
        if [ "$(grep -aFc -- "\[EXC\]" "$SER" || true)" = 0 ] && [ "$(grep -aFc -- "kernel panic" "$SER" || true)" = 0 ]; then
            fatal=0
        else
            fatal=1
        fi
    fi

    {
        echo "run $tag: rc=$rc bytes=$bytes"
        echo "  banner=$banner shim=$shim starting=$starting registered=$registered sidebar=$sidebar present=$present tabwm_pid=$tabwm_pid winloop=$winloop tab_switch=$tab_switch echo-ok=$echo_ok fatal=$fatal"
    } | tee -a "$REPORT"

    # Every assertion must land.
    [ "$rc" = 0 ] || { echo "FAIL: runner exit $rc (log: $run_log)"; return 1; }
    [ "$banner" = 1 ] || { echo "FAIL: kernel banner missing"; return 1; }
    [ "$shim" = 1 ] || { echo "FAIL: initial shim mode ('tabwm: none') not observed"; return 1; }
    [ "$starting" = 1 ] || { echo "FAIL: 'tabwm: starting TABWM.BIN' not observed"; return 1; }
    [ "$registered" = 1 ] || { echo "FAIL: TABWM.BIN did not register"; return 1; }
    [ "$sidebar" = 1 ] || { echo "FAIL: TABWM.BIN sidebar did not render"; return 1; }
    [ "$present" = 1 ] || { echo "FAIL: TABWM.BIN present did not occur"; return 1; }
    [ "$tabwm_pid" = 1 ] || { echo "FAIL: 'tabwm: registered pid=' not reported by shell"; return 1; }
    [ "$winloop" = 1 ] || { echo "FAIL: WINLOOP.BIN window open id=2 not observed"; return 1; }
    [ "$tab_switch" = 1 ] || { echo "FAIL: TABWM.BIN tab switch on window open not observed"; return 1; }
    [ "$echo_ok" = 1 ] || { echo "FAIL: shell did not echo rx-tabwm-ok after the lifecycle"; return 1; }
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
    echo "verify-live-tabwm: FAIL — $pass/$BOOTS boots passed (see $GATE_LOG)"
    exit 1
fi

echo "verify-live-tabwm: PASS — TABWM.BIN launched from shell, registered through slot 65, rendered Left Sidebar and Viewport Canvas directly to scanout, advanced present counter, tracked WINLOOP.BIN window creation, allocated viewport, and switched active tab cleanly."
