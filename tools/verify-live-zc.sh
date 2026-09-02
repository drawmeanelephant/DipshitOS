#!/usr/bin/env bash
#
# verify-live-zc.sh -- M32 Lane 2 class-B gate (issue #620): the
# on-machine Zig subset compiler produces an ELF the on-machine loader runs.
#
# The chain, all asserted in vm-serial.log:
#   1. `write MAIN.Z ...` stages a simple Z program on the host share.
#   2. `exec ZC.BIN /host/MAIN.Z /host/MAIN.ELF` — ZC.BIN reads the source,
#      compiles it, and writes a minimal AArch64 ELF32 executable.
#   3. `exec MAIN.ELF` — the loader maps and runs the compiled ELF: it
#      triggers sys_exit with status 72.
#   4. The shell stays responsive.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source tools/lib/gate-run.sh

SUFFIX="${VIRELAI_GATE_SUFFIX:-}"
art() { printf 'artifacts/%s%s' "$1" "$SUFFIX"; }

GATE_LOG="$(art m32-zc-live.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

BOOTS="${BOOTS:-1}"
REPORT="$(art live-zc-report.txt)"
STATIC_EXIT_LINE="tasks user-el0 exited status=7"
ZC_WROTE_LINE="zc: successfully compiled in-guest"
EXIT_LINE="tasks user-exec exited status=72"
REAP_LINE="tasks user-exec reaped"
SCRIPT2="artifacts/live-zc-script2.txt"

echo "=== verify-live-zc: M32 Lane 2 — compile ON the machine, run the output, $BOOTS boot(s) ==="
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
gate_begin live-zc
gate_seed_share
echo "run dir: $RUN_DIR"
SCRIPT="$RUN_DIR/script.txt"

# Stage a program that sums via for-loop, selects via switch, and prints slice, then exits 72.
SRC='const zc = @import("zc"); pub fn main() void { var sum: u64 = 0; for (0..10) |i| { sum = sum + i; } const s: []const u8 = switch (sum) { 45 => "one", else => "bad" }; zc.print(s); if (s[0] == 111) { zc.exit(72); } zc.exit(1); }'
printf 'ls\nwrite MAIN.Z '\''%s'\''\nexec ZC.BIN\n' "$SRC" > "$SCRIPT"
printf 'ls\nexec MAIN.ELF\necho rx-zc-ok\n' > "$SCRIPT2"

# --- host compile-check phase (Z0.5 dialect acceptance) -----------------------------
echo "=== verify-live-zc: host compile check ==="
HOST_CHECK_TMP="$RUN_DIR/main_check.zig"
printf '%s\n' "$SRC" > "$HOST_CHECK_TMP"
zig build-obj -target aarch64-freestanding --dep zc -Mroot="$HOST_CHECK_TMP" -Mzc=user/src/lib/zc.zig -femit-bin="$RUN_DIR/main_check.o"
rm -f "$HOST_CHECK_TMP" "$RUN_DIR/main_check.o"

# Also host compile-check the corpus fixtures
CORPUS_CHECK_TMP="$RUN_DIR/corpus_check.zig"
cp tests/zc-corpus/z05-dialect.z "$CORPUS_CHECK_TMP"
zig build-obj -target aarch64-freestanding --dep zc -Mroot="$CORPUS_CHECK_TMP" -Mzc=user/src/lib/zc.zig -femit-bin="$RUN_DIR/corpus_check.o"
rm -f "$CORPUS_CHECK_TMP" "$RUN_DIR/corpus_check.o"

CORPUS_GUI_TMP="$RUN_DIR/corpus_gui.zig"
cp tests/zc-corpus/vl6-gui.z "$CORPUS_GUI_TMP"
zig build-obj -target aarch64-freestanding --dep zc -Mroot="$CORPUS_GUI_TMP" -Mzc=user/src/lib/zc.zig -femit-bin="$RUN_DIR/corpus_gui.o"
rm -f "$CORPUS_GUI_TMP" "$RUN_DIR/corpus_gui.o"

CORPUS_STRINGS_TMP="$RUN_DIR/corpus_strings.zig"
cp tests/zc-corpus/z1a-strings.z "$CORPUS_STRINGS_TMP"
zig build-obj -target aarch64-freestanding --dep zc -Mroot="$CORPUS_STRINGS_TMP" -Mzc=user/src/lib/zc.zig -femit-bin="$RUN_DIR/corpus_strings.o"
rm -f "$CORPUS_STRINGS_TMP" "$RUN_DIR/corpus_strings.o"

CORPUS_ARRAYS_TMP="$RUN_DIR/corpus_arrays.zig"
cp tests/zc-corpus/z1b-arrays.z "$CORPUS_ARRAYS_TMP"
zig build-obj -target aarch64-freestanding --dep zc -Mroot="$CORPUS_ARRAYS_TMP" -Mzc=user/src/lib/zc.zig -femit-bin="$RUN_DIR/corpus_arrays.o"
rm -f "$CORPUS_ARRAYS_TMP" "$RUN_DIR/corpus_arrays.o"

CORPUS_STRUCTS_TMP="$RUN_DIR/corpus_structs.zig"
cp tests/zc-corpus/z1c-structs.z "$CORPUS_STRUCTS_TMP"
zig build-obj -target aarch64-freestanding --dep zc -Mroot="$CORPUS_STRUCTS_TMP" -Mzc=user/src/lib/zc.zig -femit-bin="$RUN_DIR/corpus_structs.o"
rm -f "$CORPUS_STRUCTS_TMP" "$RUN_DIR/corpus_structs.o"

