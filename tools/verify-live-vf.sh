#!/usr/bin/env bash
#
# verify-live-vf.sh -- M34 HF1+HF2+HF3 (issues #735/#736/#737) class-B gate:
# the HOST FILE CHANNEL over custom-virtio queue 5 on real VZ.
#
#   Phase 1 (HF1): the guest's VF_PROBE spike proves the ONE unproven
#   transport fact — a full 32,768-byte device-WRITE reply. Serial shows
#   `vf: probe 32k ok len=0x8000 cksum=0x0000 free=32` (the XOR-symmetric
#   pattern genuinely folds to 0x0000; the guest Zig, Swift, and python
#   all agree); the runner prints `VF-PROBE: wrote 32768/32768 bytes`.
#
#   Phase 2 (HF2): the guest lists the share and streams a >32 KiB fixture
#   byte-exactly across >= 2 READ round trips — `vf cat` prints the STAT
#   byte count FIRST, then `vf: cat ok bytes=N rts>=2 cksum=0x<…>` where
#   the checksum (RFC-1071 over the stream) must equal the gate's python
#   computation over the same fixture. LIST + STAT + READ all exercised; a
#   subdirectory proves /-paths.
#
#   Phase 3 (HF3 — issue #737): MUTATION, one phase per boot:
#     boot 1 "mutate":  vf mkdir hf3 → open hf3/new.bin (create) → write
#       100,000 probe-pattern bytes in 4 chunk round trips → fsync →
#       close → rename hf3/new.bin → hf3/renamed.bin → open APPEND →
#       write 4 bytes → fsync → close. The gate then byte-compares
#       renamed.bin ON THE HOST DISK against the same pattern stream the
#       guest wrote (write + rename + append round-trips verified).
#     boot 2 "read-back": `vf cat hf3/renamed.bin` — proves the FSYNC'd
#       write survives a REBOOT (size + checksum needles, >= 2 READ round
#       trips); python re-verifies the host disk bytes.
#     boot 3 "delete": `vf rm hf3/renamed.bin` + a mkdir-exists honest
#       error; python verifies the file is GONE and the hf3 dir survived.
#   Every boot repeats phases 1+2, so a 3-boot run covers everything.
#
# Run isolation per claim 5069 (tools/lib/gate-run.sh): the share dir
# lives inside the private RUN_DIR, so parallel gate instances cannot
# collide on fixtures.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source tools/lib/gate-run.sh

SUFFIX="${VIRELAI_GATE_SUFFIX:-}"
art() { printf 'artifacts/%s%s' "$1" "$SUFFIX"; }

GATE_LOG="$(art m34-hf1-hf2-hf3-live.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

BOOTS="${BOOTS:-3}"
REPORT="$(art live-vf-report.txt)"
STATIC_EXIT_LINE="tasks user-el0 exited status=7"
PROBE_OK_LINE="vf: probe 32k ok len=0x8000 cksum=0x0000 free=0020"

echo "=== verify-live-vf: M34 HF1+HF2+HF3 (issues #735/#736/#737) — host file channel on VZ, $BOOTS boot(s) ==="
zig version
swift --version 2>&1 | head -1
sw_vers
REVISION="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
DIRTY="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
echo "revision: $REVISION branch=$BRANCH boots=$BOOTS dirty-files=$DIRTY"

