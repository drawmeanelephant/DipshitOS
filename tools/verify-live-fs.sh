#!/usr/bin/env bash
#
# verify-live-fs.sh -- M34 HF6 (issue #740) class-B gate: the guest
# filesystem surface (write/ls/cat + the /-path directory surface) over
# the HOST SHARE, with persistence through reboot on the real macOS disk.
#
# Claim 6420's FAT driver is gone (HF6 deleted fat.zig + the post-exit
# virtio-blk path): the ESP is firmware-only, parsed pre-exit. The guest
# storage surface is the queue-5 host file channel (--cvc-file share); the
# legacy monitor commands `write`/`ls`/`cat` now route there, so the
# historical claim-6420 proof shape — write + list + read, then reboot and
# prove the file is STILL THERE — is re-observed end to end on the host
# share instead of the FAT volume.
#
# Mechanism: gate_begin attaches the ONE shared read-only boot image
# (--overlay-base; the loader's evidence writes land in a throwaway ASIF
# overlay). The share is a REAL macOS directory: gate_arm_share creates a
# per-gate share dir; the guest writes into it through the channel, and
# both boots attach the SAME dir — so a file written in boot A is read
# back from the host filesystem in boot B. The gate additionally verifies
# hello.txt ON THE HOST DISK after run B.
#
# The gate is TWO boots against the SAME share:
#   run A (fresh share, seeded fixtures): script `write hello.txt hello
#         world` + `ls` + `cat hello.txt` + `ls sub` + `cat sub/big.txt`;
#         asserts the write-ok reply (persisted N bytes to the host
#         share), the share listing (hello.txt listed as a real [host]
#         file), the cat reply, the /-path directory surface (the
#         milestone-four card 2 shape, re-pointed: `ls sub` lists the
#         seeded subdirectory; `cat sub/big.txt` reports the honest
#         direct-read cap for a > 32 KiB... > 2 KiB file).
#   run B (same share): script `ls` + `cat hello.txt`; asserts hello.txt
#         still listed from the share and cat still prints the content —
#         the write persisted across the reboot ON THE MACOS DISK.
#
# Honesty: the runner exits 0 only when the expected reply appears; the
# gate additionally asserts the full transcript (write reply, ls listing
# lines, cat reply), so an early exit on the echoed input line cannot pass.
#
# Per run this reports: rc, serial-bytes, and per-assertion flags.
# Run isolation (tools/lib/gate-run.sh, issue #740): every pair of boots
# shares the read-only boot image; the SAME private share dir (a real host
# folder, not a per-boot overlay) provides the persistence medium. Two
# concurrent instances cannot clobber each other. Set
# VIRELAI_GATE_SUFFIX=_alt for distinct canonical evidence names; set
# VIRELAI_KEEP_RUN=1 to keep the scratch dir.
#
# Class B — Apple silicon + VZ only; boots real VMs. A green CI badge
# proves class A only and says nothing about this gate.
#
# Usage:
#   bash tools/verify-live-fs.sh            # one A/B pair (2 boots)
#   BOOTS=2 bash tools/verify-live-fs.sh    # two A/B pairs
#
# Evidence saved under artifacts/: live-fs-gate.txt (full output),
# live-fs-report.txt (per-run detail), live-fs-run-<A|B>-<NN>.txt (runner
# output), live-fs-serial-<A|B>-<NN>.log (vm-serial.log copies).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source tools/lib/gate-run.sh

SUFFIX="${VIRELAI_GATE_SUFFIX:-}"
art() { printf 'artifacts/%s%s' "$1" "$SUFFIX"; }

GATE_LOG="$(art live-fs-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

PAIRS="${BOOTS:-1}"
REPORT="$(art live-fs-report.txt)"

echo "=== verify-live-fs: M34 HF6 — host-share storage (write/ls/cat persist through reboot on the macOS disk), $PAIRS pair(s) of boots ==="

# --- per-run isolation -------------------------------------------------------
gate_begin live-fs
echo "run dir: $RUN_DIR"

# --- tool versions + revision -----------------------------------------------
zig version; swift --version 2>&1 | head -1; sw_vers
REVISION="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
DIRTY="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
echo "revision: $REVISION branch=$BRANCH pairs=$PAIRS dirty-files=$DIRTY"

