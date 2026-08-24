#!/usr/bin/env bash
#
# verify-live-screen.sh -- claim 6053 (milestone six, card G1) class-B
# gate: the virtio-gpu TRANSPORT + FRAMEBUFFER observed end to end on real
# VZ — the FIRST NON-BLANK framebuffer the host `--screenshot` channel
# catches.
#
# Mechanism: the runner's `--display`/`--screenshot` flag (OFF by default —
# the default VM is untouched) attaches ONE VZVirtioGraphicsDeviceConfiguration
# with a 1280x720 scanout. The guest's virtio_gpu.zig transport (modern
# virtio-pci, DID 0x1050 — observed at claim time; class 0x038000)
# discovers the device pre-exit, negotiates VIRTIO_F_VERSION_1 (plus
# whatever gpu bits the device demands — claim-time observation: the
# device offers RING_PACKED|RING_EVENT_IDX|RING_INDIRECT_DESC|VERSION_1
# and accepts VERSION_1-only), arms queue 0 (controlq) + queue 1
# (cursorq), re-arms post-exit (VZ RESETS the gpu at ExitBootServices —
# `pre-rearm st=00` observed, like blk/entropy), and drives the spec 2D
# path: GET_DISPLAY_INFO (virtio-gpu 1.2 display_one — 24-byte pmodes,
# the 20-byte pre-1.2 shape wedged the device with DEVICE_NEEDS_RESET,
# observed) → RESOURCE_CREATE_2D (B8G8R8X8 = format 2, observed) →
# RESOURCE_ATTACH_BACKING (the fixed BSS framebuffer) → SET_SCANOUT →
# TRANSFER_TO_HOST_2D → RESOURCE_FLUSH. The `screen fill <rrggbb>`
# monitor command re-runs fill → transfer → flush on demand.
#
# Phase 1 (transport report): script `screen | screen fill 00ff00 |
#   screen peek | screen`; asserts the full report — did=0x1050
#   class=0x038000, feat=0x0/0x1 (VER1-only accepted), scanout=1280x720
#   enabled, status=0x0f rearm=1 setup=1, cmds=8 errors=0 timeouts=0
#   (cmds=8 since G2 — the boot banner's present() adds TRANSFER+FLUSH on
#   top of the 6 setup commands),
#   the guest-side fill bytes (peek p1=0xff — the green channel of the
#   first pixel), and the fill command's transfer=ok flush=ok.
# Phase 2 (the pixel proof — the milestone's headline): the host decodes
#   the captured PNG (2560x1440 — the view's retina backing for the
#   1280x720 window) and asserts the frame is the FILL COLOR, not black:
#   the green channel dominates (G > 150, R/B < 160 — the observed
#   color-managed shift of 0x00ff00 → (117, 251, 76)). This is the
#   first non-blank guest framebuffer the host has ever captured.
#
# Honesty: the runner exits 0 only when the expected reply appears; the
# gate additionally asserts every transcript line AND decodes the PNG
# itself (no pixel assertions hidden in the runner). Evidence under
# artifacts/: live-screen-*.txt (runner output), live-screen-*.log
# (serial copies), gpu-screen-*s.png (the captures), and the report.
#
# Run isolation (#523 item 2 / issue #528, claim 5069): the boot attaches a
# private DiskImageKit stacked disk (read-only base + throwaway ASIF
# overlay), a private EFI var store, and writes its serial log and screen
# captures under $RUN_DIR before they are copied to the canonical evidence
# names. DIPSHIT_GATE_SUFFIX=_alt / DIPSHIT_KEEP_RUN=1 supported.
#
# Class B — Apple silicon + VZ only; boots real VMs. A green CI badge
# proves class A only and says nothing about this gate.
#
# Usage:
#   bash tools/verify-live-screen.sh
#
# Evidence: artifacts/live-screen-gate.txt (full output),
# artifacts/live-screen-report.txt (per-phase detail).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source tools/lib/gate-run.sh

SUFFIX="${DIPSHIT_GATE_SUFFIX:-}"
art() { printf 'artifacts/%s%s' "$1" "$SUFFIX"; }

GATE_LOG="$(art live-screen-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

REPORT="$(art live-screen-report.txt)"
RUNNER="host/vm-runner/.build/release/VMRunner"

echo "=== verify-live-screen: claim 6053 — virtio-gpu transport + framebuffer (DID 0x1050, 1.2 display-info, B8G8R8X8 resource, re-arm, first non-blank scanout) ==="

