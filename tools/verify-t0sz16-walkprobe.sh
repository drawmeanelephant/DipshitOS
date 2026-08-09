#!/usr/bin/env bash
#
# verify-t0sz16-walkprobe.sh -- claim 7896 (claim-6460 follow-up) class-D
# diagnostic: SEPARATE the T0SZ start-level mismatch from the residual
# post-MMU virtio TX hang, deterministically.
#
# Mechanism: the no-TLBI crutch (ADR 0006) leaves stale firmware TLB entries
# in play, which is what makes the post-switch behavior boot-varying.
# -Dtlbi-after-switch removes the crutch: immediately after the identity-map
# install the kernel executes `tlbi vmalle1; dsb ish; isb`, so the FIRST
# post-switch access MUST re-walk the installed tables. At T0SZ=25 (W=39)
# the 4 KiB walk starts at level 1 over the L0-rooted tables -> every fresh
# walk faults -> the kernel dies right after the switch, EVERY boot. At
# T0SZ=16 (W=48, start level 0) the walk resolves. -Dwalk-probe then runs a
# cold-address probe battery (each probe bracketed by an NVRAM marker) so
# the ladder NAMES the first address that does not resolve.
#
# Four cells (each also runs the claim-0020 phase-C TX experiment as the
# observation point, like verify-t0sz16.sh):
#   A  -Dtlbi-after-switch=true                              T0SZ=25 + TLBI
#   B  -Dtlbi-after-switch=true -Dt0sz16=true -Dwalk-probe=true   T0SZ=16 + TLBI + probe
#   C  -Dwalk-probe=true                                     T0SZ=25, no TLBI
#   D  -Dwalk-probe=true -Dt0sz16=true                       T0SZ=16, no TLBI
#
# Predicted signatures (deterministic separation):
#   A: ladder ends at M2_MMUP! (switch completed) with NO M2_WP_* markers —
#      the first post-TLBI access faults. EVERY boot.
#   B: full probe ladder M2_WP_00..M2_WP_05, then phase-C TX outcome. With
#      an empty TLB the tables resolve cleanly under T0SZ=16, so phase C
#      should complete EVERY boot (claim 6460's ~1/3 rate without TLBI is
#      the stale-firmware-TLB crutch interfering, not a device hang).
#   C: dies at the first TLB-cold probe (survey of which addresses the
#      stale-TLB crutch actually covers).
#   D: full probe ladder, then phase-C residual reproduction (~1/3).
#
# Usage:
#   bash tools/verify-t0sz16-walkprobe.sh            # all cells, BOOTS each
#   CELL=A BOOTS=4 bash tools/verify-t0sz16-walkprobe.sh
#   CELL=A,B BOOTS=4 bash tools/verify-t0sz16-walkprobe.sh
#
# Evidence under artifacts/: walkprobe-gate.txt (full output),
# walkprobe-report-<cell>.txt (per-boot detail), walkprobe-compare.txt
# (cell table + interpretation), walkprobe-<cell>-{run,marker,serial}-<NN>.*
# per boot. Fresh EFI variable store per boot, --timeout 25.
#
# Diagnostic only (class D): a payload hit does NOT pass claim 0002. Default
# builds stay byte-identical (KERNEL.BIN sha 55325752...).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

GATE_LOG="artifacts/walkprobe-gate.txt"
exec > >(tee "$GATE_LOG") 2>&1
trap 'sleep 0.5' EXIT

BOOTS="${BOOTS:-4}"
CELLS="${CELL:-A,B,C,D}"

echo "=== verify-t0sz16-walkprobe: claim 7896 — start-level vs residual separation ($BOOTS boot(s) per cell, cells=$CELLS) ==="

zig version; swift --version 2>&1 | head -1; sw_vers
REVISION="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
DIRTY="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
# bash 3.2 on macOS: no associative arrays — a function instead.
flags_for() {
    case "$1" in
        A) echo "-Dtx-transition-c=true -Dtlbi-after-switch=true" ;;
        B) echo "-Dtx-transition-c=true -Dtlbi-after-switch=true -Dt0sz16=true -Dwalk-probe=true" ;;
        C) echo "-Dtx-transition-c=true -Dwalk-probe=true" ;;
        D) echo "-Dtx-transition-c=true -Dwalk-probe=true -Dt0sz16=true" ;;
    esac
}
echo "revision: $REVISION branch=$BRANCH boots-per-cell=$BOOTS dirty-files=$DIRTY"
for c in A B C D; do echo "  cell $c: $(flags_for "$c")"; done