zig fmt --check boot/src/*.zig kernel/src/*.zig build.zig
zig build
zig build image
# The custom-virtio device is a SPIKE build type (macOS 27 SDK types) —
# same as the chrome/snapshot gates.
swift build --package-path host/vm-runner --configuration release -Xswiftc -DSPIKE
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner

gate_begin live-vf
echo "run dir: $RUN_DIR"

# --- the host share: deterministic fixtures + the FULL HF3 expectation ---
SHARE="$RUN_DIR/share"
mkdir -p "$SHARE/sub"
python3 - "$SHARE" <<'EOF'
import sys
share = sys.argv[1]
def cksum(data):
    s = 0
    i = 0
    while i + 1 < len(data):
        s += (data[i] << 8) | data[i + 1]
        i += 2
    if i < len(data):
        s += data[i] << 8
    while s >> 16:
        s = (s & 0xffff) + (s >> 16)
    return (~s) & 0xffff
def pattern(i):
    return (i & 0xff) ^ ((i >> 8) & 0xff)
# big.bin: 100,000 deterministic bytes (spans >= 4 READ round trips of
# 32,765 data bytes each). hello.txt: small, read via /-path.
data = bytes((i * 37 + 11) & 0xff for i in range(100000))
open(share + "/big.bin", "wb").write(data)
hello = b"hello vf!\n"
open(share + "/sub/hello.txt", "wb").write(hello)
# HF3 expectation: the guest writes pattern(0..100000) then appends
# pattern(0..4) through an append handle — the host disk must match these
# exact bytes after RENAME, and they must survive a reboot (FSYNC).
expect = bytes(pattern(i) for i in range(100000)) + bytes(pattern(i) for i in range(4))
open(share + "/hf3-expect.bin", "wb").write(expect)
print("BIG_SIZE=%d" % len(data))
print("BIG_CKSUM=0x%04x" % cksum(data))
print("HELLO_CKSUM=0x%04x" % cksum(hello))
print("HF3_SIZE=%d" % len(expect))
print("HF3_CKSUM=0x%04x" % cksum(expect))
EOF
BIG_SIZE="$(grep '^BIG_SIZE=' "$GATE_LOG" | tail -1 | cut -d= -f2)"
BIG_CKSUM="$(grep '^BIG_CKSUM=' "$GATE_LOG" | tail -1 | cut -d= -f2)"
HELLO_CKSUM="$(grep '^HELLO_CKSUM=' "$GATE_LOG" | tail -1 | cut -d= -f2)"
HF3_SIZE="$(grep '^HF3_SIZE=' "$GATE_LOG" | tail -1 | cut -d= -f2)"
HF3_CKSUM="$(grep '^HF3_CKSUM=' "$GATE_LOG" | tail -1 | cut -d= -f2)"
echo "share: big.bin size=$BIG_SIZE cksum=$BIG_CKSUM ; sub/hello.txt cksum=$HELLO_CKSUM ; hf3 expect size=$HF3_SIZE cksum=$HF3_CKSUM"

# Host-disk verification (HF3): the mutation round-trip MUST land the exact
# guest pattern stream on the host's own filesystem.
verify_hf3_disk() {
    local phase="$1"
    python3 - "$SHARE" "$phase" <<'EOF'
import os, sys
share, phase = sys.argv[1], sys.argv[2]
def pattern(i):
    return (i & 0xff) ^ ((i >> 8) & 0xff)
expect = bytes(pattern(i) for i in range(100000)) + bytes(pattern(i) for i in range(4))
rp = os.path.join(share, "hf3", "renamed.bin")
nb = os.path.join(share, "hf3", "new.bin")
hd = os.path.join(share, "hf3")
ok = True
if phase in ("mutate", "readback"):
    if not os.path.exists(rp):
        print("HF3-DISK: FAIL — renamed.bin missing after %s" % phase); ok = False
    else:
        got = open(rp, "rb").read()
        if got != expect:
            print("HF3-DISK: FAIL — renamed.bin %d bytes != expected %d after %s" % (len(got), len(expect), phase)); ok = False
        else:
            print("HF3-DISK: renamed.bin %d bytes MATCH the guest pattern stream (%s)" % (len(got), phase))
    if os.path.exists(nb):
        print("HF3-DISK: FAIL — new.bin still present after RENAME"); ok = False
elif phase == "delete":
    if os.path.exists(rp):
        print("HF3-DISK: FAIL — renamed.bin still present after DELETE"); ok = False
    else:
        print("HF3-DISK: renamed.bin gone after DELETE")
    if not os.path.isdir(hd):
        print("HF3-DISK: FAIL — hf3 dir missing after DELETE"); ok = False
    else:
        print("HF3-DISK: hf3 dir survived DELETE")
sys.exit(0 if ok else 1)
EOF
}

# --- per-phase guest scripts ---
SCRIPT_H12="$RUN_DIR/script-h12.txt"
printf 'vf ls\nvf cat big.bin\nvf ls sub\nvf cat sub/hello.txt\n' > "$SCRIPT_H12"

SCRIPT_MUTATE="$RUN_DIR/script-mutate.txt"
cat > "$SCRIPT_MUTATE" <<'EOF'
vf mkdir hf3
vf open hf3/new.bin
vf write 0 100000
vf fsync 0
vf mv hf3/new.bin hf3/renamed.bin
vf open hf3/renamed.bin append
vf write 1 4
vf fsync 1
vf close 1
vf close 0
echo rx-vf3-mutate
EOF

SCRIPT_READBACK="$RUN_DIR/script-readback.txt"
printf 'vf cat hf3/renamed.bin\necho rx-vf3-readback\n' > "$SCRIPT_READBACK"

SCRIPT_DELETE="$RUN_DIR/script-delete.txt"
printf 'vf rm hf3/renamed.bin\nvf mkdir hf3\necho rx-vf3-delete\n' > "$SCRIPT_DELETE"

PHASES=(mutate readback delete)
phase_of() { local t=$((10#$1)); echo "${PHASES[$(( (t - 1) % ${#PHASES[@]} ))]}"; }
cat_script_of() {
    local p="$1"
    # The combined file MUST NOT alias any SCRIPT_* source (a self-append
    # like `cat f >> f` grows/hangs forever — observed live: boot 1 stuck
    # on `cat script-mutate.txt >> script-mutate.txt`).
    local out="$RUN_DIR/script-$p-combined.txt"
    cat "$SCRIPT_H12" > "$out"
    case "$p" in
        mutate)   cat "$SCRIPT_MUTATE" >> "$out" ;;
        readback) cat "$SCRIPT_READBACK" >> "$out" ;;
        delete)   cat "$SCRIPT_DELETE" >> "$out" ;;
    esac
    echo "$out"
}

run_one() {
    local tag="$1"
    local phase; phase="$(phase_of "$tag")"
    local script; script="$(cat_script_of "$phase")"
    local run_log="$(art live-vf-run-$tag.txt)"
    local serial_copy="$(art live-vf-serial-$tag.log)"
    rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial-$tag.log"

    set +e
    host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
        --cvc-file "$SHARE" \
        --serial "$RUN_DIR/vm-serial-$tag.log" \
        --script "$script" --script-after "$STATIC_EXIT_LINE" \
        --timeout 90 > "$run_log" 2>&1
    local rc=$?
    set -e
    [ -f "$RUN_DIR/vm-serial-$tag.log" ] && cp "$RUN_DIR/vm-serial-$tag.log" "$serial_copy" || true
    local SER="$serial_copy"

    local bytes=0 banner=0 probe=0 listed=0 statline=0 catok=0 catcksum=0 sub=0 hello=0 runner_write=0 fatal=0
    if [ -f "$SER" ]; then
        bytes="$(wc -c < "$SER" | tr -d ' ')"
        [ "$(grep -aFxc -- "VirelaiOS kernel has seized control." "$SER" || true)" = 1 ] && banner=1
        [ "$(grep -aFxc -- "$PROBE_OK_LINE" "$SER" || true)" = 1 ] && probe=1
        [ "$(grep -aFc -- "big.bin" "$SER" || true)" -ge 2 ] && listed=1
        [ "$(grep -aFxc -- "vf: cat big.bin size=$BIG_SIZE" "$SER" || true)" = 1 ] && statline=1
        [ "$(grep -aFc -- "vf: cat ok bytes=$BIG_SIZE rts=" "$SER" || true)" -ge 1 ] && catok=1
        [ "$(grep -aFc -- "cksum=$BIG_CKSUM" "$SER" || true)" -ge 1 ] && catcksum=1
        [ "$(grep -aFc -- "sub/" "$SER" || true)" -ge 1 ] && sub=1
        [ "$(grep -aFc -- "vf: cat ok bytes=10 rts=1 cksum=$HELLO_CKSUM" "$SER" || true)" -ge 1 ] && hello=1
        grep -qF -- "vf: probe 32k FAILED" "$SER" && fatal=1 || true
    fi
    [ "$(grep -aFc -- "VF-PROBE: wrote 32768/32768 bytes (write buffers 32768)" "$run_log" || true)" -ge 1 ] && runner_write=1
    grep -qF -- "VF-PROBE: FAILED" "$run_log" && fatal=1 || true
    # At least 2 READ round trips for the >32 KiB fixture (32765 B max/round trip).
    local rts=0
    if [ -f "$SER" ]; then
        rts="$(grep -aF -- "vf: cat ok bytes=$BIG_SIZE rts=" "$SER" | head -1 | sed -E 's/.*rts=([0-9]+).*/\1/')"
        [ -n "$rts" ] && [ "$rts" -ge 2 ] || rts=0
    fi

    # --- HF3 phase needles + host-disk verification ---
    local phase_needs=1 hf3_disk=0
    case "$phase" in
        mutate)
            [ "$(grep -aFxc -- "vf: open hf3/new.bin h=0" "$SER" || true)" = 1 ] || phase_needs=0
            [ "$(grep -aFxc -- "vf: write 0 n=100000 wrote=100000 chunks=4" "$SER" || true)" = 1 ] || phase_needs=0
            [ "$(grep -aFxc -- "vf: fsync 0 ok" "$SER" || true)" = 1 ] || phase_needs=0
            [ "$(grep -aFxc -- "vf: mv hf3/new.bin -> hf3/renamed.bin ok" "$SER" || true)" = 1 ] || phase_needs=0
            [ "$(grep -aFxc -- "vf: open hf3/renamed.bin append h=1" "$SER" || true)" = 1 ] || phase_needs=0
            [ "$(grep -aFxc -- "vf: write 1 n=4 wrote=4 chunks=1" "$SER" || true)" = 1 ] || phase_needs=0
            [ "$(grep -aFxc -- "vf: fsync 1 ok" "$SER" || true)" = 1 ] || phase_needs=0
            [ "$(grep -aFxc -- "vf: close 1 ok" "$SER" || true)" = 1 ] || phase_needs=0
            [ "$(grep -aFxc -- "vf: close 0 ok" "$SER" || true)" = 1 ] || phase_needs=0
            [ "$(grep -aFxc -- "rx-vf3-mutate" "$SER" || true)" = 1 ] || phase_needs=0
            [ "$(grep -aFc -- "VF-FILE: RENAME hf3/new.bin" "$run_log" || true)" -ge 1 ] || phase_needs=0
            [ "$(grep -aFc -- "VF-FILE: OPEN hf3/" "$run_log" || true)" -ge 2 ] || phase_needs=0
            [ "$(grep -aFc -- "VF-FILE: WRITE h=" "$run_log" || true)" -ge 5 ] || phase_needs=0
            ;;
        readback)
            [ "$(grep -aFxc -- "vf: cat hf3/renamed.bin size=$HF3_SIZE" "$SER" || true)" = 1 ] || phase_needs=0
            [ "$(grep -aFc -- "vf: cat ok bytes=$HF3_SIZE rts=" "$SER" || true)" -ge 1 ] || phase_needs=0
            [ "$(grep -aFc -- "cksum=$HF3_CKSUM" "$SER" || true)" -ge 1 ] || phase_needs=0
            [ "$(grep -aFxc -- "rx-vf3-readback" "$SER" || true)" = 1 ] || phase_needs=0
            ;;
        delete)
            [ "$(grep -aFxc -- "vf: rm hf3/renamed.bin ok" "$SER" || true)" = 1 ] || phase_needs=0
            [ "$(grep -aFc -- "already exists on the host share" "$SER" || true)" -ge 1 ] || phase_needs=0
            [ "$(grep -aFxc -- "rx-vf3-delete" "$SER" || true)" = 1 ] || phase_needs=0
            [ "$(grep -aFc -- "VF-FILE: DELETE hf3/renamed.bin" "$run_log" || true)" -ge 1 ] || phase_needs=0
            ;;
    esac
    if verify_hf3_disk "$phase"; then
        hf3_disk=1
    fi

    echo "$tag(phase=$phase): runner-rc=$rc serial-bytes=$bytes banner=$banner probe=$probe listed=$listed statline=$statline catok=$catok catcksum=$catcksum rts=$rts sub=$sub hello=$hello runner-write=$runner_write phase=$phase_needs hf3-disk=$hf3_disk fatal=$fatal" | tee -a "$REPORT"
    [ "$rc" = 0 ] && [ "$banner" = 1 ] && [ "$probe" = 1 ] && [ "$listed" = 1 ] && \
        [ "$statline" = 1 ] && [ "$catok" = 1 ] && [ "$catcksum" = 1 ] && [ "$rts" -ge 2 ] && \
        [ "$sub" = 1 ] && [ "$hello" = 1 ] && [ "$runner_write" = 1 ] && \
        [ "$phase_needs" = 1 ] && [ "$hf3_disk" = 1 ] && [ "$fatal" = 0 ]
}

: > "$REPORT"
{
    echo "VIRELAIOS live host-file-channel gate (M34 HF1+HF2+HF3, issues #735/#736/#737)"
    echo "revision: $REVISION branch=$BRANCH boots=$BOOTS dirty-files=$DIRTY"
    echo "date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo
} >> "$REPORT"

pass=0
n=0
for tag in $(seq -w 1 "$BOOTS"); do
    n=$((n + 1))
    if run_one "$tag"; then
        pass=$((pass + 1))
    fi
done

echo
echo "=== result ==="
if [ "$pass" = "$n" ]; then
    echo "verify-live-vf: PASS — VF_PROBE 32 KiB spike + vf ls/cat + HF3 mutation round-trips verified HOST-SIDE ($pass/$n boot(s)); see $REPORT and $GATE_LOG"
    exit 0
else
    echo "verify-live-vf: FAILED — $pass/$n boot(s) passed; see $REPORT and per-boot logs."
    exit 1
fi