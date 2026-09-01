#!/usr/bin/env bash
#
# verify-live-gfs.sh -- M34 HF6 (issue #740) class-B gate: the GENERAL
# filesystem surface observed on real VZ hardware. The old claim-3678 DATA
# partition is GONE (HF6 deleted the second FAT volume + the guest FAT
# driver); the general (non-boot) store is now the macOS host share — the
# `mount` command reports it, `ls`/`cat`/`write` route to it, and a file
# written in boot A persists in the host folder through boot B.
#
# The gate is TWO boots against the SAME share:
#   run A (fresh share with seeded fixtures): script `mount` + `write
#         hello.txt hello world` + `ls` + `cat README.TXT` + `cat DATA.TXT`;
#         asserts the mount reply (mount: host share armed files=N), the
#         share listing (README.TXT / DATA.TXT, labeled [host]), the
#         DATA.TXT cat reply, and the write-ok reply.
#   run B (same share): script `mount` + `ls` + `cat hello.txt`;
#         asserts the share still lists hello.txt and cat prints the
#         content — the general store persisted across the reboot ON THE
#         HOST DISK.
#
# Per run this reports: rc, serial-bytes, and per-assertion flags.
# Run isolation (tools/lib/gate-run.sh, issue #740): every pair of boots
# shares the read-only boot image (--overlay-base) and a PRIVATE share dir
# (a real host folder, present across both boots — the persistence
# medium). VIRELAI_GATE_SUFFIX=_alt gives distinct canonical evidence
# names; VIRELAI_KEEP_RUN=1 keeps the scratch dir.
#
# Class B — Apple silicon + VZ only; boots real VMs.
#
# Usage:
#   bash tools/verify-live-gfs.sh
#
# Evidence saved under artifacts/: live-gfs-gate.txt, live-gfs-report.txt,
# live-gfs-run-<A|B>-<NN>.txt, live-gfs-serial-<A|B>-<NN>.log.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source tools/lib/gate-run.sh

SUFFIX="${VIRELAI_GATE_SUFFIX:-}"
art() { printf 'artifacts/%s%s' "$1" "$SUFFIX"; }

GATE_LOG="$(art live-gfs-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

PAIRS="${BOOTS:-1}"
REPORT="$(art live-gfs-report.txt)"

echo "=== verify-live-gfs: M34 HF6 — general filesystem: the host share as the non-boot store, mount + persistence on VZ, $PAIRS pair(s) of boots ==="

# --- per-run isolation -------------------------------------------------------
gate_begin live-gfs
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
# gate_arm_share creates $RUN_DIR/share and arms --cvc-file. The fixtures
# mirror the OLD data partition's contents (README.TXT / DATA.TXT) so the
# listing/cat needles survive the re-point.
gate_arm_share
echo "VirelaiOS general store README" > "$SHARE/README.TXT"
echo "general data volume contents" > "$SHARE/DATA.TXT"
echo "fixtures: README.TXT + DATA.TXT seeded on the share root"

# --- scripted keystrokes -----------------------------------------------------
cat > "$RUN_DIR/script-A.txt" <<'EOF'
mount
write hello.txt hello world
ls
cat README.TXT
cat DATA.TXT
EOF
cat > "$RUN_DIR/script-B.txt" <<'EOF'
mount
ls
cat hello.txt
EOF

