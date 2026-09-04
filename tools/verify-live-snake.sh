#!/usr/bin/env bash
#
# verify-live-snake.sh -- class-B gate: the VL6 snake game (tests/zc-corpus/
# snake-*.z) compiles IN-GUEST with ZC.BIN, runs as a windowed EL0 program,
# and its pixels are proven on the host framebuffer capture. First live RUN
# consumer of the VL6 GUI surface (the vl6 corpus fixture is compile-only)
# and of the raw zc.svc(21, &buf) event-poll seam (ADR 0009) from zc code.
#
# What the gate proves, in one display-backed boot:
#   1. ZC.BIN compiles the 4-file group in-guest (SNAKE.Z SLIB.Z EV.Z
#      FOOD.Z -> SNAKE.ELF) under `strace exec` (traced full source reads,
#      the 2048-B single-read cap regression guard).
#   2. SNAKE.ELF runs: prints snake-up, idles ~1 s/frame (the 1 s
#      scheduler tick — the window a human would click), prints the
#      snake-wait marker after its second painted frame, auto-starts
#      after 8 idle seconds, prints snake-move on the first move, then
#      plays itself into the right wall IN ONE scheduler quantum (the
#      auto-play paces by yield, not sleep — it never depends on wake
#      latency), prints snake-over and sys_exits 72 (72 = the corpus
#      self-check convention; DISTINCTIVE from the compiler task's exit 0,
#      so the gate's expect line cannot match the wrong task). The gate
#      asserts all four needles IN ORDER.
#   3. RENDERING: the boot attaches the virtio-gpu (--display, the
#      claim-6053 path — without it sys_win_open is EINVAL and the window
#      never exists), so win_open/win_fill/win_present return 0 and the
#      shell idle loop's composite path paints the window. The host
#      captures the framebuffer (--screen periodic 5/10/15 s PLUS a
#      deterministic --screenshot-after snake-wait marker capture — the
#      marker fires ~1 s into the painted idle, so the capture reliably
#      shows the window), and the gate decodes the PNGs and asserts the
#      game's colors — the dark 0x0B1220 board, the green-family head cell
#      (0xA7F3D0) and the pink 0xF43F5E food — inside the board rect (inner
#      (542,298 196x134), clear of the WM frame/title bar). Input is NOT part of
#      this gate: the game auto-plays headless-deterministic, so no
#      keyboard/pointer device is needed (interactive play stays class C).
#
# Honesty: the corpus leg of the same sources (verify-zc-corpus.sh case
# snk) is the headless dual-parity gate (compile + run + exit 0 + ordered
# needles) where win syscalls are EINVAL-ignored — pixels can only be
# proven where a gpu exists, which is this gate. The capture path is
# reported (ScreenCaptureKit vs the cacheDisplay fallback) but either is
# accepted: the assertion is about the GUEST framebuffer content, and the
# fallback renders exactly that.
#
# Run isolation: private RUN_DIR + pristine overlay (tools/lib/gate-run.sh),
# VIRELAI_GATE_SUFFIX=_alt / VIRELAI_KEEP_RUN=1 supported.
#
# Class B — Apple silicon + VZ only. Usage:
#   bash tools/verify-live-snake.sh
# Evidence: artifacts/live-snake-gate.txt, live-snake-report.txt,
# live-snake-run-01.txt, live-snake-serial-01.log, live-snake-screen-*.png.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source tools/lib/gate-run.sh

SUFFIX="${VIRELAI_GATE_SUFFIX:-}"
art() { printf 'artifacts/%s%s' "$1" "$SUFFIX"; }

GATE_LOG="$(art live-snake-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

BOOTS="${BOOTS:-1}"
REPORT="$(art live-snake-report.txt)"
STATIC_EXIT_LINE="tasks user-el0 exited status=7"
COMPILE_LINE="zc: successfully compiled in-guest"
EXIT_LINE="tasks user-exec exited status=72"
REAP_LINE="tasks user-exec reaped"

echo "=== verify-live-snake: VL6 snake — compiled in-guest, run windowed, pixels proven ($BOOTS boot(s), display-backed) ==="
zig version
swift --version 2>&1 | head -1
sw_vers
REVISION="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
DIRTY="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
echo "revision: $REVISION branch=$BRANCH boots=$BOOTS dirty-files=$DIRTY"

