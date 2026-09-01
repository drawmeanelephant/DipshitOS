#!/usr/bin/env bash
#
# verify-live-vf.sh -- M34 HF1+HF2 (issues #735/#736) class-B gate: the
# HOST FILE CHANNEL over custom-virtio queue 5 on real VZ.
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
# Run isolation per claim 5069 (tools/lib/gate-run.sh): the share dir
# lives inside the private RUN_DIR, so parallel gate instances cannot
# collide on fixtures.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source tools/lib/gate-run.sh

SUFFIX="${VIRELAI_GATE_SUFFIX:-}"
art() { printf 'artifacts/%s%s' "$1" "$SUFFIX"; }

GATE_LOG="$(art m34-hf1-hf2-live.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

BOOTS="${BOOTS:-1}"
REPORT="$(art live-vf-report.txt)"
STATIC_EXIT_LINE="tasks user-el0 exited status=7"
PROBE_OK_LINE="vf: probe 32k ok len=0x8000 cksum=0x0000 free=0020"

echo "=== verify-live-vf: M34 HF1+HF2 (issues #735/#736) — host file channel on VZ, $BOOTS boot(s) ==="
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

# --- the host share: a deterministic >32 KiB fixture + a subdirectory ---
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
# big.bin: 100,000 deterministic bytes (spans >= 4 READ round trips of
# 32,765 data bytes each). hello.txt: small, read via /-path.
data = bytes((i * 37 + 11) & 0xff for i in range(100000))
open(share + "/big.bin", "wb").write(data)
hello = b"hello vf!\n"
open(share + "/sub/hello.txt", "wb").write(hello)
print("BIG_SIZE=%d" % len(data))
print("BIG_CKSUM=0x%04x" % cksum(data))
print("HELLO_CKSUM=0x%04x" % cksum(hello))
EOF
BIG_SIZE="$(grep '^BIG_SIZE=' "$GATE_LOG" | tail -1 | cut -d= -f2)"
BIG_CKSUM="$(grep '^BIG_CKSUM=' "$GATE_LOG" | tail -1 | cut -d= -f2)"
HELLO_CKSUM="$(grep '^HELLO_CKSUM=' "$GATE_LOG" | tail -1 | cut -d= -f2)"
echo "share: big.bin size=$BIG_SIZE cksum=$BIG_CKSUM ; sub/hello.txt cksum=$HELLO_CKSUM"

SCRIPT="$RUN_DIR/script.txt"
printf 'vf ls\nvf cat big.bin\nvf ls sub\nvf cat sub/hello.txt\necho rx-vf-ok\n' > "$SCRIPT"

run_one() {
    local tag="$1"
    local run_log="$(art live-vf-run-$tag.txt)"
    local serial_copy="$(art live-vf-serial-$tag.log)"
    rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial-$tag.log"

    set +e
    host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
        --cvc-file "$SHARE" \
        --serial "$RUN_DIR/vm-serial-$tag.log" \
        --script "$SCRIPT" --script-after "$STATIC_EXIT_LINE" \
        --timeout 90 > "$run_log" 2>&1
    local rc=$?
    set -e
    [ -f "$RUN_DIR/vm-serial-$tag.log" ] && cp "$RUN_DIR/vm-serial-$tag.log" "$serial_copy" || true
    local SER="$serial_copy"

    local bytes=0 banner=0 probe=0 listed=0 statline=0 catok=0 catcksum=0 sub=0 hello=0 echo_ok=0 runner_write=0 fatal=0
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
        [ "$(grep -aFxc -- "rx-vf-ok" "$SER" || true)" = 1 ] && echo_ok=1
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
    echo "$tag: runner-rc=$rc serial-bytes=$bytes banner=$banner probe=$probe listed=$listed statline=$statline catok=$catok catcksum=$catcksum rts=$rts sub=$sub hello=$hello echo=$echo_ok runner-write=$runner_write fatal=$fatal" | tee -a "$REPORT"
    [ "$rc" = 0 ] && [ "$banner" = 1 ] && [ "$probe" = 1 ] && [ "$listed" = 1 ] && \
        [ "$statline" = 1 ] && [ "$catok" = 1 ] && [ "$catcksum" = 1 ] && [ "$rts" -ge 2 ] && \
        [ "$sub" = 1 ] && [ "$hello" = 1 ] && [ "$echo_ok" = 1 ] && [ "$runner_write" = 1 ] && [ "$fatal" = 0 ]
}

: > "$REPORT"
{
    echo "VIRELAIOS live host-file-channel gate (M34 HF1+HF2, issues #735/#736, claim 4515)"
    echo "revision: $REVISION branch=$BRANCH boots=$BOOTS dirty-files=$DIRTY"
    echo "script: $(tr '\n' '|' < "$SCRIPT")"
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
    echo "verify-live-vf: PASS — VF_PROBE 32 KiB device-write spike + vf ls/cat streaming on VZ ($pass/$n boot(s)); see $REPORT and $GATE_LOG"
    exit 0
else
    echo "verify-live-vf: FAILED — $pass/$n boot(s) passed; see $REPORT and per-boot logs."
    exit 1
fi