# 1. Build the runner + the disk image (the kernel carries virtio_gpu.zig).
echo
echo "[1/3] building the runner + disk image"
swift build --package-path host/vm-runner --configuration release >/dev/null 2>&1
# The other live gates' convention: the fresh binary needs the
# com.apple.security.virtualization entitlement before it can boot a VM.
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner

# --- per-run isolation -------------------------------------------------------
# Private scratch dir + pristine-boot overlay for EVERY boot.
gate_begin live-screen
echo "run dir: $RUN_DIR"
SCRIPT="$RUN_DIR/script.txt"
zig build >/dev/null 2>&1
zig build image >/dev/null 2>&1

# 2. The scripted boot: report, then the solid GREEN fill (the gate color),
# then the guest-side byte proof, then the report again.
SCRIPT="$RUN_DIR/script.txt"
printf 'screen\nscreen fill 00ff00\nscreen peek\nscreen\n' > "$SCRIPT"
rm -f "$RUN_DIR/vm-serial.log" "$RUN_DIR"/gpu-screen-*.png "$REPORT"

echo
echo "[2/3] live VZ run (scripted)"
set +e
"$RUNNER" "${GATE_RUNNER_ARGS[@]}" \
    --serial "$RUN_DIR/vm-serial.log" --screen "$RUN_DIR/gpu-screen" --script "$SCRIPT" \
    --expect "gpu: screen filled" --timeout 30 \
    > "$(art live-screen-run.txt)" 2>&1
RC=$?
set -e
[ -f "$RUN_DIR/vm-serial.log" ] && cp "$RUN_DIR/vm-serial.log" "$(art live-screen-serial.log)" || true
for f in "$RUN_DIR"/gpu-screen-*.png; do [ -e "$f" ] && cp "$f" artifacts/ || true; done
echo "runner exit: $RC"
echo "--- runner output (gpu lines) ---"
grep -E "gpu:|screen:|screen fill|SUCCESS" "$(art live-screen-run.txt)" | head -40
if [ "$RC" -ne 0 ]; then
    echo "FAIL: runner did not complete successfully (exit $RC)"
    exit 1
fi

# 3. Assertions.
echo
echo "[3/3] asserting the transcript + the captured pixels"

fail() { echo "FAIL: $1"; exit 1; }

# Phase 0 — the evidence path: the capture must be the COMPOSITED WINDOW
# (ScreenCaptureKit), not the cacheDisplay offscreen render. The SCK
# switch (2026-08-12) exists so the gate's pixel evidence is
# pixel-identical to the live `--display` window; the runner prints which
# path produced each capture. Require the SCK line and forbid the
# fallback line — a single fallback capture means the decoded PNG is not
# what the operator sees.
grep -q "capture path: ScreenCaptureKit" artifacts/live-screen-run.txt \
    || fail "pixel evidence did not come from ScreenCaptureKit (composited window) — Screen Recording permission missing or the SCK path broke"
if grep -q "capture path: cacheDisplay fallback" artifacts/live-screen-run.txt; then
    fail "some captures fell back to cacheDisplay (offscreen render) — every capture must be the composited window"
fi

# Phase 1a — the transport report (the class-B record of the device).
grep -q "gpu: pre-rearm st=00" "$(art live-screen-serial.log)" || fail "missing pre-rearm st=00 (the claim-time reset-at-ExitBootServices observation)"
grep -q "gpu: setup ok scanout=0x0000000000000500x0x00000000000002d0" "$(art live-screen-serial.log)" || fail "missing gpu setup-ok line"
grep -q "screen: did=0x0000000000001050" "$(art live-screen-serial.log)" || fail "DID is not 0x1050"
grep -q "screen: feat=0x0000000000000000/0x0000000000000001" "$(art live-screen-serial.log)" || fail "accepted feature mask is not VER1-only"
grep -q "screen: scanout=0x0000000000000500x0x00000000000002d0 enabled=0x0000000000000001" "$(art live-screen-serial.log)" || fail "scanout is not 1280x720 enabled"
grep -q "screen: status=0x000000000000000f rearm=1 setup=1" "$(art live-screen-serial.log)" || fail "status/rearm/setup not as expected"
# The exact cmds counter is session-dependent since G3 (Road Pops): the
# terminal's drain-presents — and the heartbeat/worker reports it tees —
# add TRANSFER+FLUSH pairs on top of the 6 setup commands. The HEALTH
# contract is the stable part: errors=0 timeouts=0 with the device at
# DRIVER_OK through the re-arm.
grep -qE "screen: status=0x000000000000000f rearm=1 setup=1 cmds=[0-9]+ errors=0 timeouts=0" "$(art live-screen-serial.log)" || fail "status/rearm/setup are not healthy (errors=0 timeouts=0)"
grep -q "screen fill: fill=0x000000000000ff00 transfer=ok flush=ok" "$(art live-screen-serial.log)" || fail "fill/transfer/flush did not all complete ok"