CORPUS_POINTERS_TMP="$RUN_DIR/corpus_pointers.zig"
cp tests/zc-corpus/z1d-pointers.z "$CORPUS_POINTERS_TMP"
zig build-obj -target aarch64-freestanding --dep zc -Mroot="$CORPUS_POINTERS_TMP" -Mzc=user/src/lib/zc.zig -femit-bin="$RUN_DIR/corpus_pointers.o"
rm -f "$CORPUS_POINTERS_TMP" "$RUN_DIR/corpus_pointers.o"

CORPUS_CONTROL_TMP="$RUN_DIR/corpus_control.zig"
cp tests/zc-corpus/z1e-control.z "$CORPUS_CONTROL_TMP"
zig build-obj -target aarch64-freestanding --dep zc -Mroot="$CORPUS_CONTROL_TMP" -Mzc=user/src/lib/zc.zig -femit-bin="$RUN_DIR/corpus_control.o"
rm -f "$CORPUS_CONTROL_TMP" "$RUN_DIR/corpus_control.o"

echo "host compile check: ok (SRC + z05-dialect.z + vl6-gui.z + z1a-strings.z + z1b-arrays.z + z1c-structs.z + z1d-pointers.z + z1e-control.z valid Zig 0.16)"

run_one() {
    local tag="$1"
    local run_log="$(art live-zc-run-$tag.txt)"
    local serial_copy="$(art live-zc-serial-$tag.log)"
    rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial-$tag.log"

    set +e
    host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
        --serial "$RUN_DIR/vm-serial-$tag.log" \
        --script "$SCRIPT" --script-after "$STATIC_EXIT_LINE" \
        --script2 "$SCRIPT2" --script2-after "$ZC_WROTE_LINE" \
        --script-expect "$EXIT_LINE" --timeout 90 > "$run_log" 2>&1
    local rc=$?
    set -e
    [ -f "$RUN_DIR/vm-serial-$tag.log" ] && cp "$RUN_DIR/vm-serial-$tag.log" "$(art live-zc-serial-$tag.log)" || true
    local SER="$serial_copy"

    local bytes=0 banner=0 listed=0 written=0 compiled=0 loaded=0 printed=0 exit72=0 reaped=0 echo_ok=0 fatal=0
    if [ -f "$SER" ]; then
        bytes="$(wc -c < "$SER" | tr -d ' ')"
        [ "$(grep -aFxc -- "VirelaiOS kernel has seized control." "$SER" || true)" = 1 ] && banner=1
        [ "$(grep -aFc -- "MAIN.Z" "$SER" || true)" -ge 2 ] && listed=1
        [ "$(grep -aFc -- "write: ok" "$SER" || true)" = 1 ] && written=1
        [ "$(grep -aFc -- "zc: successfully compiled in-guest" "$SER" || true)" = 1 ] && compiled=1
        [ "$(grep -aFc -- "exec: loaded MAIN.ELF size=" "$SER" || true)" = 1 ] && loaded=1
        [ "$(grep -aFc -- "one" "$SER" || true)" -ge 1 ] && printed=1
        [ "$(grep -aFxc -- "$EXIT_LINE" "$SER" || true)" -ge 1 ] && exit72=1
        [ "$(grep -aFc -- "$REAP_LINE" "$SER" || true)" -ge 2 ] && reaped=1
        [ "$(grep -aFxc -- "rx-zc-ok" "$SER" || true)" = 1 ] && echo_ok=1
        grep -qF -- "[EXC] parking:" "$SER" && fatal=1 || true
    fi
    echo "$tag: runner-rc=$rc serial-bytes=$bytes banner=$banner listed=$listed written=$written compiled=$compiled loaded=$loaded printed=$printed exit72=$exit72 reaped=$reaped echo=$echo_ok fatal=$fatal" | tee -a "$REPORT"
    [ "$rc" = 0 ] && [ "$banner" = 1 ] && [ "$listed" = 1 ] && [ "$written" = 1 ] && \
        [ "$compiled" = 1 ] && [ "$loaded" = 1 ] && [ "$printed" = 1 ] && [ "$exit72" = 1 ] && \
        [ "$reaped" = 1 ] && [ "$echo_ok" = 1 ] && [ "$fatal" = 0 ]
}

: > "$REPORT"
{
    echo "VIRELAIOS live compiler gate (M32 Lane 2, issue #620)"
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
    echo "=== live-zc boot $n ==="
    if run_one "$(printf '%02d' "$n")"; then pass=$((pass + 1)); fi
done

echo
echo "=== result ==="
if [ "$pass" = "$BOOTS" ]; then
    echo "verify-live-zc: PASS — ZC.BIN compiled in-guest to a valid AArch64 ELF32 on the machine, and executed (exit status 72 observed) ($pass/$BOOTS boot(s))."
    echo "PASS: $pass/$BOOTS" >> "$REPORT"
    exit 0
fi
echo "verify-live-zc: FAILED — $pass/$BOOTS boot(s) passed; see $REPORT and per-boot logs."
echo "FAIL: $pass/$BOOTS" >> "$REPORT"
exit 1
