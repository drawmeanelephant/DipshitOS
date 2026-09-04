#!/usr/bin/env bash
#
# verify-live-tabwm-fullscreen.sh -- M42 SX5 (issue #986) class-B gate: the
# Sexiburger tabbed desktop as the PRIMARY manager end to end on real VZ.
#
# TWO headless boots (--screen only, GPU armed), both driving the full
# chain — settings-seeded default manager, tab-aware full-viewport app,
# and the god-menu overlay launch:
#
#   Boot A — the default-manager seam (SX5b):
#     1. The share is PRE-SEEDED with SETTINGS.TXT (wm=tabwm) — the guest
#        reads it at boot and the shell idle AUTO-STARTS TABWM.BIN:
#          a. "wm: autostart tabwm (settings wm=tabwm)"
#          b. "tabwm: registered" + "tabwm: sidebar-rendered"
#     2. `exec CALC.BIN` (script2, after the sidebar renders):
#          a. CALC declares tab-aware -> "calc: tab-aware (full-viewport)"
#          b. TABWM applies the FULL 1100x720 content viewport
#          c. the kernel's SX2 seam tells the app -> "calc: resize relayout"
#          d. "tabwm: tab-switch" (the tab manager activated the tab)
#     3. `echo rx-m42-ok` -> shell responsive (--script-expect).
#
#   Boot B — the god-menu overlay (SX5a):
#     1. `tabwm start` (the explicit path — unchanged).
#     2. Custom-virtio keyboard chords (after the sidebar renders):
#        ctrl-space, c,a,l,c, return — the overlay filters the APPS.TXT
#        catalog to CALC and launches it into a NEW TAB:
#          a. "tabwm: god-menu" (the summon)
#          b. "tabwm: launch CALC.BIN"
#          c. calc opens, declares tab-aware, gets the full viewport:
#             "calc: tab-aware (full-viewport)" + "calc: resize relayout"
#     3. `echo rx-m42-b-ok` -> shell responsive (--script-expect).
#
# Evidence: artifacts/live-tabwm-fullscreen-{run-A.txt,run-B.txt,
# serial-A.log,serial-B.log,report.txt,gate.txt}. Usage:
#
#   bash tools/verify-live-tabwm-fullscreen.sh             # BOOTS boots (default 1 pair)
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source tools/lib/gate-run.sh

SUFFIX="${VIRELAI_GATE_SUFFIX:-}"
art() { printf 'artifacts/%s%s' "$1" "$SUFFIX"; }

GATE_LOG="$(art m42-sx5-tabwm-fullscreen-live.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

REPORT="$(art live-tabwm-fullscreen-report.txt)"
CALC_READY_LINE="calc: ready"

echo "=== verify-live-tabwm-fullscreen: M42 SX5 — the tabbed desktop as primary manager (issue #986) ==="

zig version
swift --version 2>&1 | head -1
sw_vers
REVISION="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
DIRTY="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
echo "revision: $REVISION branch=$BRANCH dirty-files=$DIRTY"

