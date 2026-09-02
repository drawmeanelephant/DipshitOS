#!/usr/bin/env bash
#
# verify-live-wasm.sh — M35 class-B gates: the wasm interpreter on real VZ.
#
# W2 (#763) vertical proof (regression, kept green):
#   1. The HOST builds the C hello-world with `zig cc -target
#      wasm32-freestanding -nostdlib -fno-sanitize=undefined -g0` (the
#      pinned 411-byte fixture: imports env.write/env.exit via clang's
#      import_module/import_name attributes, exports _start) and drops it
#      into the `--cvc-file` share — no image rebuild. The build is
#      byte-deterministic with -g0 + a fixed output basename (the only
#      remaining entropy is the output name in the name custom section;
#      without -g0 the DWARF custom sections embed the source path), so
#      the gate pins the sha256.
#   2. `zig build wasm` produces WASM.BIN (DSK3 segmented: .bss keeps the
#      interpreter state — Module ~77 KiB + Machine ~30 KiB + module
#      buffer 64 KiB — under the 256 KiB loader staging budget; the 2 MiB
#      linear memory is mmap'd at runtime, NOT .bss). WASM.BIN is dropped
#      into the same share.
#   3. The boot runs `exec WASM.BIN HELLO.WASM`: the kernel STATs the
#      share and streams WASM.BIN across chunked READ round trips (HF4,
#      issue #738), argv[1]=HELLO.WASM rides the DSK3 writable data tail
#      (card 3e — ELF images cannot take argv), and WASM.BIN's _start
#      reads /host/HELLO.WASM through slots 23/24/26, parses/validates/
#      instantiates, and dispatches env.write → console byte-exact
#      ("hello, wasm!") and env.exit → status 55.
#
# W3 (#764) phases (same boot, --display armed for the window app):
#   4. `exec WASM.BIN WINAPP.WASM` — the wasm window app (tests/winapp.c,
#      compiled against tests/virelai.h alone, pinned ee33f184 — the
#      "host program against the contract alone" rule): opens a 96x48
#      window at (100,100) via env.win_open (slot 12), prints its id,
#      fills it 0xFF0000 with env.win_fill, provokes a kernel-side EINVAL
#      (win_set_visible(id,2) → -1 — the negative error mapping through
#      the WHOLE stack), presents, exits 21. The `dui` snapshot after it
#      must show a window row with rect=100,100,96,48, and the screen
#      capture must contain the red fill at 2x(100..196,100..148) retina.
#   5. `exec WASM.BIN FILEAPP.WASM` — the wasm file app (tests/fileapp.c,
#      pinned 9f31d07e): env.file_open("/host/FILE.TXT") through the M34
#      HF4 share transport, env.file_read in 128-byte chunks, each chunk
#      echoed byte-exact to the console with env.write, and exit status =
#      the total byte count (512 — asserted in the process report).
#
# W5 (#766) phase (same boot, the milestone's payoff — a real tool):
#   5c. `exec WASM.BIN WC.WASM` — the wc capstone (tests/wc.c, written from
#      the contract doc + tests/virelai.h alone — the standalone-author
#      provenance proof; pinned b75c504d): reads /host/WC.TXT through the
#      file channel in 64-byte chunks, counts bytes/lines/words, prints the
#      classic right-aligned wc line byte-exact (`  8  32 320 /host/WC.TXT`
#      against the deterministic 320-byte fixture, counts cross-validated
#      against host `wc`), exits 320 (the byte count).
#
# W4 (#765) phases (same boot, same fixture pattern):
#   5b. `exec WASM.BIN FLOATAPP.WASM` — the wasm float app
#      (tests/floatapp.c, compiled against tests/virelai.h alone, pinned
#      c963d5aa): a no-libc C float utility (C->F/F->C temperature
#      converter) whose volatile input tables defeat constant-folding so
#      the float opcodes execute at runtime — f64/f32 arith chains
#      (0xA0/0xA2/0xA3, 0x92..), f64.convert_i64_s (0xB9),
#      i32.trunc_sat_f64_s (0xFC 2 — clang lowers C casts to the
#      saturating form), f64.promote_f32 (0xBB), the 0xAA..0xB1 plain
#      trunc family where range is provable, bit-pattern hex dumps, and
#      i64.extend_i32_s (0xAC) in the sign-ext sanity check. Five
#      distinctive byte-exact output lines are asserted per run plus the
#      exit status = 590 (the total output byte count — fileapp's length
#      proof), so a float-op regression drifts both.
#   6. `zig build shim-check` (class A, run here too): tests/virelai-probe.c
#      compiles against tests/virelai.h and its import table is exactly
#      the frozen env.* surface (contract §5 + write/exit).
#   7. The shell stays responsive throughout (the rx-* echo after each).
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

