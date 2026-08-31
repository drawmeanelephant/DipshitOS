#!/usr/bin/env bash
#
# verify-live-roadpops.sh -- claim 1574 (milestone six, card G3) class-B
# gate: ROAD POPS live on real VZ — the boot TERMINAL renders on the
# screen. The evidence PNGs come from ScreenCaptureKit (the runner matches
# its own window by ID and captures the composited window — pixel-identical
# to `--display`, title bar cropped) with a cacheDisplay fallback when
# Screen Recording permission (TCC) is not granted; the runner's log
# prints which path produced each capture. The M1.5 console
# (line editor, tokenizer, command registry,
# shell idle loop) is unchanged; the kernel seam hands it a Road Pops TEE
# console (kernel/src/road_pops.zig): every byte still reaches serial
# FIRST (the shared seam — the transcript gates keep passing), and G2's
# text layer paints the same banner + prompt + replies on the
# framebuffer, drained ONE full-frame present per output batch by the
# shell idle loop. The G2 one-shot boot paint is replaced by the tee
# rendering the shell's OWN banner (its first present emits the G2
# `text: boot banner presented` evidence on serial).
#
# Phase 1 (shared-seam serial evidence): assert the arm line
# (`roadpops: armed target=fbtext`), the G2 evidence retained
# (`text: boot banner presented`), the `roadpops` command's report
# (`armed=1 dirty=0 presents>=1`), and the transcript still carries the
# banner + the scripted session (the echo reply `ROADPOPS` + the uname
# reply) — the machine STILL boots to a terminal on serial.
# Phase 2 (the pixel proof — the milestone's headline): the host decodes
# the captured PNG (2560x1440 — the view's retina backing for the
# 1280x720 window) and asserts the frame is a WORKING TERMINAL, not a
# static splash:
#   (a) the boot-banner region (the top glyph rows) contains green-family
#       foreground over the dark background (as G2 proved), AND
#   (b) the TERMINAL region BELOW the banner (where the echoed commands +
#       replies rendered) ALSO contains foreground over background — the
#       screen is not a one-shot splash, it carries the live session;
#   (c) the region far below is still the background fill.
# Honest bound (the G1/G2 precedent): byte-exact text is the class A
# mock's domain (the road_pops tee tests + the shell transcript fixture);
# the LIVE pixels are color-managed + retina-scaled, so the live
# assertion is "text is visible in the expected regions with the expected
# color family", not per-glyph equality.
#
# Honesty: the runner exits 0 when the scripted run completes; the gate
# asserts every transcript line AND decodes the PNG itself (no pixel
# assertions hidden in the runner). Evidence under artifacts/: live-rp-*
# (runner output, serial copies, the report) + gpu-screen-*s.png (the
# captures).
#
# Run isolation (#523 item 2 / issue #528, claim 5069): the boot attaches a
# private DiskImageKit stacked disk (read-only base + throwaway ASIF
# overlay), a private EFI var store, and writes its serial log and screen
# captures under $RUN_DIR before they are copied to the canonical evidence
# names. VIRELAI_GATE_SUFFIX=_alt / VIRELAI_KEEP_RUN=1 supported.
#
# Class B — Apple silicon + VZ only; boots real VMs. A green CI badge
# proves class A only and says nothing about this gate.
#
# Usage:
#   bash tools/verify-live-roadpops.sh
#
# Evidence: artifacts/live-roadpops-gate.txt (full output),
# artifacts/live-roadpops-report.txt (per-phase detail).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source tools/lib/gate-run.sh

SUFFIX="${VIRELAI_GATE_SUFFIX:-}"
art() { printf 'artifacts/%s%s' "$1" "$SUFFIX"; }

GATE_LOG="$(art live-roadpops-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

REPORT="$(art live-roadpops-report.txt)"
RUNNER="host/vm-runner/.build/release/VMRunner"

echo "=== verify-live-roadpops: claim 1574 — Road Pops, the boot terminal on the screen (tee console: serial shared seam + framebuffer text) ==="

# 1. Build the runner + the disk image (the kernel carries road_pops.zig).
echo
echo "[1/3] building the runner + disk image"
swift build --package-path host/vm-runner --configuration release >/dev/null 2>&1
# The other live gates' convention: the fresh binary needs the
# com.apple.security.virtualization entitlement before it can boot a VM.
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner

# --- per-run isolation -------------------------------------------------------
# Private scratch dir + pristine-boot overlay for EVERY boot.
gate_begin live-roadpops
echo "run dir: $RUN_DIR"
SCRIPT="$RUN_DIR/script.txt"
zig build >/dev/null 2>&1
zig build image >/dev/null 2>&1

# 2. The scripted boot: a real terminal SESSION — echo a distinctive
# marker, run uname, and report the tee state. The boot banner + prompt
# already rendered through the tee before the script arrives.
SCRIPT="$RUN_DIR/script.txt"
printf 'echo ROADPOPS\nuname\nroadpops\n' > "$SCRIPT"
rm -f "$RUN_DIR/vm-serial.log" "$RUN_DIR"/gpu-screen-*.png "$REPORT"

echo
echo "[2/3] live VZ run (scripted)"
set +e
"$RUNNER" "${GATE_RUNNER_ARGS[@]}" \
    --serial "$RUN_DIR/vm-serial.log" --screen "$RUN_DIR/gpu-screen" --script "$SCRIPT" \
    --expect "roadpops: armed target=fbtext" --timeout 30 \
    > "$(art live-roadpops-run.txt)" 2>&1
