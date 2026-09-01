#!/usr/bin/env bash
#
# verify-live-dynamic-linking.sh -- Milestone 30 Class-B Gate (issue #599, claim 7921):
# Freestanding Runtime Linker & Shared Libraries (LD.SO, LIBUI.SO, LIBFONT.SO, DYNAPP.ELF).
#
# The chain, all asserted in vm-serial.log on real Apple Silicon VZ hardware:
#   1. DYNAPP.ELF, LD.SO, LIBUI.SO, LIBFONT.SO live in the host share.
#   2. `exec DYNAPP.ELF` sniffs ELF dynamic executable, loads PT_INTERP (LD.SO),
#      maps interpreter segments and executable segments with strict W^X roots,
#      and constructs the initial Auxiliary Vector (AT_PHDR, AT_ENTRY, AT_BASE, etc.).
#   3. Interpreter LD.SO executes at EL0, loads needed shared libraries (LIBUI.SO,
#      LIBFONT.SO) from the ESP, resolves relocations, and branches to the main program.
#   4. DYNAPP.ELF executes at EL0, invoking imported symbols from LIBUI.SO and LIBFONT.SO.
#   5. The application exits cleanly and the task is reaped.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source tools/lib/gate-run.sh

SUFFIX="${VIRELAI_GATE_SUFFIX:-}"
art() { printf 'artifacts/%s%s' "$1" "$SUFFIX"; }

GATE_LOG="$(art m30-dynamic-linking-live.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

BOOTS="${BOOTS:-1}"
REPORT="$(art live-dynamic-linking-report.txt)"
STATIC_EXIT_LINE="tasks user-el0 exited status=7"
EXEC_EXIT_LINE="tasks user-exec exited status=0"
EXEC_REAP_LINE="tasks user-exec reaped"

echo "=== verify-live-dynamic-linking: Milestone 30 (claim 7921) — Dynamic Linking (LD.SO + LIBUI.SO + LIBFONT.SO) ==="
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

gate_begin live-dynamic-linking
gate_seed_share
echo "run dir: $RUN_DIR"
SCRIPT="$RUN_DIR/script.txt"

printf 'ls\nexec DYNAPP.ELF\necho rx-dyn-ok\n' > "$SCRIPT"

run_one() {
    local tag="$1"
    local run_log="$(art live-dyn-run-$tag.txt)"
    local serial_copy="$(art live-dyn-serial-$tag.log)"
    rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial-$tag.log"

    set +e
    host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
        --serial "$RUN_DIR/vm-serial-$tag.log" \
        --script "$SCRIPT" --script-after "$STATIC_EXIT_LINE" \
        --script-expect "$EXEC_REAP_LINE" --timeout 60 > "$run_log" 2>&1
    local rc=$?
    set -e
    [ -f "$RUN_DIR/vm-serial-$tag.log" ] && cp "$RUN_DIR/vm-serial-$tag.log" "$(art live-dyn-serial-$tag.log)" || true
    local SER="$serial_copy"

    local bytes=0 banner=0 listed=0 loaded=0 ld_init=0 dyn_run=0 exited=0 reaped=0 echo_ok=0 fatal=0
    if [ -f "$SER" ]; then
        bytes="$(wc -c < "$SER" | tr -d ' ')"
        [ "$(grep -aFxc -- "VirelaiOS kernel has seized control." "$SER" || true)" = 1 ] && banner=1
        [ "$(grep -aFc -- "DYNAPP.ELF" "$SER" || true)" -ge 2 ] && listed=1
        [ "$(grep -aFc -- "exec: loaded DYNAPP.ELF" "$SER" || true)" -ge 1 ] && loaded=1
        [ "$(grep -aFc -- "ld.so:" "$SER" || true)" -ge 1 ] && ld_init=1
        [ "$(grep -aFc -- "dynapp:" "$SER" || true)" -ge 1 ] && dyn_run=1
        [ "$(grep -aFc -- "$EXEC_EXIT_LINE" "$SER" || true)" -ge 1 ] && exited=1
        [ "$(grep -aFc -- "$EXEC_REAP_LINE" "$SER" || true)" -ge 1 ] && reaped=1
        [ "$(grep -aFc -- "rx-dyn-ok" "$SER" || true)" -ge 1 ] && echo_ok=1
        grep -aE -- "panic|EXCEPTION|Synchronous|FAULT" "$SER" >/dev/null 2>&1 && fatal=1 || true
    fi

    echo "boot $tag: bytes=$bytes banner=$banner listed=$listed loaded=$loaded ld_init=$ld_init dyn_run=$dyn_run exited=$exited reaped=$reaped echo_ok=$echo_ok fatal=$fatal rc=$rc"

    if [ "$banner" = 1 ] && [ "$listed" = 1 ] && [ "$loaded" = 1 ] && [ "$ld_init" = 1 ] && [ "$dyn_run" = 1 ] && [ "$exited" = 1 ] && [ "$reaped" = 1 ] && [ "$echo_ok" = 1 ] && [ "$fatal" = 0 ]; then
        return 0
    fi
    return 1
}

PASSES=0
for ((i=1; i<=BOOTS; i++)); do
    if run_one "$i"; then
        PASSES=$((PASSES + 1))
    else
        echo "FAIL on boot $i"
        exit 1
    fi
done

echo "=== verify-live-dynamic-linking: ALL $BOOTS BOOT(S) PASSED ==="