GATE_LOG="$(art m35-wasm-live.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

BOOTS="${BOOTS:-1}"
REPORT="$(art live-wasm-report.txt)"
STATIC_EXIT_LINE="tasks user-el0 exited status=7"
HELLO_LINE="hello, wasm!"
WASM_EXIT_LINE="tasks user-exec exited status=55"
WIN_OK_LINE="w3: win ok"
WIN_EXIT_LINE="tasks user-exec exited status=21"
FILE_EXIT_LINE="tasks user-exec exited status=512"
FLOAT_EXIT_LINE="tasks user-exec exited status=590"
WC_LINE="  8  32 320 /host/WC.TXT"
WC_EXIT_LINE="tasks user-exec exited status=320"
FAIL_NEEDLES=("wasm: open failed" "wasm: parse error" "wasm: validate error" "wasm: mmap failed" "wasm: trap" "wasm: instantiate trap")

echo "=== verify-live-wasm: M35 W2+W3+W4+W5 — C hello-world, wasm window/file/float apps + the wc capstone in-guest, $BOOTS boot(s) ==="
zig version
swift --version 2>&1 | head -1
sw_vers
REVISION="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
DIRTY="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
echo "revision: $REVISION branch=$BRANCH boots=$BOOTS dirty-files=$DIRTY"

