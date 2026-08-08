#!/usr/bin/env bash
#
# verify-tx-diag.sh -- claim 0018 gate: bisect the FIRST post-exit virtio TX
# failure with per-stage NVRAM markers, and establish whether the death
# point is deterministic across N identical boots.
#
# Background: the transport works end to end PRE-exit (claim 0017); the
# post-exit flush hangs (claim 0013). The default flush's coarse markers
# (M2_TXST!/M2_TXNT!/M2_TXPL!) could not say WHERE in the window
# [desc/avail posted ... notify] the hang occurred, and the window also
# contained a large post-exit SetVariable (the 512 B probe tail) plus a
# logging-only status read. With -Dtx-diag=true the flush writes ten
# ordered 8-byte NVRAM markers (the proven claim-0009 channel), one around
# each potentially fatal operation, and drops the probe-tail write and the
# logging dump:
#
#   M2_TXFL!  1 entered virtio flush
#   M2_TXDA!  2 descriptor/avail buffers prepared
#   M2_TXCC!  3 DMA cache clean completed
#   M2_TXBR!  4 before first post-exit BAR/common-config read
#   M2_TXAR!  5 after that read
#   M2_TXBN!  6 before queue notify MMIO write
#   M2_TXAN!  7 after notify
#   M2_TXUP!  8 entered used-ring poll
#   M2_TXUC!  9 device changed used.idx (break condition seen)
#   M2_TXFR!  10 flush returned
#
# The FIRST post-exit flush's last marker names the smallest confirmed
# failure interval (see the interpretation table in the claim file). The
# gate boots the image BOOTS times (fresh variable store per boot) with
# identical settings, saves each boot's marker dump + vm-serial.log, and
# reports per-boot stopping stages and whether they agree.
#
# The serial channel is NOT the gate (post-exit serial stays silent on VZ —
# that is what we are bisecting). Run on Apple silicon only (VZ VM).
#
# NOTE: -Dtx-diag is meant to be used ALONE. Combining it with
# -Dpreexit-tx would also emit the TX-diag markers during the pre-exit
# experiment, and this script's "first M2_TXFL!" analysis assumes the first
# TXFL! is the first POST-exit flush.
#
# Usage: bash tools/verify-tx-diag.sh   (BOOTS env overrides the count)
# Evidence saved under artifacts/: tx-diag-gate.txt (this script's full
# output), tx-diag-run-N.txt (runner output), tx-diag-marker-N.txt (ladder
# dump), tx-diag-serial-N.log (serial log), tx-diag-report.txt (the
# verdict), efi-vars.bin, and the revision line inside the gate log.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

GATE_LOG="artifacts/tx-diag-gate.txt"
exec > >(tee "$GATE_LOG") 2>&1
# Let the tee drain on every exit path so the gate log is complete.
trap 'sleep 0.5' EXIT

BOOTS="${BOOTS:-6}"

ANALYZE_ONLY="${ANALYZE_ONLY:-0}"
if [ "$ANALYZE_ONLY" = "1" ]; then
    # Re-analyze the already-saved per-boot evidence without booting again.
    for f in artifacts/tx-diag-run-*.txt; do
        [ -e "$f" ] || { echo "no saved tx-diag-run-*.txt evidence; run the full gate first" >&2; exit 1; }
    done
    BOOTS="$(ls artifacts/tx-diag-run-*.txt 2>/dev/null | wc -l | tr -d ' ')"
else
    BOOTS="${BOOTS:-6}"
fi

echo "=== verify-tx-diag: claim 0018 — post-exit virtio TX bisect ($BOOTS identical boots) ==="

# --- tool versions + exact kernel/build revision -----------------------------
zig version; swift --version 2>&1 | head -1; sw_vers
REVISION="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
DIRTY="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
echo "revision: $REVISION branch=$BRANCH build=-Dtx-diag=true boots=$BOOTS dirty-files=$DIRTY"