RC=$?
set -e
[ -f "$RUN_DIR/vm-serial.log" ] && cp "$RUN_DIR/vm-serial.log" "$(art live-roadpops-serial.log)" || true
for f in "$RUN_DIR"/gpu-screen-*.png; do [ -e "$f" ] && cp "$f" artifacts/ || true; done
echo "runner exit: $RC"
echo "--- runner output (roadpops/text/session lines) ---"
grep -E "roadpops:|text:|ROADPOPS|SUCCESS|FAILURE" "$(art live-roadpops-run.txt)" | head -40
if [ "$RC" -ne 0 ]; then
    echo "FAIL: runner did not complete successfully (exit $RC)"
    exit 1
fi

# 3. Assertions.
echo
echo "[3/3] asserting the serial transcript + the captured pixels"

fail() { echo "FAIL: $1"; exit 1; }

# Phase 0 — the evidence path: the capture must be the COMPOSITED WINDOW
# (ScreenCaptureKit), not the cacheDisplay offscreen render. The SCK
# switch (2026-08-12) exists so the gate's pixel evidence is
# pixel-identical to the live `--display` window; the runner prints which
# path produced each capture. Require the SCK line and forbid the
# fallback line — a single fallback capture means the decoded PNG is not
# what the operator sees.
grep -q "capture path: ScreenCaptureKit" "$(art live-roadpops-run.txt)" \
    || fail "pixel evidence did not come from ScreenCaptureKit (composited window) — Screen Recording permission missing or the SCK path broke"
if grep -q "capture path: cacheDisplay fallback" "$(art live-roadpops-run.txt)"; then
    fail "some captures fell back to cacheDisplay (offscreen render) — every capture must be the composited window"
fi

# Phase 1 — the shared-seam serial evidence (the machine STILL boots to a
# terminal on serial AND the same session rendered on the screen).
grep -q "roadpops: armed target=fbtext" "$(art live-roadpops-serial.log)" || fail "the Road Pops tee was not armed with the framebuffer target"
grep -q "text: boot banner presented" "$(art live-roadpops-serial.log)" || fail "boot banner not presented (the tee's first present must emit the G2 evidence)"
# The script arrives as one input burst, so the mid-burst report can
# catch the echo pending its drain (dirty=1) — the honest assert is
# armed=1 with at least the boot present already pushed.
grep -qE "roadpops: armed=1 dirty=[01] presents=[1-9][0-9]*" "$(art live-roadpops-serial.log)" || fail "the roadpops report does not show armed=1 with presents>=1"
grep -q "VirelaiOS - AArch64 firmware-assisted kernel monitor" "$(art live-roadpops-serial.log)" || fail "serial transcript lost the banner (shared-seam regression)"
grep -q "ROADPOPS" "$(art live-roadpops-serial.log)" || fail "the echo reply never reached serial (shared-seam regression)"
grep -q "VirelaiOS aarch64" "$(art live-roadpops-serial.log)" || fail "the uname reply never reached serial (shared-seam regression)"

# Phase 2 — the pixel proof: decode the captured PNG and assert a WORKING
# terminal. The runner writes `--screen <base>` captures as <base>-Ns.
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

def px(x, y):
    k = (y * w + x) * bpp
    return out[k], out[k+1], out[k+2]  # r, g, b

def is_fg(rgb):
    r, g, b = rgb
    return g > 150 and r < 160 and b < 160  # the observed shift of 0x00ff00

def is_bg(rgb):
    return max(rgb) < 100  # 0x101418 stays dark through the pipeline

def region(y0, y1, step):
    fg = bg = total = 0
    for y in range(y0, y1, step):
        for x in range(0, 1024, step):
            rgb = px(x, y)
            total += 1
            if is_fg(rgb): fg += 1
            elif is_bg(rgb): bg += 1
    return fg, bg, total

# Region A — the boot banner: the top glyph rows (the shell's banner +
# prompt, rendered through the tee).
fg_a, bg_a, tot_a = region(0, 48, 4)
fa = fg_a / tot_a if tot_a else 0
ba = bg_a / tot_a if tot_a else 0
print(f"banner region: sampled={tot_a} fg={fg_a} ({fa:.3f}) bg={bg_a} ({ba:.3f})")
if fa < 0.01:
    sys.exit("FAIL: no foreground (green-family) pixels in the boot-banner region")
if ba < 0.5:
    sys.exit("FAIL: the boot-banner region is not background-dominated")

# Region B — the TERMINAL session below the banner: the echoed commands +
# replies (rows ~6-15 of the 8px grid). THE G3 HEADLINE: the screen is a
# working terminal, not a one-shot splash.
fg_b, bg_b, tot_b = region(48, 128, 4)
fb = fg_b / tot_b if tot_b else 0
bb = bg_b / tot_b if tot_b else 0
print(f"terminal region: sampled={tot_b} fg={fg_b} ({fb:.3f}) bg={bg_b} ({bb:.3f})")
if fb < 0.01:
    sys.exit("FAIL: no foreground pixels below the banner — the live terminal session did not render")
if bb < 0.5:
    sys.exit("FAIL: the terminal region is not background-dominated")

# Region C — far below the session: still the background fill.
fg_c, bg_c, tot_c = region(h - 96, h, 8)
bc = bg_c / tot_c if tot_c else 0
print(f"lower region: sampled={tot_c} bg={bg_c} ({bc:.3f})")
if bc < 0.9:
    sys.exit("FAIL: the region below the terminal is not the background fill")

print("PASS: the captured frame is a working terminal — banner AND live session glyphs over the dark background")
EOF
if [ $? -ne 0 ]; then
    fail "captured framebuffer does not show the live terminal session (splash only, black, or garbage)"
fi

echo
echo "=== verify-live-roadpops: PASS (the boot terminal is on the screen — Road Pops, serial shared seam intact) ==="
echo "evidence: "$(art live-roadpops-run.txt)", the per-run serial log, artifacts/gpu-screen-*.png" | tee "$REPORT"