zig fmt --check boot/src/*.zig kernel/src/*.zig user/src/*.zig build.zig
zig build
zig build image
# The custom-virtio file device needs the SPIKE build type (macOS 27 SDK).
zig build wasm
# W3 acceptance item: virelai.h compiles a host program against the
# contract alone, and its import table is exactly the frozen surface.
zig build shim-check
swift build --package-path host/vm-runner --configuration release -Xswiftc -DSPIKE
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner

# Gate-owned captures from a PREVIOUS run in this worktree must not
# satisfy this run's red-fill scan (artifacts/ accumulates across local
# reruns; CI runners are fresh). Gate-owned names only.
rm -f artifacts/gpu-screen-* 2>/dev/null || true

gate_begin live-wasm
echo "run dir: $RUN_DIR"

# --- the share: the interpreter app + the three module fixtures ---
SHARE="$RUN_DIR/share"
mkdir -p "$SHARE"
cp zig-out/bin/WASM.BIN "$SHARE/WASM.BIN"
echo "WASM.BIN: $(wc -c < "$SHARE/WASM.BIN" | tr -d ' ') bytes dropped into the share (zig build wasm)"

# W2 fixture: built by the gate, sha-pinned (see header for determinism).
cat > "$RUN_DIR/hello.c" <<'EOF'
__attribute__((import_module("env"), import_name("exit")))
__attribute__((noreturn)) void exit(int status);
__attribute__((import_module("env"), import_name("write")))
int write(int fd, const void *buf, unsigned long n);
void _start(void) {
    write(1, "hello, wasm!\n", 13);
    exit(55);
}
EOF
zig cc -target wasm32-freestanding -nostdlib -fno-sanitize=undefined -g0 \
    "$RUN_DIR/hello.c" -o "$SHARE/HELLO.WASM"
WASM_SIZE="$(wc -c < "$SHARE/HELLO.WASM" | tr -d ' ')"
WASM_SHA="$(shasum -a 256 "$SHARE/HELLO.WASM" | cut -d' ' -f1)"
PINNED_SHA="edb6407bf595a0190a73f8df3b560bb5b9e32a07d0d0d78728f69bb9d113ce61"
echo "HELLO.WASM: $WASM_SIZE bytes sha256=$WASM_SHA"
if [ "$WASM_SHA" != "$PINNED_SHA" ]; then
    echo "FAIL: HELLO.WASM sha256 drifted from the pinned $PINNED_SHA (fixture regression)" >&2
    exit 1
fi

# W3 fixtures: committed binaries (user/src/wasm-corpus/, compiled from
# tests/*.c against tests/virelai.h alone), sha-pinned + re-verified by
# the host test "w3: live-gate app fixtures parse + validate".
cp user/src/wasm-corpus/winapp.wasm "$SHARE/WINAPP.WASM"
cp user/src/wasm-corpus/fileapp.wasm "$SHARE/FILEAPP.WASM"
WIN_SHA="$(shasum -a 256 "$SHARE/WINAPP.WASM" | cut -d' ' -f1)"
FIL_SHA="$(shasum -a 256 "$SHARE/FILEAPP.WASM" | cut -d' ' -f1)"
echo "WINAPP.WASM sha256=$WIN_SHA (pinned ee33f184); FILEAPP.WASM sha256=$FIL_SHA (pinned 9f31d07e)"
if [ "$WIN_SHA" != "ee33f184df3a5fed1cfc610b467b3595814afa2ab751cfc6fb84f85a32e353f6" ] || \
   [ "$FIL_SHA" != "9f31d07ec306d10eada0391e2ece92d92b21012fd71a2fdd90b24b9f62147c7c" ]; then
    echo "FAIL: a W3 app fixture sha256 drifted from its pin (regenerate from tests/*.c)" >&2
    exit 1
fi
# W4 fixture: the named C float utility (tests/floatapp.c — temp-unit
# converter, volatile tables so the float ops run at runtime), built with
# the same determinism recipe as the W3 app binaries; sha-pinned here and
# re-verified by the host test "w4: floatapp fixture runs in-guest
# byte-exact".
cp user/src/wasm-corpus/floatapp.wasm "$SHARE/FLOATAPP.WASM"
FLO_SHA="$(shasum -a 256 "$SHARE/FLOATAPP.WASM" | cut -d' ' -f1)"
echo "FLOATAPP.WASM sha256=$FLO_SHA (pinned c963d5aa)"
if [ "$FLO_SHA" != "c963d5aa897ca2b7607587ec9f9137cf188635545c8f0b3463117f23df348b42" ]; then
    echo "FAIL: the W4 app fixture sha256 drifted from its pin (regenerate from tests/floatapp.c)" >&2
    exit 1
fi
# W5 fixture: the wc capstone (tests/wc.c — written from the contract doc
# + virelai.h alone), rebuilt-deterministic, sha-pinned; plus the
# deterministic 320-byte WC.TXT it counts (tests/wc-fixture.txt — the SAME
# bytes the host test embeds). Expected: 8 lines / 32 words / 320 bytes,
# printed byte-exact as "  8  32 320 /host/WC.TXT", exit status 320.
cp user/src/wasm-corpus/wc.wasm "$SHARE/WC.WASM"
cp tests/wc-fixture.txt "$SHARE/WC.TXT"
WC_SHA="$(shasum -a 256 "$SHARE/WC.WASM" | cut -d' ' -f1)"
echo "WC.WASM sha256=$WC_SHA (pinned b75c504d); WC.TXT $(wc -c < "$SHARE/WC.TXT" | tr -d ' ') bytes"
if [ "$WC_SHA" != "b75c504ddbb30b8ada6244cb95d3aaf532c49f79a45e7a68dc02151211e7746c" ]; then
    echo "FAIL: the W5 capstone sha256 drifted from its pin (regenerate from tests/wc.c)" >&2
    exit 1
fi
# The file-app fixture: 16-byte line x 32 = 512 bytes, byte-exact echo.
python3 - "$SHARE/FILE.TXT" <<'EOF'
import sys
open(sys.argv[1], "wb").write(b"w3-filerocks!!!\n" * 32)
EOF
echo "FILE.TXT: $(wc -c < "$SHARE/FILE.TXT" | tr -d ' ') bytes written to the share"

# --- guest scripts ---------------------------------------------------------
# The runner supports TWO phases (claim 4613): script1 plays at boot;
# script2 is injected only AFTER its marker appears in the serial (claim
# 9489 settles the burst first). That marker pacing is the ONLY reliable
# way to inspect the wasm window: the shell consumes script1 lines far
# ahead of the apps (their exec streams the 55-KiB WASM.BIN through
# chunked share reads), so a naive burst of `dui` lines races the window.
# Script1: the four short non-display apps run first (floatapp, fileapp,
# hello, wc — pure compute/write, proven safe concurrently; the "faulted
# once" three-way was a display-app overlap), then the winapp loads and
# spins; the short apps first keep the winapp's overlap set at <=1 app.
# `w3: win ok`
# (printed just before the spin) triggers script2: dui snapshots (window
# rows), `dui raise 2` (the post-WMS composite trigger — the kernel no
# longer composites user windows unprompted, so the raise blits it into
# the scanout and moves user_blits), a confirming dui (blits>=1), and the
# final marker that ALSO triggers the runner's marker-driven screenshot
# (deterministic pixel capture — no race with the 5/10/15 s periodic
# captures).
SCRIPT1="$RUN_DIR/script1.txt"
printf 'exec WASM.BIN FLOATAPP.WASM\necho rx-w4-float\nexec WASM.BIN FILEAPP.WASM\necho rx-w3-file\nexec WASM.BIN HELLO.WASM\necho rx-wasm-hello\nexec WASM.BIN WC.WASM\necho rx-w5-wc\nexec WASM.BIN WINAPP.WASM\necho rx-w3-win\n' > "$SCRIPT1"
SCRIPT2="$RUN_DIR/script2.txt"
# Arc4 #239 fades windows in over 2x2 composites (25%% x2, 50%% x2, then
# opaque), so the marker screenshot must fire after a few composite
# commands — raise/move both composite unconditionally and keep the
# window at (100,100,96,48), so the final `rx-wasm-ok` marker (capture
# trigger) lands after 5 composites and the scanout shows it opaque.
printf 'dui\necho rx-w3-dui\ndui raise 2\necho rx-w3-raised\ndui move 2 100 100\necho rx-w3-moved\ndui raise 2\necho rx-w3-raised2\ndui move 2 100 100\necho rx-w3-moved2\ndui raise 2\necho rx-w3-raised3\ndui\necho rx-w3-dui\necho rx-wasm-ok\n' > "$SCRIPT2"

run_one() {
    local tag="$1"
    local run_log="$(art live-wasm-run-$tag.txt)"
    local serial_copy="$(art live-wasm-serial-$tag.log)"
    rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial-$tag.log" "$RUN_DIR"/gpu-screen-*s "$RUN_DIR"/gpu-screen-after

    set +e
    host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
        --cvc-file "$SHARE" \
        --serial "$RUN_DIR/vm-serial-$tag.log" \
        --display --screen "$RUN_DIR/gpu-screen" \
        --script "$SCRIPT1" --script-after "$STATIC_EXIT_LINE" \
        --script2 "$SCRIPT2" --script2-after "w3: win ok" \
        --screenshot-after "rx-wasm-ok" \
        --timeout 120 > "$run_log" 2>&1
    local rc=$?
    set -e
    [ -f "$RUN_DIR/vm-serial-$tag.log" ] && cp "$RUN_DIR/vm-serial-$tag.log" "$serial_copy" || true
    cp "$RUN_DIR"/gpu-screen-*s artifacts/ 2>/dev/null || true
    [ -f "$RUN_DIR/gpu-screen-after" ] && cp "$RUN_DIR/gpu-screen-after" "$(art "gpu-screen-after-$tag.png")" || true
    local SER="$serial_copy"

    local bytes=0 banner=0 hello=0 exit55=0 heck0=0 winid=0 winok=0 win21=0 drow=0 file512=0 fileecho=0 float590=0 float1=0 float2=0 float3=0 float4=0 float5=0 heck4=0 wcline=0 wcexit=0 wcresp=0 ok=0 fatal=0 blitok=0
    if [ -f "$SER" ]; then
        bytes="$(wc -c < "$SER" | tr -d ' ')"
        [ "$(grep -aFxc -- "VirelaiOS kernel has seized control." "$SER" || true)" = 1 ] && banner=1
        [ "$(grep -aFxc -- "$HELLO_LINE" "$SER" || true)" -ge 1 ] && hello=1
        [ "$(grep -aFxc -- "$WASM_EXIT_LINE" "$SER" || true)" -ge 1 ] && exit55=1
        [ "$(grep -aFxc -- "rx-wasm-hello" "$SER" || true)" -ge 1 ] && heck0=1
        [ "$(grep -aE -- "w3: win open=[2-5]" "$SER" | wc -l | tr -d ' ')" -ge 1 ] && winid=1
        [ "$(grep -aFxc -- "$WIN_OK_LINE" "$SER" || true)" -ge 1 ] && winok=1
        [ "$(grep -aFxc -- "$WIN_EXIT_LINE" "$SER" || true)" -ge 1 ] && win21=1
        [ "$(grep -aF -- "rect=100,100,96,48" "$SER" | wc -l | tr -d ' ')" -ge 1 ] && drow=1
        [ "$(grep -aFxc -- "$FILE_EXIT_LINE" "$SER" || true)" -ge 1 ] && file512=1
        [ "$(grep -aFc -- "w3-filerocks!!!" "$SER" || true)" -ge 1 ] && fileecho=1
        [ "$(grep -aFxc -- "$FLOAT_EXIT_LINE" "$SER" || true)" -ge 1 ] && float590=1
        # W4 float-app output: distinctive byte-exact lines, one per opcode
        # family — f64 arith+mC loop, f64 bit-pattern hex, saturating
        # trunc rounding, f32 path, i64.extend_i32_s. (The host test holds
        # the full 590-byte byte-exact proof; these prove the SAME binary
        # executes through the live boot.)
        [ "$(grep -aFxc -- "mC 100000 = 212.00" "$SER" || true)" -ge 1 ] && float1=1
        [ "$(grep -aFxc -- "bits64 c2f 21.50 = 4051accccccccccd" "$SER" || true)" -ge 1 ] && float2=1
        [ "$(grep -aFxc -- "f2c 98.60 = 37.00" "$SER" || true)" -ge 1 ] && float3=1
        [ "$(grep -aFxc -- "f32 f2c -4.00 = -20.00" "$SER" || true)" -ge 1 ] && float4=1
        [ "$(grep -aFxc -- "sext chk = -66" "$SER" || true)" -ge 1 ] && float5=1
        [ "$(grep -aFxc -- "rx-w4-float" "$SER" || true)" -ge 1 ] && heck4=1
        # W5 capstone: the byte-exact wc line + the exit-status length
        # proof + the shell staying responsive.
        [ "$(grep -aFxc -- "$WC_LINE" "$SER" || true)" -ge 1 ] && wcline=1
        [ "$(grep -aFxc -- "$WC_EXIT_LINE" "$SER" || true)" -ge 1 ] && wcexit=1
        [ "$(grep -aFxc -- "rx-w5-wc" "$SER" || true)" -ge 1 ] && wcresp=1
        [ "$(grep -aFxc -- "rx-wasm-ok" "$SER" || true)" = 1 ] && ok=1
        [ "$(grep -aEc -- "dui: windows=[4-9].*blits=[1-9][0-9]*" "$SER" || true)" -ge 1 ] && blitok=1
        for n in "${FAIL_NEEDLES[@]}"; do
            if grep -aFq -- "$n" "$SER"; then fatal=1; break; fi
        done
    fi

    echo "run $tag: rc=$rc bytes=$bytes banner=$banner hello=$hello exit55=$exit55 helloresp=$heck0 winid=$winid winok=$winok win21=$win21 duirow=$drow file512=$file512 fileecho=$fileecho float590=$float590 float1=$float1 float2=$float2 float3=$float3 float4=$float4 float5=$float5 floatresp=$heck4 wcline=$wcline wcexit=$wcexit wcresp=$wcresp finalresp=$ok blits=$blitok fatal=$fatal"

    local PASS=0
    if [ $banner -eq 1 ] && [ $hello -eq 1 ] && [ $exit55 -eq 1 ] && [ $heck0 -eq 1 ] && \
       [ $winid -eq 1 ] && [ $winok -eq 1 ] && [ $win21 -eq 1 ] && [ $drow -eq 1 ] && \
       [ $file512 -eq 1 ] && [ $fileecho -eq 1 ] && [ $float590 -eq 1 ] && \
       [ $float1 -eq 1 ] && [ $float2 -eq 1 ] && [ $float3 -eq 1 ] && [ $float4 -eq 1 ] && [ $float5 -eq 1 ] && \
       [ $heck4 -eq 1 ] && [ $wcline -eq 1 ] && [ $wcexit -eq 1 ] && [ $wcresp -eq 1 ] && \
       [ $ok -eq 1 ] && [ $blitok -eq 1 ] && [ $fatal -eq 0 ] && [ $rc -eq 0 ]; then
        PASS=1
    fi

    # The pixel proof — the winapp's 0xFF0000 fill, observed via the
    # scanout captures (2560x1440 retina = 2x the 1280x720 scanout; the
    # window sits at logical 100,100,96,48). The winapp's window is only
    # blitted into the scanout after the gate's `dui raise 2` triggers the
    # composite (post-WMS the kernel does not composite user windows
    # unprompted), so the red block appears in whichever capture lands
    # inside the app's ~12s hold — scan ALL captures and accept any hit.
    local REDOK=0
    local CAPS="$(ls -t artifacts/gpu-screen-*s artifacts/gpu-screen-after-*.png 2>/dev/null | tr '\n' ' ' || true)"
    if [ -n "$CAPS" ]; then
        echo "decoding captures: $CAPS for the red fill"
        python3 - $CAPS <<'EOF'
import sys, zlib, struct
def decode(path):
    d = open(path, 'rb').read()
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
                b = prev[x]
                c = prev[x-bpp] if x >= bpp else 0
                p = a + b - c
                pa, pb, pc = abs(p-a), abs(p-b), abs(p-c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[x] = (line[x] + pr) & 0xff
        out += line
        prev = line
    return w, h, bpp, out
# The winapp's 0xFF0000 body — rendered ~90% alpha below its title
# chrome, so fixed-point sampling is brittle; assert instead that SOME
# capture carries an LARGE CONTIGUOUS red component (the window body) in
# the top-left quadrant where the app opened it (2x retina: logical
# 100,100,96,48 plus chrome allowance). Measured on the live gate:
# 10,436 px in one component, 180 wide x 58 tall.
def largest_red_component(out, w, h, bpp, x0, y0, x1, y1):
    def px(x, y):
        o = (y * w + x) * bpp
        return out[o], out[o+1], out[o+2]
    mask = set()
    for y in range(y0, y1):
        for x in range(x0, x1):
            r, g, b = px(x, y)
            if r > 170 and g < 110 and b < 110:  # alpha-blended 0xFF0000
                mask.add((x, y))
    best = 0
    todo = list(mask)
    while todo:
        seed = todo.pop()
        comp = {seed}
        stack = [seed]
        while stack:
            cx, cy = stack.pop()
            for nx, ny in ((cx+1, cy), (cx-1, cy), (cx, cy+1), (cx, cy-1)):
                if (nx, ny) in mask and (nx, ny) not in comp:
                    comp.add((nx, ny))
                    stack.append((nx, ny))
        if len(comp) > best: best = len(comp)
    return best
best = 0
for path in sys.argv[1:]:
    try:
        w, h, bpp, out = decode(path)
    except Exception:
        continue
    best = max(best, largest_red_component(out, w, h, bpp, 150, 150, 450, 350))
print(f"red fill: largest contiguous red block = {best} px across {len(sys.argv)-1} captures")
sys.exit(0 if best >= 4000 else 1)
EOF
        local redrc=$?
        [ $redrc -eq 0 ] && REDOK=1
    else
        echo "no gpu-screen capture — red fill NOT proven"
    fi
    echo "redfill=$REDOK"

    if [ $PASS -eq 1 ] && [ "${REDOK:-0}" -eq 1 ]; then
        echo "PASS $tag: hello (write byte-exact, exit 55) + wasm window app (dui row rect=100,100,96,48, blits>=1 post-raise, red fill block in the marker capture) + wasm file app (FILE.TXT echoed byte-exact, exit 512) + wasm float app (FLOATAPP.WASM: five float opcode families byte-exact, exit 590) + the wc capstone (WC.WASM: 8 lines 32 words 320 bytes byte-exact, exit 320 — a real tool ported to wasm, shipped as an HF4 app) — virelai.h contract proven live" | tee -a "$REPORT"
        return 0
    fi
    echo "FAIL $tag: see $SER and $run_log" | tee -a "$REPORT"
    return 1
}

status=0
for b in $(seq 1 "$BOOTS"); do
    run_one "boot$b" || status=1
done
exit $status