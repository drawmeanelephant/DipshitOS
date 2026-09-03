#!/usr/bin/env bash
#
# verify-live-zc.sh -- M32 Lane 2 class-B gate (issue #620): the
# on-machine Zig subset compiler produces an ELF the on-machine loader runs.
# Since Z3b (issue #759) the staged program is the stdz-using wc app
# (tests/zc-corpus/z3b-stdz.z + z3b-labels.z) compiled together with the
# stdz library (user/src/lib/stdz/fmt.zig + string_builder.zig + ring.zig)
# through Z3a's multi-file path: APP.Z, LABELS.Z, FMT.Z, BUILDER.Z and
# RING.Z are seeded host-side (no shell line-length cap; each under the
# 2048-byte single file_read cap) and ZC.BIN is invoked `strace exec ZC.BIN
# APP.Z LABELS.Z FMT.Z BUILDER.Z RING.Z MAIN.ELF`. The app mmaps the Z2a arena, reads DATA.TXT through the ring
# buffer, counts bytes/lines/words, formats a report (dec + hex) into the
# string builder, writes OUT.TXT byte-exact, prints deterministic markers,
# and sys_exits with status 72. The gate asserts every marker and their
# exact order in the serial log plus a host-side compare of OUT.TXT against
# the expected report.
#
# ZC.BIN runs under `strace exec` (M22 D5) so the serial log carries
# per-syscall evidence of the compile (sys_file_open/read of the full
# sources) — and the strace run is the RELIABLE shape for this gate. A
# latent kernel-shell race makes the plain async-exec path flaky: boots with
# `exec ZC.BIN` + `exec MAIN.ELF` (same binary, same fixture) repeatedly
# died with the VM stopping silently or the shell faulting inside
# shell.boot_and_park's idle loop (elr 0x7da7fd44 / 0x7da7ff54 — the kernel
# text at 0x7da77000 + 0x8d44/0x8f54 — dereferencing corrupted callee-saved
# registers, far 0x6/0x1e/garbage; register states differ per boot). The
# corruption strikes the exit-report drain right as a traced/async task
# exits; tracing MAIN.ELF too (extra console prints during its exit) made it
# WORSE (0/2), tracing only ZC.BIN gives clean boots (3/3 observed). Worth
# its own card: the exit-report ring (process.zig push_exit_report /
# take_exit_report) vs the shell idle drain is a real race.
#
# The chain, asserted in vm-serial.log plus a host-side file compare:
#   1. APP.Z (the stdz wc fixture) and the three stdz modules are seeded.
#   2. `strace exec ZC.BIN APP.Z FMT.Z BUILDER.Z RING.Z MAIN.ELF` — ZC.BIN
#      reads all four sources, compiles them in-guest into ONE flat symbol
#      table (cross-file calls resolved through patches), and writes a
#      minimal AArch64 ELF32 executable (asserted: sys_file_read of the full
#      sources — this also guards the 2048-byte single-read truncation
#      regression).
#   3. `exec MAIN.ELF` — the loader maps and runs the compiled ELF: the z3b
#      marker sequence (start → ok) is printed in order, DATA.TXT was
#      streamed through the ring, and the program sys_exits with status 72.
#   4. The host asserts every marker's presence and their exact order in the
#      serial log, and compares OUT.TXT byte-exact to the expected report
#      (bytes/lines/words/hex for the seeded DATA.TXT).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source tools/lib/gate-run.sh

SUFFIX="${VIRELAI_GATE_SUFFIX:-}"
art() { printf 'artifacts/%s%s' "$1" "$SUFFIX"; }

GATE_LOG="$(art m32-zc-live.txt)"
Z3B_APP="tests/zc-corpus/z3b-stdz.z"
Z3B_LABELS="tests/zc-corpus/z3b-labels.z"
Z3B_FMT="user/src/lib/stdz/fmt.zig"
Z3B_BUILDER="user/src/lib/stdz/string_builder.zig"
Z3B_RING="user/src/lib/stdz/ring.zig"
Z3A_MAIN="tests/zc-corpus/z3a-multifile.z"
Z3A_LIB="tests/zc-corpus/z3a-lib.z"
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

