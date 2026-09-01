#!/usr/bin/env bash
#
# verify-live-wasm.sh -- M35 W2 (issue #763) class-B gate: the vertical
# proof — `exec WASM.BIN <file>` reads a wasm module through the M34 file
# channel, the interpreter runs it, and its output is observed on the
# console — with a host-built C hello-world.
#
# The chain, all asserted in vm-serial.log:
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
#   4. `tasks user-exec exited status=55` proves the observed exit.
#   5. The shell stays responsive (the rx-wasm-ok echo after).
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
WASM_MARKER="hello, wasm!"          # the module's own write, byte-exact
FAIL_NEEDLES=("wasm: open failed" "wasm: parse error" "wasm: validate error" "wasm: mmap failed" "wasm: trap")

echo "=== verify-live-wasm: M35 W2 — C hello-world runs in-guest via the wasm interpreter, $BOOTS boot(s) ==="
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
swift build --package-path host/vm-runner --configuration release -Xswiftc -DSPIKE
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner

gate_begin live-wasm
echo "run dir: $RUN_DIR"

# --- the share: the interpreter app + the host-built C hello-world ---
SHARE="$RUN_DIR/share"
mkdir -p "$SHARE"
cp zig-out/bin/WASM.BIN "$SHARE/WASM.BIN"
echo "WASM.BIN: $(wc -c < "$SHARE/WASM.BIN" | tr -d ' ') bytes dropped into the share (zig build wasm)"

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

# --- guest script ---
SCRIPT="$RUN_DIR/script.txt"
printf 'exec WASM.BIN HELLO.WASM\necho rx-wasm-ok\n' > "$SCRIPT"

run_one() {
    local tag="$1"
    local run_log="$(art live-wasm-run-$tag.txt)"
    local serial_copy="$(art live-wasm-serial-$tag.log)"
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

    local bytes=0 banner=0 hello=0 exit55=0 echo_ok=0 fatal=0
    if [ -f "$SER" ]; then
        bytes="$(wc -c < "$SER" | tr -d ' ')"
        [ "$(grep -aFxc -- "VirelaiOS kernel has seized control." "$SER" || true)" = 1 ] && banner=1
        [ "$(grep -aFxc -- "$HELLO_LINE" "$SER" || true)" -ge 1 ] && hello=1
        [ "$(grep -aFxc -- "$WASM_EXIT_LINE" "$SER" || true)" -ge 1 ] && exit55=1
        [ "$(grep -aFxc -- "rx-wasm-ok" "$SER" || true)" = 1 ] && echo_ok=1
        for n in "${FAIL_NEEDLES[@]}"; do
            if grep -aFq -- "$n" "$SER"; then fatal=1; break; fi
        done
    fi

    echo "run $tag: rc=$rc bytes=$bytes banner=$banner hello=$hello exit55=$exit55 echo=$echo_ok fatal=$fatal"
    if [ $banner -eq 1 ] && [ $hello -eq 1 ] && [ $exit55 -eq 1 ] && [ $echo_ok -eq 1 ] && [ $fatal -eq 0 ] && [ $rc -eq 0 ]; then
        echo "PASS $tag: the C hello-world ran in-guest — write byte-exact, exit status 55, shell alive" | tee -a "$REPORT"
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
