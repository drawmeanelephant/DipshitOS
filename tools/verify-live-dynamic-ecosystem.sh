#!/usr/bin/env bash
#
# verify-live-dynamic-ecosystem.sh -- Milestone 31 Class-B Gate (claim 4001):
# Dynamic Linking Ecosystem & Userland Migration.
#
# Asserts on real Apple Silicon VZ hardware:
#   1. LD.SO, LIBUI.SO, LIBFONT.SO, PLUGIN.SO, DYNAPP.ELF, CALC.ELF, NOTEPAD.ELF,
#      FILE.ELF, DESKTOP.ELF live in the host share.
#   2. `exec DYNAPP.ELF`: loads via LD.SO, resolves LIBUI.SO/LIBFONT.SO, exits 0.
#   3. `exec CALC.ELF`: loads via LD.SO, loads PLUGIN.SO via dlopen/dlsym,
#      computes plugin pow(2, 8) = 256, renders UI, exits 0.
#   4. `exec NOTEPAD.ELF`: loads via LD.SO, tests clipboard roundtrip, renders editor UI, exits 0.
#   5. `exec FILE.ELF`: loads via LD.SO, exercises file table/UI routines, exits 0.
#   6. `exec DESKTOP.ELF`: loads via LD.SO, executes desktop composition session, exits 0.
#   7. All processes exit status 0, zero fatal faults/panics.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source tools/lib/gate-run.sh

SUFFIX="${VIRELAI_GATE_SUFFIX:-}"
art() { printf 'artifacts/%s%s' "$1" "$SUFFIX"; }

GATE_LOG="$(art m31-dynamic-ecosystem-live.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

BOOTS="${BOOTS:-1}"
STATIC_EXIT_LINE="tasks user-el0 exited status=7"
EXEC_EXIT_LINE="tasks user-exec exited status=0"
EXEC_REAP_LINE="tasks user-exec reaped"

echo "=== verify-live-dynamic-ecosystem: Milestone 31 (claim 4001) — Dynamic Linking Ecosystem ==="
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

gate_begin live-dynamic-ecosystem
gate_seed_share
echo "run dir: $RUN_DIR"

test_one_app() {
    local app="$1"
    local expect_str="$2"
    local tag="$3"
    local script_file="$RUN_DIR/script-$app.txt"
    local run_log="$(art live-m31-$app-run-$tag.txt)"
    local serial_copy="$(art live-m31-$app-serial-$tag.log)"
    rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial-$tag.log"

    printf 'ls\nexec %s\n' "$app" > "$script_file"

    set +e
    host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
        --serial "$RUN_DIR/vm-serial-$tag.log" \
        --script "$script_file" --script-after "$STATIC_EXIT_LINE" \
        --script-expect "$EXEC_REAP_LINE" --timeout 60 > "$run_log" 2>&1
    local rc=$?
    set -e
    [ -f "$RUN_DIR/vm-serial-$tag.log" ] && cp "$RUN_DIR/vm-serial-$tag.log" "$serial_copy" || true

    local banner=0 loaded=0 expected=0 exited=0 reaped=0 fatal=0
    if [ -f "$serial_copy" ]; then
        [ "$(grep -aFxc -- "VirelaiOS kernel has seized control." "$serial_copy" || true)" = 1 ] && banner=1
        [ "$(grep -aFc -- "exec: loaded $app" "$serial_copy" || true)" -ge 1 ] && loaded=1
        [ "$(grep -aFc -- "$expect_str" "$serial_copy" || true)" -ge 1 ] && expected=1
        [ "$(grep -aFc -- "$EXEC_EXIT_LINE" "$serial_copy" || true)" -ge 1 ] && exited=1
        [ "$(grep -aFc -- "$EXEC_REAP_LINE" "$serial_copy" || true)" -ge 1 ] && reaped=1
        grep -aE -- "panic|EXCEPTION|Synchronous|FAULT" "$serial_copy" >/dev/null 2>&1 && fatal=1 || true
    fi

    echo "  app $app: banner=$banner loaded=$loaded expected=$expected exited=$exited reaped=$reaped fatal=$fatal rc=$rc"
    if [ "$banner" = 1 ] && [ "$loaded" = 1 ] && [ "$expected" = 1 ] && [ "$exited" = 1 ] && [ "$reaped" = 1 ] && [ "$fatal" = 0 ]; then
        return 0
    fi
    return 1
}

run_suite() {
    local tag="$1"
    echo "=== Running Dynamic Ecosystem Suite (boot $tag) ==="
    local all_ok=1

    echo "1/5 Testing DYNAPP.ELF..."
    test_one_app "DYNAPP.ELF" "dynapp: hello from dynamic executable" "$tag" || all_ok=0

    echo "2/5 Testing CALC.ELF..."
    test_one_app "CALC.ELF" "calc.elf: plugin pow(2, 8) = 256 ok" "$tag" || all_ok=0

    echo "3/5 Testing NOTEPAD.ELF..."
    test_one_app "NOTEPAD.ELF" "notepad.elf: clipboard roundtrip ok" "$tag" || all_ok=0

    echo "4/5 Testing FILE.ELF..."
    test_one_app "FILE.ELF" "file.elf: file table and ui ok" "$tag" || all_ok=0

    echo "5/5 Testing DESKTOP.ELF..."
    test_one_app "DESKTOP.ELF" "desktop.elf: composition session active ok" "$tag" || all_ok=0

    return $((1 - all_ok))
}

PASSES=0
for ((i=1; i<=BOOTS; i++)); do
    if run_suite "$i"; then
        PASSES=$((PASSES + 1))
    else
        echo "FAIL on boot $i"
    fi
done

if [ "$PASSES" -eq "$BOOTS" ]; then
    echo "=== verify-live-dynamic-ecosystem: ALL $BOOTS BOOT(S) PASSED ==="
    exit 0
else
    echo "=== verify-live-dynamic-ecosystem: FAILED ($PASSES/$BOOTS passed) ==="
    exit 1
fi
