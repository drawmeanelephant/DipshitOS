#!/usr/bin/env bash
#
# verify-live-file-browser.sh -- claim 4046 (Milestone 13, Card B4) class-B
# capstone gate: desktop composition, verified on real Apple silicon
# Virtualization.framework hardware.
#
# The gate proves the full B4 arc end-to-end from EL0, composing B2's
# manifest-driven launcher with B3's FILE.BIN:
#   1. DESKTOP.BIN boots and reads its menu from /esp/APPS.TXT — 19 entries
#      today (9 at M13 close; grew via M15 C4, M23 E1, M27 G6, the M30/M31
#      ELF rows, and M32's ZC.BIN), FILE.BIN included (the manifest, not the
#      hardcoded fallback).
#   2. The runner navigates the manifest menu to FILE.BIN and presses Enter;
#      DESKTOP launches it through the M11 sys_exec seam (slot 28).
#   3. FILE.BIN opens its own window (auto-focused), lists `/data/` via
#      sys_dir_list (slot 27), and the runner's second Enter opens the
#      selected first entry read-only via sys_file_open/read (slots 23/24).
#      OBSERVED 2026-08-24 (claim 2259): the opened entry is DATA.TXT —
#      PR #512 (658bd86, 2026-08-23) added alphabetical sorting to the
#      listing (sort_column=.name, sort_asc=true), and DATA.TXT sorts
#      before README.TXT, so the initial selection (index 0) changed.
#   4. The syscalls report proves the seam: sys_exec once, sys_dir_list
#      twice (main listing + F4 du walk, claim 2539), file_open six times
#      and file_read three times — desktop host-open (HF4, fails) + ESP
#      manifest + FILE.BIN's recent-ring load (fails) + preview + view +
#      recent-ring save (claim 2539) — see the needles below.
#
# Delete/rename (B1, slots 34-37) are proven separately by
# tools/verify-live-fs-mutation.sh; this gate keeps the read-only browser
# arc deterministic.
#
# Run isolation (#523 item 2 / issue #528, claim 5069; fleet remainder
# claim 2259): private stacked disk (pristine-per-boot overlay), EFI var
# store, serial log, and screen captures under $RUN_DIR. The browse arc is
# read-only by design, so the throwaway overlay is the right disk mode.
# Set VIRELAI_GATE_SUFFIX=_alt for distinct canonical evidence names;
# VIRELAI_KEEP_RUN=1 keeps the scratch dir.
#
# Usage:
#   bash tools/verify-live-file-browser.sh
#

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source tools/lib/gate-run.sh

SUFFIX="${VIRELAI_GATE_SUFFIX:-}"
art() { printf 'artifacts/%s%s' "$1" "$SUFFIX"; }

GATE_LOG="$(art live-file-browser-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

REPORT="$(art live-file-browser-report.txt)"

echo "=== verify-live-file-browser: claim 4046 — Milestone 13 B4 desktop composition on VZ ==="

PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export PATH

zig version; swift --version 2>&1 | head -1; sw_vers
REVISION="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
DIRTY="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
echo "revision: $REVISION branch=$BRANCH dirty-files=$DIRTY"

# Build all binaries and disk image
zig build
zig build image
swift build --package-path host/vm-runner --configuration release
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner

# --- per-run isolation -------------------------------------------------------
gate_begin live-file-browser
echo "run dir: $RUN_DIR"

# Boot the desktop only; FILE.BIN is launched from EL0 by the desktop, never
# exec'd by the monitor (the composition proof).
cat > "$RUN_DIR/script.txt" <<'EOF'
exec DESKTOP.BIN
EOF

cat > "$RUN_DIR/script2.txt" <<'EOF'
echo done-file-sweep
syscalls
EOF

STATIC_EXIT_LINE="tasks user-el0 exited status=7"

# Eight Down arrows walk the manifest menu from CALC.BIN (index 0)
# to FILE.BIN (index 8 — still eighth even after the M15/M23 appends,
# which landed below it); the first Return launches it, the second Return
# (arriving once FILE.BIN's window is focused) opens the selected entry —
# DATA.TXT since the sorted-listing change (see header note).
CHORDS="down,down,down,down,down,down,down,down,return,return"

echo "--- Phase 1: Running desktop composition (DESKTOP -> FILE.BIN) on VZ ---"
rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial.log"
rm -f "$RUN_DIR"/gpu-screen-*

set +e
host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
    --serial "$RUN_DIR/vm-serial.log" \
    --display --input --screen "$RUN_DIR/gpu-screen" \
    --script "$RUN_DIR/script.txt" \
    --script-after "$STATIC_EXIT_LINE" \
    --input-chords "$CHORDS" \
    --input-chords-after "desktop: menu ready" \
    --input-chords-delay 2.0 \
    --script2 "$RUN_DIR/script2.txt" \
    --script2-after "file: view DATA.TXT" \
    --script-expect "done-file-sweep" \
    --timeout 90 > "$(art live-file-browser-run.txt)" 2>&1
RC=$?
set -e

[ -f "$RUN_DIR/vm-serial.log" ] && cp "$RUN_DIR/vm-serial.log" "$(art live-file-browser-serial.log)" || true
cp "$RUN_DIR"/gpu-screen-* artifacts/ 2>/dev/null || true
SER="$(art live-file-browser-serial.log)"

echo "VMRunner exit code: $RC"
if [ $RC -ne 0 ]; then
    echo "ERROR: VMRunner failed with return code $RC"
    cat "$(art live-file-browser-run.txt)"
    exit 1
