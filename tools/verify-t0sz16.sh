#!/usr/bin/env bash
#
# verify-t0sz16.sh -- claim 1517 (claims 6460/7896 follow-up) class-D
# regression: the production kernel now programs TCR_EL1.T0SZ=16 (W=48, the
# 4 KiB stage-1 walk starts at level 0 — matching the built L0-rooted
# hierarchy) and executes the full TLBI at the switch; -Dt0sz25 selects the
# legacy start level 25 (W=39, walk starts at level 1 — the claim-6460/7896
# mismatch that made every fresh post-switch walk fault on VZ).
#
# Controlled A/B on real Apple-silicon VZ hardware, using the existing
# claim-0020 phase-C TX experiment (-Dtx-transition-c=true) as the payload
# and observation point:
#
#   A. baseline:  -Dtx-transition-c=true -Dt0sz25=true  (T0SZ=25, legacy)
#   B. candidate: -Dtx-transition-c=true                 (T0SZ=16, production)
#
# SAME page tables, SAME TTBR0 root, SAME MAIR/attributes, SAME phase-C TX
# experiment; the kernels differ in the T0SZ immediate (+ the TLBI is
# unconditional production behavior, claim 1517). Fresh EFI variable store
# per boot. Per-boot evidence: runner output, complete NVRAM marker ladder,
# vm-serial.log, revision/flags.
#
# Per boot this reports:
#   entered        M2_TRC1! present (phase C entered)
#   returned       M2_TRC2! present (flush returned)
#   used-advanced  M2_TRCU! present (used.idx advanced)
#   payload        exact "DIPSHITOS TRANSITION TX" line in vm-serial.log
#   last marker    the last persisted ladder marker
#
# SUPPORT FOR THE HYPOTHESIS requires ALL of: baseline reproduces the known
# post-MMU failure AND candidate repeatedly lets phase C return AND
# used.idx advances AND the exact payload reaches vm-serial.log. A compile,
# boot, marker advance, or returning MMIO read alone is NOT "fixed".
#
# Diagnostic only (class D): a payload hit does NOT pass the claim-0002
# serial gate by itself (the gate is `zig build run`). Since claim 1517 the
# production default IS T0SZ=16 + TLBI; -Dt0sz25 reproduces the old
# production start level for regression.
#
# Usage:
#   bash tools/verify-t0sz16.sh                     # both variants, BOOTS each
#   VARIANT=baseline  BOOTS=6 bash tools/verify-t0sz16.sh   # baseline only
#   VARIANT=candidate BOOTS=6 bash tools/verify-t0sz16.sh   # candidate only
# The comparison + interpretation run whenever both per-variant report files
# exist (also on the second half of a split run).
#
# Evidence saved under artifacts/: t0sz16-gate.txt (full output),
# t0sz16-report-{baseline,candidate}.txt (per-boot detail),
# t0sz16-compare.txt (A/B table), t0sz16-baseline-{run,marker,serial}-<NN>.*
# and t0sz16-candidate-{run,marker,serial}-<NN>.* per boot.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

GATE_LOG="artifacts/t0sz16-gate.txt"
exec > >(tee "$GATE_LOG") 2>&1
trap 'sleep 0.5' EXIT

BOOTS="${BOOTS:-6}"
VARIANT="${VARIANT:-both}" # baseline | candidate | both

echo "=== verify-t0sz16: claim 6460 — T0SZ start-level A/B ($BOOTS boot(s) per variant, variant=$VARIANT) ==="

# --- tool versions + exact kernel/build revision -----------------------------
zig version; swift --version 2>&1 | head -1; sw_vers
REVISION="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
DIRTY="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
BASELINE_FLAGS="-Dtx-transition-c=true -Dt0sz25=true"
CANDIDATE_FLAGS="-Dtx-transition-c=true"
echo "revision: $REVISION branch=$BRANCH baseline-flags=$BASELINE_FLAGS candidate-flags=$CANDIDATE_FLAGS boots-per-variant=$BOOTS dirty-files=$DIRTY"

REPORT_BASE="artifacts/t0sz16-report-baseline.txt"
REPORT_CAND="artifacts/t0sz16-report-candidate.txt"
COMPARE="artifacts/t0sz16-compare.txt"