# Stage the Z3b stdz app + library host-side (seeded directly, so not
# limited by the shell's 256-byte write line cap; each stays under 2048
# bytes so a single file_read per source suffices — the kernel caps a read
# at 2048 B). ZC.BIN gets the multi-file CLI shape: last word = output,
# words before it = sources. DATA.TXT is the wc input; REPORT.EXP is the
# report the gate expects the in-guest program to produce.
cp "$Z3B_APP" "$SHARE/APP.Z"
cp "$Z3B_LABELS" "$SHARE/LABELS.Z"
cp "$Z3B_FMT" "$SHARE/FMT.Z"
cp "$Z3B_BUILDER" "$SHARE/BUILDER.Z"
cp "$Z3B_RING" "$SHARE/RING.Z"
echo "staged APP.Z ($(wc -c < "$SHARE/APP.Z" | tr -d ' ') bytes) from $Z3B_APP"
echo "staged LABELS.Z ($(wc -c < "$SHARE/LABELS.Z" | tr -d ' ') bytes) from $Z3B_LABELS"
echo "staged FMT.Z ($(wc -c < "$SHARE/FMT.Z" | tr -d ' ') bytes) from $Z3B_FMT"
echo "staged BUILDER.Z ($(wc -c < "$SHARE/BUILDER.Z" | tr -d ' ') bytes) from $Z3B_BUILDER"
echo "staged RING.Z ($(wc -c < "$SHARE/RING.Z" | tr -d ' ') bytes) from $Z3B_RING"
printf 'hello world\nfoo bar baz\n' > "$SHARE/DATA.TXT"
printf 'bytes=24\nlines=2\nwords=5\nhex=18\n' > "$SHARE/REPORT.EXP"
printf 'ls\nstrace exec ZC.BIN APP.Z LABELS.Z FMT.Z BUILDER.Z RING.Z MAIN.ELF\n' > "$SCRIPT"
printf 'ls\nexec MAIN.ELF\necho rx-zc-ok\n' > "$SCRIPT2"

# --- host compile-check phase (Z0.5 dialect acceptance) -----------------------------
echo "=== verify-live-zc: host compile check ==="
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

CORPUS_ENUM_TMP="$RUN_DIR/corpus_enum.zig"
cp tests/zc-corpus/z1f-enums.z "$CORPUS_ENUM_TMP"
zig build-obj -target aarch64-freestanding --dep zc -Mroot="$CORPUS_ENUM_TMP" -Mzc=user/src/lib/zc.zig -femit-bin="$RUN_DIR/corpus_enum.o"
rm -f "$CORPUS_ENUM_TMP" "$RUN_DIR/corpus_enum.o"

CORPUS_HEAP_TMP="$RUN_DIR/corpus_heap.zig"
cp tests/zc-corpus/z2a-heap.z "$CORPUS_HEAP_TMP"
zig build-obj -target aarch64-freestanding --dep zc -Mroot="$CORPUS_HEAP_TMP" -Mzc=user/src/lib/zc.zig -femit-bin="$RUN_DIR/corpus_heap.o"
rm -f "$CORPUS_HEAP_TMP" "$RUN_DIR/corpus_heap.o"

CORPUS_DEFER_TMP="$RUN_DIR/corpus_defer.zig"
cp tests/zc-corpus/z2b-defer-fnptr.z "$CORPUS_DEFER_TMP"
zig build-obj -target aarch64-freestanding --dep zc -Mroot="$CORPUS_DEFER_TMP" -Mzc=user/src/lib/zc.zig -femit-bin="$RUN_DIR/corpus_defer.o"
rm -f "$CORPUS_DEFER_TMP" "$RUN_DIR/corpus_defer.o"

# Z3a (issue #758): the multi-file pair is host-checked CONCATENATED — the
# in-guest compile merges both files into one flat namespace, so cat'ing them
# is the exact host-side analogue (no @import between them, per the ladder).
CORPUS_MULTI_TMP="$RUN_DIR/corpus_multifile.zig"
cat "$Z3A_LIB" "$Z3A_MAIN" > "$CORPUS_MULTI_TMP"
zig build-obj -target aarch64-freestanding --dep zc -Mroot="$CORPUS_MULTI_TMP" -Mzc=user/src/lib/zc.zig -femit-bin="$RUN_DIR/corpus_multifile.o"
rm -f "$CORPUS_MULTI_TMP" "$RUN_DIR/corpus_multifile.o"

# Z3b (issue #759): the stdz app + app glue + three library modules
# host-checked CONCATENATED — the flat-namespace analogue of the in-guest
# compile (only the app imports zc; the library/glue modules are pure).
CORPUS_STDZ_TMP="$RUN_DIR/corpus_stdz.zig"
cat "$Z3B_FMT" "$Z3B_BUILDER" "$Z3B_RING" "$Z3B_LABELS" "$Z3B_APP" > "$CORPUS_STDZ_TMP"
zig build-obj -target aarch64-freestanding --dep zc -Mroot="$CORPUS_STDZ_TMP" -Mzc=user/src/lib/zc.zig -femit-bin="$RUN_DIR/corpus_stdz.o"
rm -f "$CORPUS_STDZ_TMP" "$RUN_DIR/corpus_stdz.o"