# --- host compile-check phase (the Z4b dual-parity fast fail) --------------
# Every tests/zc-corpus fixture — now including the snake group — must build
# strict-valid against the REAL shim (user/src/lib/zc.zig, whose svc is
# anytype-widened for the zc.svc(21, &buf) call) + pass the loader contract.
echo "=== verify-live-snake: host compile check (delegated to verify-zc-corpus.sh --host) ==="
if ! bash tools/verify-zc-corpus.sh --host; then
    echo "verify-live-snake: FAILED — corpus host compile phase failed" >&2
    exit 1
fi
echo "host compile check: ok — every corpus case builds a strict-valid host ELF under zig $(zig version)"

# --- build the runner + image -----------------------------------------------
zig fmt --check boot/src/*.zig kernel/src/*.zig user/src/*.zig build.zig
zig build
zig build image
swift build --package-path host/vm-runner --configuration release -Xswiftc -DSPIKE >/dev/null 2>&1
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner

# --- per-run isolation -------------------------------------------------------
gate_begin live-snake
gate_arm_share
echo "run dir: $RUN_DIR"
cp zig-out/bin/ZC.BIN "$SHARE/ZC.BIN"
echo "staged ZC.BIN ($(wc -c < "$SHARE/ZC.BIN" | tr -d ' ') B) from zig-out/bin"
for pair in "SNAKE.Z tests/zc-corpus/snake-main.z" "SLIB.Z tests/zc-corpus/snake-lib.z" "EV.Z tests/zc-corpus/snake-events.z" "FOOD.Z tests/zc-corpus/snake-food.z"; do
    set -- $pair
    cp "$2" "$SHARE/$1"
    echo "staged $1 ($(wc -c < "$SHARE/$1" | tr -d ' ') B) from $2"
done

SCRIPT="$RUN_DIR/script.txt"
SCRIPT2="$RUN_DIR/script2.txt"
printf 'ls\nstrace exec ZC.BIN SNAKE.Z SLIB.Z EV.Z FOOD.Z SNAKE.ELF\n' > "$SCRIPT"
printf 'ls\nexec SNAKE.ELF\necho rx-snake-ok\n' > "$SCRIPT2"

run_one() {
    local tag="$1"
    local run_log="$(art live-snake-run-$tag.txt)"
    local serial_copy="$(art live-snake-serial-$tag.log)"
    rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial-$tag.log" "$RUN_DIR"/snake-screen-*

    set +e
    host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
        --serial "$RUN_DIR/vm-serial-$tag.log" \
        --display \
        --screen "$RUN_DIR/snake-screen" \
        --screenshot-after "snake-wait" \
        --script "$SCRIPT" --script-after "$STATIC_EXIT_LINE" \
        --script2 "$SCRIPT2" --script2-after "$COMPILE_LINE" \
        --script-expect "$EXIT_LINE" --script-expect-tail 2 --timeout 120 > "$run_log" 2>&1
    local rc=$?
    set -e
    [ -f "$RUN_DIR/vm-serial-$tag.log" ] && cp "$RUN_DIR/vm-serial-$tag.log" "$serial_copy" || true
    local n=0
    for f in "$RUN_DIR"/snake-screen-*; do
        [ -e "$f" ] || continue
        n=$((n + 1))
        cp "$f" "$(art live-snake-screen-$(basename "$f" | sed 's/^snake-screen-//'))"
    done
    echo "captures: $n PNG(s) copied to artifacts/live-snake-screen-*"
    local SER="$serial_copy"

    local needles=(snake-up snake-wait snake-move snake-over)
    local bytes=0 banner=0 listed=0 compiled=0 loaded=0 markers_ok=0 exit0=0 reaped=0 echo_ok=0 ordered=0 fatal=0
    if [ -f "$SER" ]; then
        bytes="$(wc -c < "$SER" | tr -d ' ')"
        [ "$(grep -aFxc -- "VirelaiOS kernel has seized control." "$SER" || true)" = 1 ] && banner=1
        for sname in SNAKE.Z SLIB.Z EV.Z FOOD.Z; do
            [ "$(grep -aFc -- "$sname" "$SER" || true)" -ge 1 ] && listed=$((listed + 1))
        done
        [ "$listed" = 4 ] && listed=1 || listed=0
        [ "$(grep -aFc -- "zc: successfully compiled in-guest" "$SER" || true)" = 1 ] && compiled=1
        [ "$(grep -aFc -- "exec: loaded SNAKE.ELF size=" "$SER" || true)" = 1 ] && loaded=1
        local present=0 m=""
        for m in "${needles[@]}"; do
            [ "$(grep -aFc -- "$m" "$SER" || true)" -ge 1 ] && present=$((present + 1))
        done
        [ "$present" = "${#needles[@]}" ] && markers_ok=1
        # Order proof: first occurrence of snake-up -> snake-move -> snake-over ascends.
        if python3 - "$SER" "${needles[@]}" <<'PY' 2>/dev/null; then
import sys
path = sys.argv[1]
names = sys.argv[2:]
data = open(path, "rb").read()
last = -1
for name in names:
    idx = data.find(name.encode())
    if idx < 0 or idx < last:
        sys.exit(1)
    last = idx
sys.exit(0)
PY
            ordered=1
        fi
        [ "$(grep -aFxc -- "$EXIT_LINE" "$SER" || true)" -ge 1 ] && exit0=1
        [ "$(grep -aFc -- "$REAP_LINE" "$SER" || true)" -ge 2 ] && reaped=1
        [ "$(grep -aFxc -- "rx-snake-ok" "$SER" || true)" = 1 ] && echo_ok=1
        grep -qF -- "[EXC] parking:" "$SER" && fatal=1 || true
    fi
    # The window syscalls must have SUCCEEDED (win_open returned a real
    # window id — a headless boot would EINVAL it). The serial log does not
    # carry the id, so this is proven by the pixels; the kernel's own gpu
    # setup line (uart) is surfaced as the transport evidence.
    grep -aFc -- "gpu: setup ok scanout=" "$SER" >/dev/null 2>&1 && gpu_setup=1 || gpu_setup=0
    echo "$tag: runner-rc=$rc serial-bytes=$bytes banner=$banner listed=$listed compiled=$compiled loaded=$loaded markers=$markers_ok exit0=$exit0 reaped=$reaped echo=$echo_ok ordered=$ordered gpu-setup=$gpu_setup fatal=$fatal" | tee -a "$REPORT"

    local serial_pass=0
    [ "$rc" = 0 ] && [ "$banner" = 1 ] && [ "$listed" = 1 ] && \
        [ "$compiled" = 1 ] && [ "$loaded" = 1 ] && [ "$markers_ok" = 1 ] && [ "$exit0" = 1 ] && \
        [ "$reaped" = 1 ] && [ "$echo_ok" = 1 ] && [ "$ordered" = 1 ] && [ "$fatal" = 0 ] && serial_pass=1
    echo "$tag: serial leg -> $([ "$serial_pass" = 1 ] && echo PASS || echo FAIL)" | tee -a "$REPORT"
    [ "$serial_pass" = 1 ]
}

run_pixels() {
    # Decode every captured PNG and assert the game window's colors inside a
    # rect well within the board. The WM draws a title bar + frame border
    # over the requested 208x152 window (measured insets: ~5 px left/right,
    # ~14 px top — the title-bar chrome is green/pink and must be EXCLUDED),
    # so the assertion rect is (542,298 196x134) in scanout coords, inside
    # the 0x0B1220 board. At least ONE capture must show a dark-board
    # majority plus green-family cells (head 0xA7F3D0 / body 0x34D399) and
    # pink food (0xF43F5E). Channel-dominance tests, tolerant of the
    # observed color-managed shift; thresholds calibrated on real captures
    # (a full 8px cell reads ~64 hits at the 2x subsample; head=68 food=16).
    local win=0 n=0 found=0
    for f in artifacts/live-snake-screen-*; do
        [ -e "$f" ] || continue
        found=$((found + 1))
        [ -e "$f" ] || continue
        n=$((n + 1))
        if python3 - "$f" <<'PY'; then
import sys, zlib, struct

def decode(path):
    d = open(path, 'rb').read()
    assert d[:8] == b'\x89PNG\r\n\x1a\n', "not a PNG"
    pos = 8; idat = b''; w = h = ct = 0
    while pos < len(d):
        ln, typ = struct.unpack('>I4s', d[pos:pos+8])
        data = d[pos+8:pos+8+ln]
        if typ == b'IHDR':
            w, h, _, ct = struct.unpack('>IIBB', data[:10])
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
    return w, h, bpp, out

w, h, bpp, out = decode(sys.argv[1])
# The scanout is 1280x720; the capture is the window content at backing scale.
scale = w / 1280.0
# Inner rect, clear of the WM frame: origin (536,284)+insets, minus borders.
x0, y0, ww, wh = int(542 * scale), int(298 * scale), int(196 * scale), int(134 * scale)
if x0 + ww > w or y0 + wh > h:
    print(f"pixels: {sys.argv[1]}: window rect {x0},{y0} {ww}x{wh} outside {w}x{h} — skipping")
    sys.exit(1)
dark = green = pink = total = 0
for yy in range(y0, y0 + wh, 2):
    for xx in range(x0, x0 + ww, 2):
        k = (yy * w + xx) * bpp
        r, g, b = out[k], out[k+1], out[k+2]
        total += 1
        if max(r, g, b) < 100:
            dark += 1
        elif g > 120 and g >= r and g >= b:
            green += 1
        elif r > 140 and r > g + 30 and r > b:
            pink += 1
dark_frac = dark / total if total else 0
# Calibrated on real captures: head cell = 64-68 hits, food cell = 16 hits
# (2x capture, 2px subsample, channel-dominance classifiers). Thresholds at
# half-cell margins so a partially-occluded cell still passes.
ok = dark_frac > 0.5 and green >= 32 and pink >= 8
print(f"pixels: {sys.argv[1]}: {w}x{h} scale={scale:.2f} window={x0},{y0}+{ww}x{wh} "
      f"dark={dark}/{total} ({dark_frac:.2f}) green={green} pink={pink} -> {'OK' if ok else 'BAD'}")
sys.exit(0 if ok else 1)
PY
            win=$((win + 1))
        fi
    done
    if [ "$found" = 0 ]; then
        echo "pixels: FAIL — no live-snake-screen PNG captured" | tee -a "$REPORT"
        return 1
    fi
    echo "pixels: $win/$found captures showed the game window (dark board + green snake cells + pink food)" | tee -a "$REPORT"
    [ "$win" -ge 1 ]
}

: > "$REPORT"
{
    echo "VIRELAIOS live snake gate — VL6 first run consumer (zc.svc event poll + window syscalls + pixels)"
    echo "revision: $REVISION branch=$BRANCH boots=$BOOTS dirty-files=$DIRTY"
    echo "script: $(cat "$SCRIPT" | tr '\n' '|')"
    echo "date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo
} >> "$REPORT"

pass=0
n=0
while [ "$n" -lt "$BOOTS" ]; do
    n=$((n + 1))
    echo
    echo "=== live-snake boot $n ==="
    if run_one "$(printf '%02d' "$n")"; then
        echo "=== live-snake boot $n: pixel leg ==="
        if run_pixels; then
            pass=$((pass + 1))
        fi
    fi
done

echo
echo "=== result ==="
if [ "$pass" = "$BOOTS" ]; then
    echo "verify-live-snake: PASS — ZC.BIN compiled the 4-file snake group in-guest, SNAKE.ELF ran it windowed (snake-up → snake-wait → snake-move → snake-over in order, exit 72), and the framebuffer capture showed the game (dark board + green snake + pink food in the board rect) ($pass/$BOOTS boot(s))."
    echo "PASS: $pass/$BOOTS" >> "$REPORT"
    exit 0
fi
echo "verify-live-snake: FAILED — $pass/$BOOTS boot(s) passed; see $REPORT, the per-boot logs, and artifacts/live-snake-screen-*.png."
echo "FAIL: $pass/$BOOTS" >> "$REPORT"
exit 1