# --- build gates ------------------------------------------------------------
zig fmt --check boot/src/*.zig kernel/src/*.zig build.zig
zig build
zig build image
# The --cvc-file FILE channel requires the SPIKE runner build.
swift build --package-path host/vm-runner --configuration release -Xswiftc -DSPIKE
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner

# --- the host share: seeded fixtures + the persistence medium --------------
# gate_arm_share creates $RUN_DIR/share and arms --cvc-file. The fixtures:
#   sub/hello.txt  — the /-path directory surface (ls sub lists it)
#   sub/big.txt    — 4,000 bytes > the 2,048-byte bounded cat buffer, so
#                    `cat sub/big.txt` honestly reports the direct-read cap
#                    (the BOOTAA64.EFI cap check's modern /-path shape).
gate_arm_share
mkdir -p "$SHARE/sub"
mkdir -p "$SHARE/sub/deeper"
echo "hello from the seeded share" > "$SHARE/sub/hello.txt"
python3 - "$SHARE" <<'EOF'
import sys
share = sys.argv[1]
open(share + "/sub/big.txt", "wb").write(bytes((i * 7 + 3) & 0xff for i in range(4000)))
open(share + "/sub/deeper/nested.txt", "w").write("nested level 2\n")
print("fixtures: sub/hello.txt + sub/big.txt (4000 bytes) + sub/deeper/nested.txt")
EOF

# --- scripted keystrokes -----------------------------------------------------
# Run A ends on the honest direct-read-cap ERROR (`cat sub/big.txt`), which
# paints the red prompt; run B ends on the successful `cat hello.txt`
# (green prompt). `version` gives the guest two more shell cycles after the
# final reply so the runner exit lands at idle.
cat > "$RUN_DIR/script-A.txt" <<'EOF'
write hello.txt hello world
ls
cat hello.txt
ls sub
cat sub/big.txt
version
EOF
cat > "$RUN_DIR/script-B.txt" <<'EOF'
ls
cat hello.txt
version
EOF

# --- per-run gate ------------------------------------------------------------
# $1 = tag, $2 = script file, $3 = expect substring, $4 = fresh nvram (1|0).
run_one() {
    local tag="$1" script="$2" expect="$3" fresh="$4"
    if [ "$fresh" = 1 ]; then
        rm -f "$RUN_DIR/efi-vars.bin"
    fi
    rm -f "$RUN_DIR/vm-serial-$tag.log"
    set +e
    host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
        --serial "$RUN_DIR/vm-serial-$tag.log" \
        --script "$script" --script-expect "$expect" --timeout 40 \
        > "$(art live-fs-run-$tag.txt)" 2>&1
    local RC=$?
    set -e
    [ -f "$RUN_DIR/vm-serial-$tag.log" ] && cp "$RUN_DIR/vm-serial-$tag.log" "$(art live-fs-serial-$tag.log)" || true
    local SER="$(art live-fs-serial-$tag.log)"

    local SERIAL_BYTES=0
    local WRITEOK=0 FILELISTED=0 CATREPLY=0 WINDOW=0 LSHEAD=0 SUBDIRLS=0 SUBDIRCAT=0
    if [ -f "$SER" ]; then
        SERIAL_BYTES=$(wc -c < "$SER" | tr -d ' ')
        # The write-ok reply: "write: ok (persisted 11 bytes to the host share)".
        grep -a -qF -- "write: ok (persisted" "$SER" && WRITEOK=1
        # The share listing header (count in 16-hex form).
        grep -a -qF -- "ls: host=0x" "$SER" && LSHEAD=1
        # The persistence proof: hello.txt LISTED in the ls output as a real
        # [host] share file. The share preserves the guest's casing
        # (hello.txt stays lowercase — no FAT 8.3 uppercasing).
        grep -a -qF -- "  hello.txt" "$SER" && FILELISTED=1
        # The /-path directory surface: `ls sub` lists the seeded files.
        grep -a -qF -- "ls: sub entries=0x" "$SER" && grep -a -qF -- "  hello.txt" "$SER" && SUBDIRLS=1
        # The honest direct-read cap for a > 2 KiB file (the old
        # BOOTAA64.EFI cap check, re-pointed to a share fixture).
        grep -a -qF -- "direct read caps at 0x0000000000000800" "$SER" && SUBDIRCAT=1
        # The cat reply.
        grep -a -qF -- "hello world" "$SER" && CATREPLY=1
        # The boot-time window line proves the channel was armed.
        grep -a -qF -- "host share: armed" "$SER" && WINDOW=1
    fi
    local PASS=0
    if [ "$RC" = 0 ] && [ "$WINDOW" = 1 ] && [ "$LSHEAD" = 1 ] && [ "$FILELISTED" = 1 ] && [ "$CATREPLY" = 1 ]; then
        PASS=1
    fi
    if [ "$tag" = "A" ] && { [ "$WRITEOK" != 1 ] || [ "$SUBDIRLS" != 1 ] || [ "$SUBDIRCAT" != 1 ]; }; then
        PASS=0
    fi
    {
        echo "$tag: rc=$RC serial-bytes=$SERIAL_BYTES write-ok=$WRITEOK file-listed=$FILELISTED cat-reply=$CATREPLY window-line=$WINDOW ls-header=$LSHEAD subdir-ls=$SUBDIRLS subdir-cat=$SUBDIRCAT pass=$PASS"
    } >> "$REPORT"
    echo "$tag rc=$RC serial-bytes=$SERIAL_BYTES write-ok=$WRITEOK file-listed=$FILELISTED cat-reply=$CATREPLY window-line=$WINDOW ls-header=$LSHEAD subdir-ls=$SUBDIRLS subdir-cat=$SUBDIRCAT pass=$PASS"
    [ "$PASS" = 1 ]
}

: > "$REPORT"
{
    echo "VIRELAIOS live host-share storage gate (M34 HF6, issue #740) — write/ls/cat persist through reboot on the macOS share (VZ hardware)"
    echo "revision: $REVISION branch=$BRANCH pairs=$PAIRS dirty-files=$DIRTY"
    echo "run A: write hello.txt 'hello world' + ls + cat + ls sub + cat sub/big.txt (fresh share)"
    echo "run B: ls + cat hello.txt (SAME share — persistence through reboot on the host disk)"
    echo "date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo
} >> "$REPORT"

PASS=0
n=0
while [ "$n" -lt "$PAIRS" ]; do
    n=$((n + 1))
    echo
    echo "=== live-fs pair $n, run A (write/ls/cat, fresh share) ==="
    AOK=0
    # Run A ends on the direct-read-cap ERROR reply (red prompt).
    run_one "A-$n" "$RUN_DIR/script-A.txt" $'direct read caps at 0x0000000000000800 bytes\n\x1b[31mvirelai> ' 1 && AOK=1 || true
    echo "=== live-fs pair $n, run B (persistence through reboot, same share) ==="
    BOK=0
    sleep 3
    run_one "B-$n" "$RUN_DIR/script-B.txt" $'hello world\n\x1b[32mvirelai> ' 0 && BOK=1 || true
    if [ "$AOK" = 1 ] && [ "$BOK" = 1 ]; then
        PASS=$((PASS + 1))
    fi
done

# M34 HF6 (issue #740): prove the write landed ON THE HOST DISK — the
# share is the persistence home; run B's listing is the guest-side proof,
# this is the host-side ground truth.
HOST_DISK_OK=0
if [ -f "$SHARE/hello.txt" ] && [ "$(cat "$SHARE/hello.txt" 2>/dev/null || true)" = "hello world" ]; then
    HOST_DISK_OK=1
    echo "HF6-DISK: hello.txt on the host share still carries 'hello world' after run B"
else
    echo "HF6-DISK: FAIL — hello.txt missing/incomplete on the host share"
fi
[ "$HOST_DISK_OK" != 1 ] && PASS=0  # a persistence gate CANNOT pass on guest-side claims alone

echo
echo "=== result ==="
if [ "$PASS" = "$PAIRS" ]; then
    echo "verify-live-fs: PASS — write/ls/cat persist through reboot on the host share (M34 HF6): run A persisted 'hello world' to the share (write-ok, hello.txt [host] in ls, cat reply, /-path sub listing + honest direct-read cap); run B — a fresh boot against the same share — still lists and prints the file from the macOS disk; the host-disk check confirms the bytes ($PASS/$PAIRS pair(s))."
    echo "PASS: $PASS/$PAIRS" >> "$REPORT"
    sleep 0.5
else
    echo "verify-live-fs: FAIL — $PASS/$PAIRS pair(s) passed (see $REPORT and the run/serial artifacts)."
    echo "FAIL: $PASS/$PAIRS" >> "$REPORT"
    exit 1
fi