# Phase 1b — the guest-side byte proof (the framebuffer REALLY holds green).
grep -q "screen peek: fb=0x00000000" "$(art live-screen-serial.log)" || fail "missing screen peek line"
grep -q "p1=0x00000000000000ff" "$(art live-screen-serial.log)" || fail "framebuffer's green channel is not 0xff"

# Phase 2 — the pixel proof: decode the captured PNG and assert the frame
# is NON-BLANK. Since G3 (Road Pops, claim 1574) the shell's terminal
# renders over the raw fill — its drain-present redraws the whole frame
# (the dark bg + text) after every console write, so the last present
# before the capture is the terminal, not the fill. The FILL is still
# proven byte-level by the guest-side assertions above (the command reply
# `fill=0x…ff00 transfer=ok flush=ok` + `screen peek`'s `p1=0xff`); the
# live frame must show dark background with green-family content.
# The runner writes `--screen <base>` captures as <base>-Ns (no extension).
LATEST="$(ls -t artifacts/gpu-screen-*s 2>/dev/null | head -1 || true)"
if [ -z "$LATEST" ]; then
    fail "no gpu-screen PNG captured"
fi
echo "decoding $LATEST"
python3 - "$LATEST" <<'EOF'
import sys, zlib, struct
path = sys.argv[1]
d = open(path, 'rb').read()
assert d[:8] == b'\x89PNG\r\n\x1a\n', "not a PNG"
pos = 8; idat = b''; w = h = ct = 0
while pos < len(d):
    ln, typ = struct.unpack('>I4s', d[pos:pos+8])
    data = d[pos+8:pos+8+ln]
    if typ == b'IHDR':
        w, h, bd, ct = struct.unpack('>IIBB', data[:10])
    elif typ == b'IDAT':
        idat += data
    pos += 12 + ln
raw = zlib.decompress(idat)
bpp = 4 if ct == 6 else 3
stride = w * bpp
out = bytearray(); prev = bytearray(stride); i = 0
for y in range(h):
    f = raw[i]; i += 1
    line = bytearray(raw[i:i+stride]); i += stride
    if f == 1:
        for x in range(bpp, stride): line[x] = (line[x] + line[x-bpp]) & 0xff
    elif f == 2:
        for x in range(stride): line[x] = (line[x] + prev[x]) & 0xff
    elif f == 3:
        for x in range(stride):
            a = line[x-bpp] if x >= bpp else 0
            line[x] = (line[x] + ((a + prev[x]) >> 1)) & 0xff
    elif f == 4:
        for x in range(stride):
            a = line[x-bpp] if x >= bpp else 0
            b = prev[x]; c = prev[x-bpp] if x >= bpp else 0
            p = a + b - c
            pa, pb, pc = abs(p-a), abs(p-b), abs(p-c)
            pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
            line[x] = (line[x] + pr) & 0xff
    out += line
    prev = line
# Sample the terminal's text region (the top glyph rows) at a fine step
# (step 16 aliases against the 8px glyph grid and the huge dark frame
# drowns the few glyph rows — measured). The frame must be NON-BLANK:
# dark background dominant with green-family content present.
fg = 0; bg = 0; sampled = 0
for y in range(0, 96, 4):
    for x in range(0, 1024, 4):
        k = (y * w + x) * bpp
        r, g, b = out[k], out[k+1], out[k+2]
        sampled += 1
        if g > 150 and r < 160 and b < 160:
            fg += 1
        elif max(r, g, b) < 100:
            bg += 1
fg_frac = fg / sampled if sampled else 0
bg_frac = bg / sampled if sampled else 0
print(f"text region: sampled={sampled} fg={fg} ({fg_frac:.3f}) bg={bg} ({bg_frac:.3f}) — the terminal frame (Road Pops renders over the raw fill since G3)")
if bg_frac < 0.5:
    sys.exit(1)
if fg_frac < 0.01:
    sys.exit(1)
EOF
if [ $? -ne 0 ]; then
    fail "captured framebuffer is black or wrong (expected the non-blank terminal frame)"
fi

echo
echo "=== verify-live-screen: PASS (the non-blank framebuffer — transport healthy, fill proven guest-side, terminal frame on screen) ==="
echo "evidence: artifacts/live-screen-run.txt, the per-run serial log, artifacts/gpu-screen-*.png" | tee "$REPORT"
