#!/usr/bin/env bash
#
# verify-t0sz16-walkprobe.sh -- claim 1517 (claims 6460/7896 follow-up)
# class-D regression matrix. Production now programs T0SZ=16 (correct start
# level for the L0-rooted tables) and ALWAYS executes `tlbi vmalle1; dsb
# ish; isb` at the identity-map install (claim 1517 pays the ADR-0006
# no-TLBI debt), so the FIRST post-switch access MUST re-walk the installed
# tables. -Dt0sz25 selects the legacy start level 25 (W=39, walk starts at
# level 1 over the L0-rooted tables -> every fresh walk faults).
# -Dwalk-probe runs a cold-address probe battery (each probe bracketed by
# an NVRAM marker) so the ladder NAMES the first address that does not
# resolve.
#
# Four cells (each also runs the claim-0020 phase-C TX experiment as the
# observation point, like verify-t0sz16.sh):
#   A  -Dtx-transition-c=true -Dt0sz25=true                     T0SZ=25 + TLBI
#   B  -Dtx-transition-c=true -Dwalk-probe=true                 T0SZ=16 + TLBI + probe
#   C  -Dtx-transition-c=true -Dt0sz25=true -Dwalk-probe=true   T0SZ=25 + TLBI + probe
#   D  -Dtx-transition-c=true                                   T0SZ=16 + TLBI, phase-C only
#
# Predicted signatures:
#   A: ladder ends at M2_MMUP! (switch completed) with NO M2_WP_* markers —
#      the first post-switch re-walk faults under the legacy start level.
#      EVERY boot (the claim-6460/7896 defect, deterministic).
#   B: full probe ladder M2_WP_00..M2_WP_05, then phase-C TX completes —
#      the corrected start level + empty TLB resolve every boot.
#   C: dies at the first probe (the first post-switch re-walk faults).
#   D: phase C completes — the production configuration with minimal
#      instrumentation (same configuration the class-B `zig build run` gate
#      boots).
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
# Diagnostic only (class D): a payload hit does NOT pass claim 0002 by
# itself (the gate is `zig build run`). Since claim 1517 the default build
# IS the production kernel (T0SZ=16 + TLBI); the KERNEL.BIN sha changes with
# this claim (previously 55325752...).

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
        A) echo "-Dtx-transition-c=true -Dt0sz25=true" ;;
        B) echo "-Dtx-transition-c=true -Dwalk-probe=true" ;;
        C) echo "-Dtx-transition-c=true -Dt0sz25=true -Dwalk-probe=true" ;;
        D) echo "-Dtx-transition-c=true" ;;
    esac
}
echo "revision: $REVISION branch=$BRANCH boots-per-cell=$BOOTS dirty-files=$DIRTY"
for c in A B C D; do echo "  cell $c: $(flags_for "$c")"; done

# --- build gates: default build unchanged; every requested cell compiles ---
zig fmt --check boot/src/*.zig kernel/src/*.zig build.zig
zig build
DEFAULT_SHA=$(shasum -a 256 zig-out/bin/KERNEL.BIN | cut -d' ' -f1)
echo "default KERNEL.BIN sha256: $DEFAULT_SHA (production T0SZ=16 + TLBI since claim 1517)"
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
    [ -f "artifacts/walkprobe-$tag-serial.log" ] && grep -qF -- "VIRELAIOS TRANSITION TX" "artifacts/walkprobe-$tag-serial.log" && PAYLOAD=1
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
        echo "VIRELAIOS walk-probe cell $c — claim 7896"
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
            A) echo "cell A totals (n=$N): wp-markers=$A_WP  (expect 0 -> deterministic fault right after the switch under legacy T0SZ=25)";;
            B) echo "cell B totals (n=$N): wp-markers=$B_WP (expect 6n — corrected start level + empty TLB resolves)  phaseC-returned=$B_RET used=$B_USED payload=$B_PAY  (expect n)";;
            C) echo "cell C totals (n=$N): wp-markers=$C_WP  (expect 0 — first post-switch re-walk faults under legacy T0SZ=25)";;
            D) echo "cell D totals (n=$N): wp-markers=$D_WP  phaseC-returned=$D_RET used=$D_USED payload=$D_PAY  (production, phase-C only; expect n)";;
        esac
done

echo
echo "=== interpretation (claim 1517, regression) ==="
echo "  A (T0SZ=25 + TLBI): no WP markers + ladder ending at M2_MMUP! => the legacy start-level"
echo "      defect is reproduced deterministically (with an empty TLB the FIRST re-walk faults)."
echo "  B (T0SZ=16 + TLBI): full probe ladder + phase-C completion => the production fix"
echo "      resolves every boot (the claim-6460/7896 finding, now production)."
echo "  C (T0SZ=25 + TLBI + probe): dies at the first probe => same defect, site named."
echo "  D (T0SZ=16 + TLBI, phase-C only): phase C completes => the production configuration"
echo "      (what the class-B `zig build run` gate boots)."
echo
echo "Evidence saved under artifacts/ (walkprobe-gate.txt, walkprobe-report-{A,B,C,D}.txt,"
echo "walkprobe-compare.txt, walkprobe-cell-*-{run,marker,serial}-*)."