# --- build gates: both variants compile, default build unchanged ------------
if [ "$VARIANT" != "candidate" ]; then
    zig fmt --check boot/src/*.zig kernel/src/*.zig build.zig
    zig build
    echo "--- compile baseline kernel ---"
    zig build kernel $BASELINE_FLAGS
fi
if [ "$VARIANT" != "baseline" ]; then
    echo "--- compile candidate kernel ---"
    zig build kernel $CANDIDATE_FLAGS
fi
swift build --package-path host/vm-runner --configuration release
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner

# --- THE GATE: per-variant boots, fresh variable store per boot --------------
# run_one <report> <tag> <build flags> — build the image for the variant, boot
# once with a fresh variable store, save runner output / marker dump / serial
# log under artifacts/t0sz16-<tag>-{run,marker,serial}-<NN>.*, print the
# ordered ladder, and append a summary line to the report.
run_one() {
    local report="$1" tag="$2" flags="$3"
    echo "--- image for $tag ($flags) ---"
    # shellcheck disable=SC2086
    zig build $flags image >/dev/null
    rm -f artifacts/efi-vars.bin
    set +e
    host/vm-runner/.build/release/VMRunner artifacts/disk.img artifacts/vm-serial.log \
        --dump-marker artifacts/marker-dump.txt --timeout 25 \
        > "artifacts/t0sz16-$tag-run.txt" 2>&1
    local RUNNER_RC=$?
    set -e
    [ -f artifacts/marker-dump.txt ] && cp artifacts/marker-dump.txt "artifacts/t0sz16-$tag-marker.txt" || true
    [ -f artifacts/vm-serial.log ] && cp artifacts/vm-serial.log "artifacts/t0sz16-$tag-serial.log" || true

    local LADDER=()
    while IFS= read -r line; do
        LADDER+=("${line#MARKER-GATE: }")
    done < <(grep -E '^MARKER-GATE: M2_' "artifacts/t0sz16-$tag-run.txt" || true)

    if [ "${#LADDER[@]}" -eq 0 ]; then
        echo "$tag rc=$RUNNER_RC: NO MARKERS AT ALL"
        echo "$tag: entered=0 returned=0 used-advanced=0 skipped=0 payload=0 serial-bytes=0 alive=0 last-marker=(no markers)" >> "$report"
        return
    fi

    # Locate the phase-C experiment window: the LAST M2_TRC1! marker.
    local start=-1 i=0 m
    while [ "$i" -lt "${#LADDER[@]}" ]; do
        if [ "${LADDER[$i]}" = "M2_TRC1!" ]; then start=$i; fi
        i=$((i + 1))
    done

    local ENTER=0 RETURNED=0 USED=0 SKIP=0 AFTER=0 end_idx
    if [ "$start" -eq -1 ]; then
        for m in "${LADDER[@]}"; do
            [ "$m" = "M2_TRNX!" ] && SKIP=1
        done
        AFTER=1
    else
        ENTER=1
        end_idx=$start
        i=$start
        while [ "$i" -lt "${#LADDER[@]}" ]; do
            m="${LADDER[$i]}"
            case "$m" in
                "M2_TRC2!") RETURNED=1; end_idx=$i ;;
                "M2_TRCU!") USED=1; end_idx=$i ;;
                "M2_TRNX!") SKIP=1 ;;
                "M2_TXST!"|"M2_TXNT!"|"M2_TXPL!")
                    [ "$RETURNED" = 0 ] && end_idx=$i ;;
            esac
            i=$((i + 1))
        done
        i=$((end_idx + 1))
        while [ "$i" -lt "${#LADDER[@]}" ]; do
            AFTER=1
            i=$((i + 1))
        done
    fi

    local PAYLOAD=0
    [ -f "artifacts/t0sz16-$tag-serial.log" ] && grep -qF -- "DIPSHITOS TRANSITION TX" "artifacts/t0sz16-$tag-serial.log" && PAYLOAD=1
    local SERIAL_BYTES
    SERIAL_BYTES=$(wc -c < "artifacts/t0sz16-$tag-serial.log" 2>/dev/null | tr -d ' ')

    {
        echo "$tag: entered=$ENTER returned=$RETURNED used-advanced=$USED skipped=$SKIP payload=$PAYLOAD serial-bytes=$SERIAL_BYTES alive=$AFTER last-marker=${LADDER[${#LADDER[@]}-1]}"
        echo "  ladder: ${LADDER[*]}"
    } >> "$report"
    echo "$tag rc=$RUNNER_RC: entered=$ENTER returned=$RETURNED used-advanced=$USED skipped=$SKIP payload=$PAYLOAD alive=$AFTER last=${LADDER[${#LADDER[@]}-1]}"
}

if [ "$VARIANT" = "baseline" ] || [ "$VARIANT" = "both" ]; then
    : > "$REPORT_BASE"
    {
        echo "DIPSHITOS T0SZ start-level A/B (baseline) — claim 6460"
        echo "revision: $REVISION branch=$BRANCH boots=$BOOTS dirty-files=$DIRTY"
        echo "flags: $BASELINE_FLAGS   (T0SZ=25, legacy start level)"
        echo "date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        echo
    } >> "$REPORT_BASE"
    n=0
    while [ "$n" -lt "$BOOTS" ]; do
        n=$((n + 1))
        echo
        echo "=== baseline boot $n (T0SZ=25, legacy) ==="
        run_one "$REPORT_BASE" "baseline-$(printf "%02d" "$n")" "$BASELINE_FLAGS"
    done
fi

if [ "$VARIANT" = "candidate" ] || [ "$VARIANT" = "both" ]; then
    : > "$REPORT_CAND"
    {
        echo "DIPSHITOS T0SZ start-level A/B (candidate) — claim 6460"
        echo "revision: $REVISION branch=$BRANCH boots=$BOOTS dirty-files=$DIRTY"
        echo "flags: $CANDIDATE_FLAGS   (T0SZ=16, production)"
        echo "date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        echo
    } >> "$REPORT_CAND"
    n=0
    while [ "$n" -lt "$BOOTS" ]; do
        n=$((n + 1))
        echo
        echo "=== candidate boot $n (T0SZ=16, production) ==="
        run_one "$REPORT_CAND" "candidate-$(printf "%02d" "$n")" "$CANDIDATE_FLAGS"
    done
fi

# --- the A/B comparison (runs whenever both report files have data) ----------
if [ -s "$REPORT_BASE" ] && [ -s "$REPORT_CAND" ]; then
    : > "$COMPARE"
    {
        echo "A/B COMPARISON (claim 6460) — revision $REVISION, per-boot detail in the report files:"
        echo "baseline ($BASELINE_FLAGS) vs candidate ($CANDIDATE_FLAGS)"
        printf "%-14s %-8s %-10s %-14s %-10s %-10s %-12s\n" "boot" "entered" "returned" "used.adv" "payload" "alive" "last marker"
    } >> "$COMPARE"
    echo
    echo "=== A/B COMPARISON (claim 6460) ==="
    printf "%-14s %-8s %-10s %-14s %-10s %-10s %-12s\n" "boot" "entered" "returned" "used.adv" "payload" "alive" "last marker"
    printf "%-14s %-8s %-10s %-14s %-10s %-10s %-12s\n" "---" "---" "---" "---" "---" "---" "---"
    B_ENTER=0; B_RET=0; B_USED=0; B_PAY=0; C_ENTER=0; C_RET=0; C_USED=0; C_PAY=0
    while IFS= read -r line; do
        case "$line" in
            baseline-*) : ;;
            *) continue ;;
        esac
        tag="${line%%:*}"
        EN=$(printf '%s' "$line" | sed -E 's/^.* entered=([01]) .*$/\1/')
        RT=$(printf '%s' "$line" | sed -E 's/^.* returned=([01]) .*$/\1/')
        US=$(printf '%s' "$line" | sed -E 's/^.* used-advanced=([01]) .*$/\1/')
        PL=$(printf '%s' "$line" | sed -E 's/^.* payload=([01]) .*$/\1/')
        AL=$(printf '%s' "$line" | sed -E 's/^.* alive=([01]) .*$/\1/')
        LM=$(printf '%s' "$line" | sed -E 's/^.* last-marker=(.*)$/\1/')
        B_ENTER=$((B_ENTER + EN)); B_RET=$((B_RET + RT)); B_USED=$((B_USED + US)); B_PAY=$((B_PAY + PL))
        printf "%-14s %-8s %-10s %-14s %-10s %-10s %-12s\n" "$tag" "$EN" "$RT" "$US" "$PL" "$AL" "$LM" | tee -a "$COMPARE"
    done < "$REPORT_BASE"
    while IFS= read -r line; do
        case "$line" in
            candidate-*) : ;;
            *) continue ;;
        esac
        tag="${line%%:*}"
        EN=$(printf '%s' "$line" | sed -E 's/^.* entered=([01]) .*$/\1/')
        RT=$(printf '%s' "$line" | sed -E 's/^.* returned=([01]) .*$/\1/')
        US=$(printf '%s' "$line" | sed -E 's/^.* used-advanced=([01]) .*$/\1/')
        PL=$(printf '%s' "$line" | sed -E 's/^.* payload=([01]) .*$/\1/')
        AL=$(printf '%s' "$line" | sed -E 's/^.* alive=([01]) .*$/\1/')
        LM=$(printf '%s' "$line" | sed -E 's/^.* last-marker=(.*)$/\1/')
        C_ENTER=$((C_ENTER + EN)); C_RET=$((C_RET + RT)); C_USED=$((C_USED + US)); C_PAY=$((C_PAY + PL))
        printf "%-14s %-8s %-10s %-14s %-10s %-10s %-12s\n" "$tag" "$EN" "$RT" "$US" "$PL" "$AL" "$LM" | tee -a "$COMPARE"
    done < "$REPORT_CAND"
    printf "%-14s %-8s %-10s %-14s %-10s %-10s\n" "baseline total" "$B_ENTER/$BOOTS" "$B_RET/$BOOTS" "$B_USED/$BOOTS" "$B_PAY/$BOOTS" "" | tee -a "$COMPARE"
    printf "%-14s %-8s %-10s %-14s %-10s %-10s\n" "candidate total" "$C_ENTER/$BOOTS" "$C_RET/$BOOTS" "$C_USED/$BOOTS" "$C_PAY/$BOOTS" "" | tee -a "$COMPARE"

    # --- interpretation ---
    echo
    echo "=== interpretation ==="
    if [ "$B_RET" -eq 0 ] && [ "$C_RET" -ge 1 ] && [ "$C_USED" -ge 1 ] && [ "$C_PAY" -ge 1 ]; then
        echo "  CONFIRMED (claim 1517): legacy T0SZ=25 reproduces the post-MMU failure (phase C"
        echo "  never returns); production T0SZ=16 lets phase C return, used.idx advances, and the"
        echo "  exact TX payload reaches vm-serial.log. The corrected start level restores"
        echo "  post-MMU virtio-pci console TX on VZ (the class-B gate is `zig build run`)."
    elif [ "$C_RET" -eq 0 ]; then
        echo "  REGRESSION: production T0SZ=16 fails at the same boundary (phase C never returns)."
        echo "  The start-level fix is not sufficient on this host/run; investigate before merging."
    elif [ "$C_RET" -ge 1 ] && [ "$C_PAY" -eq 0 ]; then
        echo "  PARTIAL: production T0SZ=16 moves the failure later (phase C returns / used advances at"
        echo "  least once) but TX does not complete. Record the new smallest confirmed interval."
    else
        echo "  See the per-boot table; neither clear confirmation nor clear regression at this sample."
        echo "  Check whether baseline reproduced the historical failure (premise check)."
    fi
else
    echo
    echo "(comparison skipped: both per-variant report files needed; run the other VARIANT or run without VARIANT)"
fi
echo
echo "Evidence saved under artifacts/ (t0sz16-gate.txt, t0sz16-report-{baseline,candidate}.txt, t0sz16-compare.txt, t0sz16-{baseline,candidate}-{run,marker,serial}-*)."