# --- per-run gate ------------------------------------------------------------
# $1 = tag, $2 = script file, $3 = expect substring, $4 = fresh disk (1|0).
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
        > "$(art live-gfs-run-$tag.txt)" 2>&1
    local RC=$?
    set -e
    [ -f "$RUN_DIR/vm-serial-$tag.log" ] && cp "$RUN_DIR/vm-serial-$tag.log" "$(art live-gfs-serial-$tag.log)" || true
    local SER="$(art live-gfs-serial-$tag.log)"

    local SERIAL_BYTES=0
    local MOUNTOK=0 LSHEAD=0 DATAFILES=0 CATDATA=0 WRITEOK=0 FILELISTED=0 CATHELLO=0
    if [ -f "$SER" ]; then
        SERIAL_BYTES=$(wc -c < "$SER" | tr -d ' ')
        # The mount reply reports the host share as the one general store.
        grep -a -qF -- "mount: host share armed files=0x" "$SER" && MOUNTOK=1
        # The share listing header (count in 16-hex form).
        grep -a -qF -- "ls: host=0x" "$SER" && LSHEAD=1
        # The general store's seeded files are listed (labeled [host]).
        grep -a -qF -- "  README.TXT" "$SER" && DATAFILES=1
        grep -a -qF -- "  DATA.TXT" "$SER" && DATAFILES=1
        grep -a -qF -- "  [host]" "$SER" && DATAFILES=1
        # The DATA.TXT cat reply (volume content, not the ESP's).
        grep -a -qF -- "general data volume contents" "$SER" && CATDATA=1
        # The write reply (hello world -> the share root).
        grep -a -qF -- "write: ok (persisted" "$SER" && WRITEOK=1
        # hello.txt listed after the write (run A: window; run B: from disk).
        grep -a -qi -- "  hello" "$SER" && FILELISTED=1
        # The cat hello.txt reply.
        grep -a -qF -- "hello world" "$SER" && CATHELLO=1
    fi
    local PASS=0
    # Common requirements (both runs): the share mounted/reported, its
    # window labeled [host] with its files listed, hello.txt listed, and the
    # hello-world cat reply. Run A additionally requires the write-ok reply
    # and the DATA.TXT cat; run B's list+cat of hello.txt are the real
    # persistence proof (run A's "hello world" match is the command echo).
    if [ "$RC" = 0 ] && [ "$MOUNTOK" = 1 ] && [ "$LSHEAD" = 1 ] && [ "$DATAFILES" = 1 ] && \
       [ "$FILELISTED" = 1 ] && [ "$CATHELLO" = 1 ]; then
        PASS=1
    fi
    if [ "$tag" = "A" ] && { [ "$WRITEOK" != 1 ] || [ "$CATDATA" != 1 ]; }; then
        PASS=0
    fi
    {
        echo "$tag: rc=$RC serial-bytes=$SERIAL_BYTES mount-ok=$MOUNTOK ls-header=$LSHEAD data-files=$DATAFILES cat-data=$CATDATA write-ok=$WRITEOK file-listed=$FILELISTED cat-hello=$CATHELLO pass=$PASS"
    } >> "$REPORT"
    echo "$tag rc=$RC serial-bytes=$SERIAL_BYTES mount-ok=$MOUNTOK ls-header=$LSHEAD data-files=$DATAFILES cat-data=$CATDATA write-ok=$WRITEOK file-listed=$FILELISTED cat-hello=$CATHELLO pass=$PASS"
    [ "$PASS" = 1 ]
}

: > "$REPORT"
{
    echo "VIRELAIOS live general-filesystem gate (issue #740) — the host share as the general (non-boot) store: mounted, listed, read, written, and persistent across reboot (VZ hardware)"
    echo "revision: $REVISION branch=$BRANCH pairs=$PAIRS dirty-files=$DIRTY"
    echo "run A: mount + write hello.txt 'hello world' + ls + cat README.TXT + cat DATA.TXT (fresh share)"
    echo "run B: mount + ls + cat hello.txt (SAME share — persistence through reboot on the host disk)"
    echo "date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo
} >> "$REPORT"

PASS=0
n=0
while [ "$n" -lt "$PAIRS" ]; do
    n=$((n + 1))
    echo
    echo "=== live-gfs pair $n, run A (mount data / write / list / read, fresh disk) ==="
    AOK=0
    # The expect is the LAST reply (the DATA.TXT cat + next prompt): the
    # runner exits when it appears, so it must be the final script line's
    # reply, not an earlier one.
    # Reply+idle-prompt anchor (colored prompt bytes; see fs gate note):
    # fires only at shell idle after the reply, so the pair's second boot
    # never reads a mid-writeback image.
    run_one "A-$n" "$RUN_DIR/script-A.txt" $'general data volume contents: 1234567890\n\x1b[32mvirelai> ' 1 && AOK=1 || true
    echo "=== live-gfs pair $n, run B (persistence through reboot, same disk) ==="
    BOK=0
    sleep 3
    run_one "B-$n" "$RUN_DIR/script-B.txt" $'hello world\n\x1b[32mvirelai> ' 0 && BOK=1 || true
    if [ "$AOK" = 1 ] && [ "$BOK" = 1 ]; then
        PASS=$((PASS + 1))
    fi
done

echo
echo "=== result ==="
if [ "$PASS" = "$PAIRS" ]; then
    echo "verify-live-gfs: PASS — the host share is mounted/reported as the one general store, its window labeled [host], its files listed and read, hello.txt written to it, and run B — a fresh boot against the same share — still lists and prints the file ($PASS/$PAIRS pair(s))."
    echo "PASS: $PASS/$PAIRS" >> "$REPORT"
    sleep 0.5
    exit 0
else
    echo "verify-live-gfs: FAILED — $PASS/$PAIRS pair(s) passed; see artifacts/live-gfs-report.txt and the per-run runner output/serial logs."
    echo "FAIL: $PASS/$PAIRS" >> "$REPORT"
    sleep 0.5
    exit 1
fi