# --- build gates: default build unchanged; every requested cell compiles ---
zig fmt --check boot/src/*.zig kernel/src/*.zig build.zig
zig build
DEFAULT_SHA=$(shasum -a 256 zig-out/bin/KERNEL.BIN | cut -d' ' -f1)
echo "default KERNEL.BIN sha256: $DEFAULT_SHA (expect 55325752...)"
for c in ${CELLS//,/ }; do
    echo "--- compile cell $c ---"
    # shellcheck disable=SC2086
    zig build kernel $(flags_for "$c")
done
swift build --package-path host/vm-runner --configuration release
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner

run_one() {
    local report="$1" tag="$2" flags="$3"
    echo "--- image for $tag ($flags) ---"
    # shellcheck disable=SC2086
    zig build $flags image >/dev/null
    rm -f artifacts/efi-vars.bin
    set +e
    host/vm-runner/.build/release/VMRunner artifacts/disk.img artifacts/vm-serial.log \
        --dump-marker artifacts/marker-dump.txt --timeout 25 \
        > "artifacts/walkprobe-$tag-run.txt" 2>&1
    local RUNNER_RC=$?
    set -e
    [ -f artifacts/marker-dump.txt ] && cp artifacts/marker-dump.txt "artifacts/walkprobe-$tag-marker.txt" || true
    [ -f artifacts/vm-serial.log ] && cp artifacts/vm-serial.log "artifacts/walkprobe-$tag-serial.log" || true

    local LADDER=()
    while IFS= read -r line; do
        LADDER+=("${line#MARKER-GATE: }")
    done < <(grep -E '^MARKER-GATE: M2_' "artifacts/walkprobe-$tag-run.txt" || true)

    if [ "${#LADDER[@]}" -eq 0 ]; then
        echo "$tag rc=$RUNNER_RC: NO MARKERS AT ALL"
        echo "$tag: wp-depth=0 last-marker=(none) phaseC-returned=0 used-advanced=0 payload=0 serial-bytes=0" >> "$report"
        return
    fi

    local WP=0
    for m in "${LADDER[@]}"; do
        case "$m" in
            M2_WP_*) WP=$((WP + 1)) ;;
        esac
    done

    # Phase-C outcome (claim-0020 style): did the transition experiment
    # return (M2_TRC2!) and advance used.idx (M2_TRCU!)?
    local RET=0 USED=0
    for m in "${LADDER[@]}"; do
        [ "$m" = "M2_TRC2!" ] && RET=1
        [ "$m" = "M2_TRCU!" ] && USED=1
    done
    local PAYLOAD=0
    [ -f "artifacts/walkprobe-$tag-serial.log" ] && grep -qF -- "DIPSHITOS TRANSITION TX" "artifacts/walkprobe-$tag-serial.log" && PAYLOAD=1
    local SERIAL_BYTES
    SERIAL_BYTES=$(wc -c < "artifacts/walkprobe-$tag-serial.log" 2>/dev/null | tr -d ' ')

    {
        echo "$tag: wp-depth=$WP last-marker=${LADDER[${#LADDER[@]}-1]} phaseC-returned=$RET used-advanced=$USED payload=$PAYLOAD serial-bytes=$SERIAL_BYTES"
        echo "  ladder: ${LADDER[*]}"
    } >> "$report"
    echo "$tag rc=$RUNNER_RC: wp-depth=$WP last=${LADDER[${#LADDER[@]}-1]} phaseC-returned=$RET used-advanced=$USED payload=$PAYLOAD"
}

report_for() {
    echo "artifacts/walkprobe-report-$1.txt"
}
for c in ${CELLS//,/ }; do
    REPORT="$(report_for "$c")"
    : > "$REPORT"
    {
        echo "DIPSHITOS walk-probe cell $c — claim 7896"
        echo "revision: $REVISION branch=$BRANCH boots=$BOOTS dirty-files=$DIRTY"
        echo "flags: $(flags_for "$c")"
        echo "date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        echo
    } >> "$REPORT"
    n=0
    while [ "$n" -lt "$BOOTS" ]; do
        n=$((n + 1))
        echo
        echo "=== cell $c boot $n ==="
        run_one "$REPORT" "cell-$c-$(printf "%02d" "$n")" "$(flags_for "$c")"
    done
done

# --- the cell comparison + interpretation ---
: > "artifacts/walkprobe-compare.txt"
{
    echo "CELL COMPARISON (claim 7896) — revision $REVISION, per-boot detail in the report files:"
    printf "%-10s %-10s %-10s %-14s %-10s %-10s %-12s\n" "cell" "wp-depth" "last" "phaseC-ret" "used" "payload" "interpretation"
} >> "artifacts/walkprobe-compare.txt"
echo
echo "=== CELL COMPARISON (claim 7896) ==="
printf "%-10s %-10s %-10s %-14s %-10s %-10s %-12s\n" "cell" "wp-depth" "last" "phaseC-ret" "used" "payload" "interpretation"
printf "%-10s %-10s %-10s %-14s %-10s %-10s %-12s\n" "----" "--------" "----" "----------" "----" "-------" "--------------"
A_WP=0; A_BR=0; B_WP=0; B_RET=0; B_USED=0; B_PAY=0; C_WP=0; D_WP=0; D_RET=0; D_USED=0; D_PAY=0
for c in ${CELLS//,/ }; do
    while IFS= read -r line; do
        case "$line" in
            cell-$c-*) : ;;
            *) continue ;;
        esac
        tag="${line%%:*}"
        WP_N=$(printf '%s' "$line" | sed -E 's/^.* wp-depth=([0-9]+) .*$/\1/')
        LM=$(printf '%s' "$line" | sed -E 's/^.* last-marker=([^ ]+).*$/\1/')
        RT=$(printf '%s' "$line" | sed -E 's/^.* phaseC-returned=([01]) .*$/\1/')
        US=$(printf '%s' "$line" | sed -E 's/^.* used-advanced=([01]) .*$/\1/')
        PL=$(printf '%s' "$line" | sed -E 's/^.* payload=([01]) .*$/\1/')
        case "$c" in
            A) A_WP=$((A_WP + WP_N)); A_BR=$((A_BR + 1));;
            B) B_WP=$((B_WP + WP_N)); B_RET=$((B_RET + RT)); B_USED=$((B_USED + US)); B_PAY=$((B_PAY + PL));;
            C) C_WP=$((C_WP + WP_N));;
            D) D_WP=$((D_WP + WP_N)); D_RET=$((D_RET + RT)); D_USED=$((D_USED + US)); D_PAY=$((D_PAY + PL));;
        esac
        printf "%-10s %-10s %-10s %-14s %-10s %-10s\n" "$tag" "$WP_N" "$LM" "$RT" "$US" "$PL" | tee -a "artifacts/walkprobe-compare.txt"
    done < "$(report_for "$c")"
done

# Totals per cell (boot counts from the loop above are per-cell; recompute
# from the reports to stay honest about what actually ran).
for c in ${CELLS//,/ }; do
    N=$(grep -c '^cell-' "$(report_for "$c")" || true)
    case "$c" in
            A) echo "cell A totals (n=$N): wp-markers=$A_WP  (expect 0 -> deterministic fault right after the switch)";;
            B) echo "cell B totals (n=$N): wp-markers=$B_WP (expect 6n — empty-TLB walk resolves)  phaseC-returned=$B_RET used=$B_USED payload=$B_PAY  (expect ~n; claim 6460's ~1/3 no-TLBI rate is stale-TLB interference)";;
            C) echo "cell C totals (n=$N): wp-markers=$C_WP  (expect partial: first TLB-cold address faults)";;
            D) echo "cell D totals (n=$N): wp-markers=$D_WP  phaseC-returned=$D_RET used=$D_USED payload=$D_PAY  (expect wp=6n, ~1/3 phaseC)";;
        esac
done

echo
echo "=== interpretation (claim 7896) ==="
echo "  A (T0SZ=25 + TLBI): no WP markers + ladder ending at M2_MMUP! => the start-level"
echo "      mismatch is confirmed: with an empty TLB the FIRST re-walk faults (every boot)."
echo "  B (T0SZ=16 + TLBI): full probe ladder + phase-C outcome. With an empty TLB the tables"
echo "      resolve under T0SZ=16 and phase C should complete EVERY boot — proving claim 6460's"
echo "      ~1/3 residual was the stale-firmware-TLB crutch, not a device/emulator hang."
echo "  C (T0SZ=25, no TLBI): partial probe ladder => names the first address the stale-TLB"
echo "      crutch does NOT cover (TLB-coverage survey)."
echo "  D (T0SZ=16, no TLBI): full probe ladder + ~1/3 phase-C => reproduces claim 6460."
echo
echo "Evidence saved under artifacts/ (walkprobe-gate.txt, walkprobe-report-{A,B,C,D}.txt,"
echo "walkprobe-compare.txt, walkprobe-cell-*-{run,marker,serial}-*)."