fi

echo "--- Phase 2: Verifying the composition arc ---"

# 1. The desktop menu came from the manifest (11 entries, FILE.BIN included),
#    not the hardcoded fallback (claim 8877 + B4).
# Expectation revised to OBSERVED BYTES (2026-09-01, claim 5251): the
# serial marker reads `desktop: manifest apps=19` — image/apps.txt grew
# from 9 entries at M13 close (d62c933) through M15 C4's SETTINGS.BIN
# (6c8b5b3), M23 E1's EDIT.BIN (ee3da3e), M27 G6's SYSMON.BIN, the M30/M31
# ELF rows, and M32's ZC.BIN. `#` comments are skipped by parse_manifest.
grep -q "desktop: manifest apps=19" "$SER" || {
    echo "ERROR: desktop manifest marker (apps=19) missing from serial log"
    exit 1
}
echo "DESKTOP.MANIFEST: OK"

# 2. The desktop launched FILE.BIN through the EL0 exec seam (claim 6359).
grep -q "desktop: launch FILE.BIN" "$SER" || {
    echo "ERROR: desktop launch FILE.BIN marker missing from serial log"
    exit 1
}
echo "DESKTOP.LAUNCH: OK"
grep -q "28 sys_exec calls=1" "$SER" || {
    echo "ERROR: sys_exec call count missing from syscalls report"
    exit 1
}
echo "SYS_EXEC: OK"

# 3. FILE.BIN opened its window and browsed /data (claim 4742).
grep -q "file: ready" "$SER" || {
    echo "ERROR: FILE.BIN ready marker missing from serial log"
    exit 1
}
echo "FILE.READY: OK"
grep -q "file: listing 2 entries" "$SER" || {
    echo "ERROR: FILE.BIN listing marker (2 entries) missing from serial log"
    exit 1
}
echo "FILE.LIST: OK"
# Expectation revised to OBSERVED BYTES (2026-09-01, claim 1732):
# calls=2 — the main listing PLUS one recursive dir_list per level from
# F4's bounded du total (claim 2539, depth ≤ 3; /data has no subdirs at
# depth 1, so exactly one extra walk).
grep -q "27 sys_dir_list calls=2" "$SER" || {
    echo "ERROR: sys_dir_list call count (calls=2) missing from syscalls report"
    exit 1
}
echo "SYS_DIR_LIST: OK"

# 4. The second Enter opened the SELECTED entry read-only (the browse
#    arc). Expectation revised to OBSERVED BYTES (2026-08-24, claim 2259):
#    `file: open DATA.TXT` / `file: view DATA.TXT` — PR #512's sorted
#    listing (658bd86, 2026-08-23) put DATA.TXT at selection index 0.
grep -q "file: open DATA.TXT" "$SER" || {
    echo "ERROR: FILE.BIN open marker missing from serial log"
    exit 1
}
echo "FILE.OPEN: OK"
grep -q "file: view DATA.TXT" "$SER" || {
    echo "ERROR: FILE.BIN view marker missing from serial log"
    exit 1
}
echo "FILE.VIEW: OK"

# 5. File seam accounting — OBSERVED BYTES (2026-09-01, claim 1732):
#    calls=6 today (was 3 at the 2026-08-24 revision):
#      desktop host-manifest open /host/APPS.TXT — fails, still counts
#        (M34 HF4 issue #738 host-first manifest, claim 7599)
#      desktop /esp/APPS.TXT manifest open
#      FILE.BIN startup recent-ring load /data/RECENT.SAV — absent, still
#        counts (M25 F5, claim 2539)
#      FILE.BIN C7 inline preview open (DATA.TXT)
#      FILE.BIN view open (DATA.TXT)
#      FILE.BIN recent-ring save /data/RECENT.SAV (M25 F5, claim 2539)
#    file_read stays calls=3 (the two opens that failed/saved never read).
grep -q "23 sys_file_open calls=6" "$SER" || {
    echo "ERROR: sys_file_open call count (calls=6) missing from syscalls report"
    exit 1
}
echo "SYS_FILE_OPEN: OK"
grep -q "24 sys_file_read calls=3" "$SER" || {
    echo "ERROR: sys_file_read call count (calls=3) missing from syscalls report"
    exit 1
}
echo "SYS_FILE_READ: OK"

# 6. Clean sweep marker.
grep -q "done-file-sweep" "$SER" || {
    echo "ERROR: final sweep marker missing from serial log"
    exit 1
}

cat > "$REPORT" <<EOF
=== Milestone 13 B4 Desktop Composition Live Gate Report ===
Revision: $REVISION ($BRANCH)
Status: PASS (1/1 on Apple Virtualization.framework)

Verified Components:
- DESKTOP.BIN: manifest-driven launcher (19 apps incl FILE.BIN, claim 8877)
- sys_exec (ADR 0007 slot 28): DESKTOP launches FILE.BIN from EL0
- FILE.BIN: lists /data and opens the selected entry (DATA.TXT) read-only (claim 4742)
- sys_dir_list (slot 27) / sys_file_open+read (slots 23/24)

Serial Output Highlights:
$(grep -E 'desktop:|file:|sys_(exec|dir_list|file_open|file_read)' "$SER" || true)
EOF

echo "verify-live-file-browser: PASS — DESKTOP.BIN launches FILE.BIN from the manifest menu and it browses /data on VZ."
