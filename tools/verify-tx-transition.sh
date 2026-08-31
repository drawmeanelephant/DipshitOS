#!/usr/bin/env bash
#
# verify-tx-transition.sh -- claim 0020 gate: which transition destroys
# access to the virtio-pci console? Controlled one-variable-at-a-time
# experiments, one phase per build+boot:
#
#   A. pre-ExitBootServices
#   B. immediately after successful ExitBootServices, while the firmware's
#      translation regime is still active (before VirelaiOS page tables)
#   C. immediately after installing the VirelaiOS identity map (before any
#      unrelated runtime-service/diagnostic work)
#   D. at the normal final location (the banner TX site)
#
# Each phase build (-Dtx-transition-{a,b,c,d}, default off) runs ONE
# controlled TX attempt of the SAME fixed payload ("VIRELAIOS TRANSITION
# TX\n") through the SAME armed transport and SAME virtio_pci_flush(),
# bracketed by persistent NVRAM markers:
#
#   M2_TRx1!  experiment entered, about to flush (x = A/B/C/D)
#   M2_TRx2!  flush returned (TX did not hang)
#   M2_TRxU!  flush returned AND used.idx advanced (device consumed)
#   M2_TRNX!  experiment skipped (transport not armed pre-exit)
#
# The flush's own M2_TXST!/TXNT!/TXPL! stage markers interleave and name
# the hang site inside the flush (TXST! without TXNT! = died at the first
# common-cfg read; TXNT! without TXPL! = died in the used-ring poll).
# vm-serial.log is the "bytes reached the host" evidence.
#
# The FIRST failed phase names the transition that destroys access (see the
# claim file's interpretation table). Run on Apple silicon only (VZ VM).
# Diagnostic only: a payload hit does NOT pass the claim-0002 serial gate.
#
# Usage: bash tools/verify-tx-transition.sh   (PHASE_BOOTS env overrides the
# boots per phase, default 2)
# Evidence saved under artifacts/: transition-gate.txt (full output),
# transition-run-<phase>-<n>.txt (runner output), transition-marker-<phase>-<n>.txt
# (marker dump), transition-serial-<phase>-<n>.log (serial log),
# transition-report.txt (per-boot detail), transition-matrix.txt (the matrix).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

GATE_LOG="artifacts/transition-gate.txt"
exec > >(tee "$GATE_LOG") 2>&1
# Let the tee drain on every exit path so the gate log is complete.
trap 'sleep 0.5' EXIT

PHASE_BOOTS="${PHASE_BOOTS:-2}"

PHASES=(a b c d)
PHASE_NAME=(pre-EBS post-EBS/pre-MMU post-MMU final-location)

echo "=== verify-tx-transition: claim 0020 — TX-transition matrix (${PHASE_BOOTS} boot(s) per phase, 4 phases) ==="

# --- tool versions + exact kernel/build revision -----------------------------
zig version; swift --version 2>&1 | head -1; sw_vers
REVISION="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
DIRTY="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
echo "revision: $REVISION branch=$BRANCH build=-Dtx-transition-{a,b,c,d} boots-per-phase=$PHASE_BOOTS dirty-files=$DIRTY"