echo "host compile check: ok (z05-dialect.z + vl6-gui.z + z1a-strings.z + z1b-arrays.z + z1c-structs.z + z1d-pointers.z + z1e-control.z + z1f-enums.z + z2a-heap.z + z2b-defer-fnptr.z + z3a pair + stdz fmt+builder+ring+app concatenated valid Zig 0.16)"

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

    local markers=("z3b-start" "z3b-ok")
    local bytes=0 banner=0 listed=0 compiled=0 loaded=0 markers_ok=0 exit72=0 reaped=0 echo_ok=0 ordered=0 secondary=0 fatal=0
    if [ -f "$SER" ]; then
        bytes="$(wc -c < "$SER" | tr -d ' ')"
        [ "$(grep -aFxc -- "VirelaiOS kernel has seized control." "$SER" || true)" = 1 ] && banner=1
        [ "$(grep -aFc -- "APP.Z" "$SER" || true)" -ge 1 ] && listed=1
        [ "$(grep -aFc -- "RING.Z" "$SER" || true)" -ge 1 ] && listed=1
        [ "$(grep -aFc -- "zc: successfully compiled in-guest" "$SER" || true)" = 1 ] && compiled=1
        [ "$(grep -aFc -- "exec: loaded MAIN.ELF size=" "$SER" || true)" = 1 ] && loaded=1
        local present=0
        local m=""
        for m in "${markers[@]}"; do
            [ "$(grep -aFc -- "$m" "$SER" || true)" -ge 1 ] && present=$((present + 1))
        done
        [ "$present" = "${#markers[@]}" ] && markers_ok=1
        # Order proof: the first occurrence of each marker must ascend in the
        # serial log — z3b-start first, then the in-guest app finished its
        # ring-encoded wc run and wrote the report before printing z3b-ok.
        if python3 - "$SER" "${markers[@]}" <<'PY' 2>/dev/null; then
import sys
path = sys.argv[1]
names = sys.argv[2:]
data = open(path, "rb").read()
last = -1
for name in names:
    idx = data.find(name.encode())
    if idx < 0 or idx < last:
        sys.exit(1)
    last = idx
sys.exit(0)
PY
            ordered=1
        fi
        [ "$(grep -aFxc -- "$EXIT_LINE" "$SER" || true)" -ge 1 ] && exit72=1
        [ "$(grep -aFc -- "$REAP_LINE" "$SER" || true)" -ge 2 ] && reaped=1
        [ "$(grep -aFxc -- "rx-zc-ok" "$SER" || true)" = 1 ] && echo_ok=1
        # SMP lift (claim 8477 follow-up): a secondary core staged a real
        # task (the worker) — the per-core tick ran outside PE 0.
        [ "$(grep -aFc -- "smp: secondary runs=" "$SER" || true)" -ge 1 ] && secondary=1
        grep -qF -- "[EXC] parking:" "$SER" && fatal=1 || true
    fi
    # Z3b: byte-exact report compare — the guest built OUT.TXT in the mmap
    # arena via the stdz builder; it must equal the expected report for the
    # seeded DATA.TXT. Keep OUT.TXT as evidence (gate_end may delete the
    # share dir).
    local fileeq=0
    if [ -f "$SHARE/OUT.TXT" ]; then
        cp -f "$SHARE/OUT.TXT" "$(art live-zc-out-$tag.txt)"
        cmp -s "$SHARE/REPORT.EXP" "$SHARE/OUT.TXT" && fileeq=1
    fi
    echo "$tag: runner-rc=$rc serial-bytes=$bytes banner=$banner listed=$listed compiled=$compiled loaded=$loaded markers=$markers_ok exit72=$exit72 reaped=$reaped echo=$echo_ok ordered=$ordered fileeq=$fileeq secondary=$secondary fatal=$fatal" | tee -a "$REPORT"
    [ "$rc" = 0 ] && [ "$banner" = 1 ] && [ "$listed" = 1 ] && \
        [ "$compiled" = 1 ] && [ "$loaded" = 1 ] && [ "$markers_ok" = 1 ] && [ "$exit72" = 1 ] && \
        [ "$reaped" = 1 ] && [ "$echo_ok" = 1 ] && [ "$ordered" = 1 ] && [ "$fileeq" = 1 ] && [ "$secondary" = 1 ] && [ "$fatal" = 0 ]
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
    echo "verify-live-zc: PASS — ZC.BIN compiled the stdz app + app glue + 3 library modules in-guest (traced full source reads; 5-file multi-file CLI shape), MAIN.ELF ran it (all 2 markers present in order — DATA.TXT streamed through the ring, counts formatted dec+hex into the builder, OUT.TXT matched the expected report byte-exact, exit status 72 observed) ($pass/$BOOTS boot(s))."
    echo "PASS: $pass/$BOOTS" >> "$REPORT"
    exit 0
fi
echo "verify-live-zc: FAILED — $pass/$BOOTS boot(s) passed; see $REPORT and per-boot logs."
echo "FAIL: $pass/$BOOTS" >> "$REPORT"
exit 1