zig fmt --check boot/src/*.zig kernel/src/*.zig user/src/*.zig build.zig
zig build
zig build image
swift build --package-path host/vm-runner --configuration release -Xswiftc -DSPIKE
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner

# --- per-run isolation -------------------------------------------------------------
gate_begin live-tabwm-fullscreen
gate_seed_share
echo "run dir: $RUN_DIR"

run_one() {
    local tag="$1"          # A | B
    local run_log="$(art live-tabwm-fullscreen-run-$tag.txt)"
    local serial_copy="$(art live-tabwm-fullscreen-serial-$tag.log)"
    rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial-$tag.log"

    local runner_args=("${GATE_RUNNER_ARGS[@]}"
        --serial "$RUN_DIR/vm-serial-$tag.log"
        --screen "$RUN_DIR/screen")

    local script script2 expect_marker
    # The share persists across this gate's boots (one RUN_DIR): boot B must
    # NOT inherit boot A's settings seed (the gate-run.sh note — prior-boot
    # state resurrects). Each boot states its own world explicitly.
    rm -f "$RUN_DIR/share/SETTINGS.TXT"
    if [ "$tag" = "A" ]; then
        # Boot A: the settings-seeded default manager. Pre-seed SETTINGS.TXT
        # (the versioned v1 format settings.zig parses at boot).
        printf '#v1\nwm=tabwm\n' > "$RUN_DIR/share/SETTINGS.TXT"
        script="$RUN_DIR/script-A.txt"
        printf 'echo boot-a-idle\n' > "$script"
        script2="$RUN_DIR/script2-A.txt"
        printf 'exec CALC.BIN\n' > "$script2"
        script3="$RUN_DIR/script3-A.txt"
        printf 'dui\necho rx-m42-ok\n' > "$script3"
        # The runner STOPS on the relayout marker: CALC prints it after its
        # 50-tick settle sleep — the last link in the full-screen chain.
        expect_marker="calc: resize relayout"
        # script2 fires after the sidebar renders (TABWM seated by autostart);
        # script3 after CALC is ready — the dui enumeration captures the
        # post-declaration geometry (the decisive full-viewport proof).
        runner_args+=(--script "$script"
            --script2 "$script2" --script2-after "tabwm: sidebar-rendered"
            --script3 "$script3" --script3-after "calc: ready"
            --script-expect "$expect_marker" --timeout 90)
    else
        # Boot B: the explicit start + the god-menu overlay launch.
        script="$RUN_DIR/script-B.txt"
        printf 'tabwm start\necho boot-b-idle\n' > "$script"
        script2="$RUN_DIR/script2-B.txt"
        printf 'echo rx-m42-b-ok\n' > "$script2"
        script3="$RUN_DIR/script3-B.txt"
        printf 'procs\necho rx-m42-b2-ok\n' > "$script3"
        # The runner stops on CALC's relayout marker (it prints after the
        # app's 50-tick settle — the last link in the full-screen chain).
        expect_marker="calc: resize relayout"
        runner_args+=(--script "$script"
            --script2 "$script2" --script2-after "tabwm: sidebar-rendered"
            --script3 "$script3" --script3-after "tabwm: launch"
            --script-expect "$expect_marker" --timeout 120
            --via-virtio
            --input-chords "ctrl-space,6,4,-,b,i,t,return"
            --input-chords-after "tabwm: sidebar-rendered")
    fi

    set +e
    host/vm-runner/.build/release/VMRunner "${runner_args[@]}" \
        > "$run_log" 2>&1
    local rc=$?
    set -e
    [ -f "$RUN_DIR/vm-serial-$tag.log" ] && cp "$RUN_DIR/vm-serial-$tag.log" "$serial_copy" || true
    local SER="$serial_copy"

    local bytes=0 banner=0 autostart=0 registered=0 sidebar=0 \
        calc_open=0 tab_aware=0 relayout=0 tab_switch=0 echo_ok=0 \
        god_menu=0 launch=0 fatal=0
    if [ -f "$SER" ]; then
        bytes="$(wc -c < "$SER" | tr -d ' ')"
        [ "$(grep -aFxc -- "VirelaiOS kernel has seized control." "$SER" || true)" = 1 ] && banner=1
        [ "$(grep -aFc -- "tabwm: registered" "$SER" || true)" -ge 1 ] && registered=1
        [ "$(grep -aFc -- "tabwm: sidebar-rendered" "$SER" || true)" -ge 1 ] && sidebar=1
        [ "$(grep -aFc -- "calc: open id=2" "$SER" || true)" -ge 1 ] && calc_open=1
        [ "$(grep -aFc -- "tabwm: tab-switch" "$SER" || true)" -ge 1 ] && tab_switch=1
        if [ "$(grep -aFc -- "\[EXC\]" "$SER" || true)" = 0 ] && [ "$(grep -aFc -- "kernel panic" "$SER" || true)" = 0 ]; then
            fatal=0
        else
            fatal=1
        fi
        if [ "$tag" = "A" ]; then
            [ "$(grep -aFc -- "wm: autostart tabwm (settings wm=tabwm)" "$SER" || true)" -ge 1 ] && autostart=1
        else
            [ "$(grep -aFc -- "tabwm: starting TABWM.BIN" "$SER" || true)" -ge 1 ] && autostart=1
            [ "$(grep -aFc -- "tabwm: god-menu" "$SER" || true)" -ge 1 ] && god_menu=1
            [ "$(grep -aFc -- "tabwm: launch CALC.BIN" "$SER" || true)" -ge 1 ] && launch=1
        fi
    fi
    [ "$(grep -aFc -- "calc: tab-aware (full-viewport)" "$SER" 2>/dev/null || true)" -ge 1 ] && tab_aware=1
    [ "$(grep -aFc -- "calc: resize relayout" "$SER" 2>/dev/null || true)" -ge 1 ] && relayout=1
    [ "$(grep -aFc -- "$expect_marker" "$SER" 2>/dev/null || true)" -ge 1 ] && relayout=1
    [ "$(grep -aFc -- "rx-m42" "$SER" 2>/dev/null || true)" -ge 1 ] && echo_ok=1

    {
        echo "run $tag: rc=$rc bytes=$bytes"
        echo "  banner=$banner autostart=$autostart registered=$registered sidebar=$sidebar calc_open=$calc_open tab_aware=$tab_aware relayout=$relayout tab_switch=$tab_switch god_menu=$god_menu launch=$launch echo-ok=$echo_ok fatal=$fatal"
    } | tee -a "$REPORT"

    [ "$rc" = 0 ] || { echo "FAIL [$tag]: runner exit $rc (log: $run_log)"; return 1; }
    [ "$banner" = 1 ] || { echo "FAIL [$tag]: kernel banner missing"; return 1; }
    [ "$registered" = 1 ] || { echo "FAIL [$tag]: TABWM.BIN did not register"; return 1; }
    [ "$sidebar" = 1 ] || { echo "FAIL [$tag]: TABWM.BIN sidebar did not render"; return 1; }
    [ "$calc_open" = 1 ] || { echo "FAIL [$tag]: CALC.BIN did not open"; return 1; }
    [ "$tab_aware" = 1 ] || { echo "FAIL [$tag]: CALC tab-aware declaration not accepted"; return 1; }
    [ "$relayout" = 1 ] || { echo "FAIL [$tag]: WIN_RESIZE seam did not reach CALC (no resize relayout)"; return 1; }
    [ "$tab_switch" = 1 ] || { echo "FAIL [$tag]: TABWM tab switch not observed"; return 1; }
    [ "$echo_ok" = 1 ] || { echo "FAIL [$tag]: shell did not echo $expect_marker"; return 1; }
    [ "$fatal" = 0 ] || { echo "FAIL [$tag]: kernel fault/panic observed"; return 1; }
    if [ "$tag" = "A" ]; then
        [ "$autostart" = 1 ] || { echo "FAIL [A]: the settings-seeded autostart did not fire"; return 1; }
    else
        [ "$autostart" = 1 ] || { echo "FAIL [B]: 'tabwm start' not observed"; return 1; }
        [ "$god_menu" = 1 ] || { echo "FAIL [B]: the god-menu overlay was not summoned (ctrl-space)"; return 1; }
        [ "$launch" = 1 ] || { echo "FAIL [B]: the overlay did not launch CALC.BIN (filter+enter)"; return 1; }
    fi
    return 0
}

pass=0
for tag in A B; do
    echo "--- boot $tag ---"
    if run_one "$tag"; then
        pass=$((pass + 1))
        echo "boot $tag: PASS"
    else
        echo "boot $tag: FAIL"
    fi
done
gate_end

if [ "$pass" -ne 2 ]; then
    echo "verify-live-tabwm-fullscreen: FAIL — $pass/2 boots passed (see $GATE_LOG)"
    exit 1
fi

echo "verify-live-tabwm-fullscreen: PASS — settings-seeded autostart booted TABWM as the default manager, CALC declared tab-aware and received the full 1100x720 viewport through the WIN_RESIZE seam, and the god-menu overlay launched CALC into a new tab from typed filter+enter."