# --- formatting gate ---------------------------------------------------------
zig fmt --check boot/src/*.zig kernel/src/*.zig build.zig

# --- build gates: every phase kernel compiles, default build unchanged -----
zig build
for p in "${PHASES[@]}"; do
    echo "--- compile phase $p kernel ---"
    zig build "-Dtx-transition-$p=true"
done
swift build --package-path host/vm-runner --configuration release
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner

# --- THE GATE: per-phase boots, fresh variable store per boot -----------------
REPORT="artifacts/transition-report.txt"
MATRIX="artifacts/transition-matrix.txt"
: > "$REPORT"
: > "$MATRIX"
{
    echo "VIRELAIOS TX-transition matrix — claim 0020"
    echo "revision: $REVISION branch=$BRANCH boots-per-phase=$PHASE_BOOTS dirty-files=$DIRTY"
    echo "date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo
} >> "$REPORT"

# First-boot-wins matrix cells, one scalar per phase (bash 3.2 compatible).
# Set a cell only if unset.
set_cell() { # varname value
    local v="$1" val="$2"
    if [ -z "${!v+x}" ]; then eval "$v='$val'"; fi
}

for idx in 0 1 2 3; do
    p="${PHASES[$idx]}"
    pu=$(printf '%s' "$p" | tr 'a-z' 'A-Z') # marker names are uppercase: M2_TR${pu}1!
    name="${PHASE_NAME[$idx]}"
    echo
    echo "=== phase $p ($name): ${PHASE_BOOTS} boot(s), fresh variable store per boot ==="
    # Rebuild the phase image IMMEDIATELY before its boots: all phase images
    # share artifacts/disk.img, so the image must be the phase's own when the
    # VM boots (a stale last-built image would run the wrong kernel).
    echo "--- image for phase $p ---"
    zig build "-Dtx-transition-$p=true" image >/dev/null
    n=0
    while [ "$n" -lt "$PHASE_BOOTS" ]; do
        n=$((n + 1))
        tag="${p}-$(printf "%02d" "$n")"
        rm -f artifacts/efi-vars.bin
        set +e
        host/vm-runner/.build/release/VMRunner artifacts/disk.img artifacts/vm-serial.log \
            --dump-marker artifacts/marker-dump.txt --timeout 25 \
            > "artifacts/transition-run-$tag.txt" 2>&1
        RUNNER_RC=$?
        set -e
        [ -f artifacts/marker-dump.txt ] && cp artifacts/marker-dump.txt "artifacts/transition-marker-$tag.txt" || true
        [ -f artifacts/vm-serial.log ] && cp artifacts/vm-serial.log "artifacts/transition-serial-$tag.log" || true
        echo "  boot $n rc=$RUNNER_RC"
        # Ordered ladder from the runner's MARKER-GATE lines.
        LADDER=()
        while IFS= read -r line; do
            LADDER+=("${line#MARKER-GATE: }")
        done < <(grep -E '^MARKER-GATE: M2_' "artifacts/transition-run-$tag.txt" || true)
        if [ "${#LADDER[@]}" -eq 0 ]; then
            echo "  boot $n: NO MARKERS AT ALL"
            set_cell "LAST_$p" "(no markers)"
            continue
        fi
        set_cell "LAST_$p" "${LADDER[${#LADDER[@]}-1]}"

        # Locate the experiment window: the LAST M2_TR${p}1! marker. The
        # flush's stage markers (TXST!/TXNT!/TXPL!) plus the experiment's
        # x2/xU follow it; the continuing boot's markers come after x2.
        start=-1
        i=0
        while [ "$i" -lt "${#LADDER[@]}" ]; do
            if [ "${LADDER[$i]}" = "M2_TR${pu}1!" ]; then start=$i; fi
            i=$((i + 1))
        done

        ENTER=0; RETURNED=0; USED=0; SKIP=0; TXST=0; TXNT=0; TXPL=0; AFTER=0
        if [ "$start" -eq -1 ]; then
            # Experiment never entered. Any TRNX! in the ladder = skipped.
            for m in "${LADDER[@]}"; do
                [ "$m" = "M2_TRNX!" ] && SKIP=1
            done
            AFTER=1 # the VM is alive; the experiment just did not run
        else
            ENTER=1
            # window_end = the experiment's x2 marker when present; otherwise
            # the last flush-stage marker (the flush hung mid-window). Once
            # the experiment's flush has RETURNED (x2 seen), later TXST!/TXNT!/
            # TXPL! belong to the continuing boot's banner flush and must NOT
            # extend the window — they prove the VM stayed alive.
            end_idx=$start
            i=$start
            while [ "$i" -lt "${#LADDER[@]}" ]; do
                m="${LADDER[$i]}"
                case "$m" in
                    "M2_TR${pu}2!") RETURNED=1; end_idx=$i ;;
                    "M2_TR${pu}U!") USED=1; end_idx=$i ;;
                    "M2_TRNX!") SKIP=1 ;;
                    "M2_TXST!"|"M2_TXNT!"|"M2_TXPL!")
                        if [ "$RETURNED" = 0 ]; then end_idx=$i; fi ;;
                esac
                i=$((i + 1))
            done
            # Anything strictly after the experiment's own bracket proves the
            # VM continued (for D: the banner flush's own TXST! counts).
            i=$((end_idx + 1))
            while [ "$i" -lt "${#LADDER[@]}" ]; do
                AFTER=1
                i=$((i + 1))
            done
        fi

        # Payload bytes reaching the host (vm-serial.log).
        PAYLOAD=0
        [ -f "artifacts/transition-serial-$tag.log" ] && grep -qF -- "VIRELAIOS TRANSITION TX" "artifacts/transition-serial-$tag.log" && PAYLOAD=1
        SERIAL_BYTES=$(wc -c < "artifacts/transition-serial-$tag.log" 2>/dev/null | tr -d ' ')

        {
            echo "phase $p boot $n: entered=$ENTER returned=$RETURNED used-advanced=$USED skipped=$SKIP payload=$PAYLOAD serial-bytes=$SERIAL_BYTES alive=$AFTER last-marker=${LADDER[${#LADDER[@]}-1]}"
            echo "  ladder: ${LADDER[*]}"
        } >> "$REPORT"
        echo "  entered=$ENTER returned=$RETURNED used-advanced=$USED skipped=$SKIP payload=$PAYLOAD alive=$AFTER last=${LADDER[${#LADDER[@]}-1]}"

        # First boot per phase populates the matrix cells.
        set_cell "ENTER_$p" "$ENTER"
        [ "$RETURNED" = 1 ] && set_cell "RETURNED_$p" yes
        [ "$USED" = 1 ] && set_cell "USED_$p" yes
        [ "$SKIP" = 1 ] && set_cell "SKIP_$p" skipped
        [ "$PAYLOAD" = 1 ] && set_cell "PAYLOAD_$p" yes
        [ "$AFTER" = 1 ] && set_cell "ALIVE_$p" yes
    done
done

# --- the matrix ---------------------------------------------------------------
echo
echo "=== TRANSITION MATRIX (first boot's evidence per phase; per-boot detail in the report) ==="
printf "%-22s %-16s %-12s %-16s %-10s %-10s\n" "phase" "TX reaches host" "TX returned" "used.idx advanced" "VM alive" "last marker"
printf "%-22s %-16s %-12s %-16s %-10s %-10s\n" "---" "---" "---" "---" "---" "---"
{
    echo "TRANSITION MATRIX (claim 0020) — revision $REVISION, $PHASE_BOOTS boot(s) per phase:"
    printf "%-22s %-16s %-12s %-16s %-10s %-10s\n" "phase" "TX reaches host" "TX returned" "used.idx advanced" "VM alive" "last marker"
} >> "$MATRIX"
for idx in 0 1 2 3; do
    p="${PHASES[$idx]}"
    name="${PHASE_NAME[$idx]}"
    eval "hit=\${PAYLOAD_$p:-NO}; ret=\${RETURNED_$p:-NO}; used=\${USED_$p:-NO}; alive=\${ALIVE_$p:-NO}; last=\${LAST_$p:-?}"
    printf "%-22s %-16s %-12s %-16s %-10s %-10s\n" "$p ($name)" "$hit" "$ret" "$used" "$alive" "$last" | tee -a "$MATRIX"
done

# --- interpretation (the first failed phase names the transition) ---------------
echo
echo "=== interpretation ==="
for idx in 0 1 2 3; do
    p="${PHASES[$idx]}"
    name="${PHASE_NAME[$idx]}"
    eval "hit=\${PAYLOAD_$p:-NO}; ret=\${RETURNED_$p:-NO}; used=\${USED_$p:-NO}; skip=\${SKIP_$p:-}; last=\${LAST_$p:-?}"
    if [ "$skip" = "skipped" ]; then
        echo "  phase $p ($name): SKIPPED (transport not armed) — matrix indeterminate for this phase"
        continue
    fi
    if [ "$ret" = "NO" ]; then
        echo "  phase $p ($name): HUNG — the flush never returned (last marker: $last)"
    elif [ "$hit" = "NO" ]; then
        echo "  phase $p ($name): returned but bytes did NOT reach vm-serial.log (used advanced=$used)"
    else
        echo "  phase $p ($name): WORKED — payload reached vm-serial.log (used advanced=$used)"
    fi
done
echo
echo "  The FIRST phase that failed (HUNG or no bytes) names the transition that destroys console access;"
echo "  see docs/claims/0020-tx-transition-matrix.md for the interpretation table."
echo
echo "Evidence saved under artifacts/ (transition-gate.txt, transition-report.txt, transition-matrix.txt, transition-run-*, transition-marker-*, transition-serial-*)."