# --- formatting + build gates (skipped in ANALYZE_ONLY re-analysis) ---------
if [ "$ANALYZE_ONLY" != "1" ]; then
    zig fmt --check boot/src/*.zig kernel/src/*.zig build.zig
    zig build -Dtx-diag=true
    zig build -Dtx-diag=true image
    swift build --package-path host/vm-runner --configuration release
    codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner
fi

# --- THE GATE: N identical boots, fresh variable store per boot --------------
REPORT="artifacts/tx-diag-report.txt"
: > "$REPORT"
{
    echo "DIPSHITOS tx-diag report — claim 0018 (post-exit virtio TX bisect)"
    echo "revision: $REVISION branch=$BRANCH build=-Dtx-diag=true boots=$BOOTS dirty-files=$DIRTY"
    echo "date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo
} >> "$REPORT"

BOOT_STAGES=()
i=0
while [ "$i" -lt "$BOOTS" ]; do
    i=$((i + 1))
    n=$(printf "%02d" "$i")
    echo
    echo "--- boot $i/$BOOTS (fresh variable store) ---"
    if [ "$ANALYZE_ONLY" = "1" ]; then
        # Reuse the saved evidence; derive the ladder from the run file.
        n=$(printf "%02d" "$i")
        grep '^MARKER-GATE: M2_' "artifacts/tx-diag-run-$n.txt" || true
        TXSEQ=()
        while IFS= read -r line; do
            TXSEQ+=("${line#MARKER-GATE: }")
        done < <(grep -E '^MARKER-GATE: M2_TX(FL|DA|CC|BR|AR|BN|AN|UP|UC|FR)!' "artifacts/tx-diag-run-$n.txt" || true)
        STOP="(no TX-diag markers)"
        if [ "${#TXSEQ[@]}" -gt 0 ]; then
            start=0
            while [ "$start" -lt "${#TXSEQ[@]}" ]; do
                if [ "${TXSEQ[$start]}" = "M2_TXFL!" ]; then break; fi
                start=$((start + 1))
            done
            last=""
            j=$start
            while [ "$j" -lt "${#TXSEQ[@]}" ]; do
                m="${TXSEQ[$j]}"
                if [ -n "$last" ] && [ "$m" = "M2_TXFL!" ]; then break; fi
                last="$m"
                j=$((j + 1))
            done
            STOP="$last"
        fi
        BOOT_STAGES+=("$STOP")
        echo "  first post-exit flush stopped at: $STOP"
        echo "boot $n: $STOP" >> "$REPORT"
        continue
    fi
    rm -f artifacts/efi-vars.bin
    set +e
    host/vm-runner/.build/release/VMRunner artifacts/disk.img artifacts/vm-serial.log \
        --dump-marker artifacts/marker-dump.txt --timeout 25 \
        > "artifacts/tx-diag-run-$n.txt" 2>&1
    RUNNER_RC=$?
    set -e
    [ -f artifacts/marker-dump.txt ] && cp artifacts/marker-dump.txt "artifacts/tx-diag-marker-$n.txt" || true
    [ -f artifacts/vm-serial.log ] && cp artifacts/vm-serial.log "artifacts/tx-diag-serial-$n.log" || true
    echo "  runner rc=$RUNNER_RC"
    grep '^MARKER-GATE: M2_' "artifacts/tx-diag-run-$n.txt" || echo "  (no markers at all)"

    # The ordered TX-diag markers of this boot (excludes M2_TXOK!, the
    # kernel_main post-flush marker).
    TXSEQ=()
    while IFS= read -r line; do
        TXSEQ+=("${line#MARKER-GATE: }")
    done < <(grep -E '^MARKER-GATE: M2_TX(FL|DA|CC|BR|AR|BN|AN|UP|UC|FR)!' "artifacts/tx-diag-run-$n.txt" || true)

    STOP=""
    if [ "${#TXSEQ[@]}" -eq 0 ]; then
        STOP="(no TX-diag markers)"
    else
        # The FIRST flush's last marker: walk from the first M2_TXFL! until a
        # second M2_TXFL! (next flush) or the end of the sequence.
        start=0
        while [ "$start" -lt "${#TXSEQ[@]}" ]; do
            if [ "${TXSEQ[$start]}" = "M2_TXFL!" ]; then break; fi
            start=$((start + 1))
        done
        last=""
        j=$start
        while [ "$j" -lt "${#TXSEQ[@]}" ]; do
            m="${TXSEQ[$j]}"
            if [ -n "$last" ] && [ "$m" = "M2_TXFL!" ]; then break; fi
            last="$m"
            j=$((j + 1))
        done
        STOP="$last"
    fi
    BOOT_STAGES+=("$STOP")

    echo "  first post-exit flush stopped at: $STOP"
    echo "boot $n: $STOP" >> "$REPORT"
done

# --- determinism + interpretation ----------------------------------------------
echo
echo "=== determinism across $BOOTS boots ==="
UNIQUE=()
for s in "${BOOT_STAGES[@]}"; do
    seen=0
    k=0
    while [ "$k" -lt "${#UNIQUE[@]}" ]; do
        [ "${UNIQUE[$k]}" = "$s" ] && seen=1
        k=$((k + 1))
    done
    [ "$seen" -eq 0 ] && UNIQUE+=("$s")
done
echo "  distinct stopping stages: ${#UNIQUE[@]}"
for s in "${UNIQUE[@]}"; do
    echo "    - $s"
done

echo
echo "=== interpretation (per unique stopping stage) ==="
for s in "${UNIQUE[@]}"; do
    echo "  $s:"
    case "$s" in
        M2_TXBR!*) echo "    M2_TXBR! written, M2_TXAR! absent -> THE FIRST POST-EXIT BAR/COMMON-CFG READ DOES NOT RETURN." ;;
        M2_TXBN!*) echo "    M2_TXBN! written, M2_TXAN! absent -> THE NOTIFY MMIO WRITE DOES NOT RETURN (read returned)." ;;
        M2_TXUP!*|M2_TXAN!*) echo "    notify returned, used-ring poll entered but M2_TXUC! absent -> used.idx never changed within the poll bound." ;;
        M2_TXUC!*) echo "    device changed used.idx (M2_TXUC!); flush returned next (M2_TXFR!)." ;;
        M2_TXFR!*) echo "    FIRST POST-EXIT TX FLUSH RETURNED (stages 1-10 all seen) — the failure is later, or the probe-tail removal fixed the hang." ;;
        M2_TXFL!*) echo "    M2_TXFL! written, no M2_TXDA! -> died between flush entry and descriptor publication (FIRST flush: the ring cannot be full, so this is the ring guard or the M2_TXDA! marker write; NOT an MMIO TX access)." ;;
        M2_TXDA!*|M2_TXCC!*|M2_TXAR!*) echo "    died inside a marker-write window (stage $s); not an MMIO access — re-check the flush order." ;;
        *) echo "    no TX-diag markers — kernel died before the first post-exit flush (pre-exit ladder names the site)." ;;
    esac
done

# M2_TXOK! = kernel_main's post-flush marker ("first TX returned"). Present
# in every boot where the first flush returned at all.
echo
echo "=== M2_TXOK! (kernel_main: first TX returned) presence per boot ==="
i=0
while [ "$i" -lt "$BOOTS" ]; do
    i=$((i + 1))
    n=$(printf "%02d" "$i")
    if grep -q '^MARKER-GATE: M2_TXOK!' "artifacts/tx-diag-run-$n.txt"; then
        echo "  boot $n: M2_TXOK! present"
        echo "boot $n: M2_TXOK! present" >> "$REPORT"
    else
        echo "  boot $n: M2_TXOK! absent"
        echo "boot $n: M2_TXOK! absent" >> "$REPORT"
    fi
done

echo
echo "=== non-empty vm-serial.log per boot (unexpected for a hang) ==="
i=0
while [ "$i" -lt "$BOOTS" ]; do
    i=$((i + 1))
    n=$(printf "%02d" "$i")
    SIZE=$(wc -c < "artifacts/tx-diag-serial-$n.log" 2>/dev/null | tr -d ' ')
    echo "  boot $n: $SIZE byte(s)"
    echo "boot $n: serial-bytes=$SIZE" >> "$REPORT"
done

echo
echo "=== per-boot summary ==="
i=0
while [ "$i" -lt "$BOOTS" ]; do
    echo "  boot $((i + 1)): ${BOOT_STAGES[$i]}"
    i=$((i + 1))
done

# --- verdict ------------------------------------------------------------------
if [ "${#UNIQUE[@]}" -eq 1 ]; then
    echo
    echo "VERDICT: deterministic across $BOOTS boots — stopping stage: ${UNIQUE[0]}"
    echo "verdict: deterministic (${UNIQUE[0]})" >> "$REPORT"
else
    echo
    echo "VERDICT: NOT deterministic — ${#UNIQUE[@]} distinct stopping stages across $BOOTS boots"
    echo "verdict: not-deterministic ($(IFS=,; echo "${UNIQUE[*]}"))" >> "$REPORT"
fi
echo
echo "Evidence saved under artifacts/ (tx-diag-gate.txt, tx-diag-run-N.txt, tx-diag-marker-N.txt, tx-diag-serial-N.log, tx-diag-report.txt, efi-vars.bin)."
