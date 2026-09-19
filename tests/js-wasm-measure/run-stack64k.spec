# Control: same Elk driver, wasm-ld C stack 64 KiB instead of 8 KiB.
# NOT a fleet member. Observed 2026-09-19: still traps (exit 3). The 8 KiB
# stack is falsified as the cause; remaining inference is max_frames=32.
#
#   STACK_SIZE=65536 bash tests/js-wasm-measure/measure.sh
#   VGATE_NO_BUILD=1 bash tools/gate/vgate.sh tests/js-wasm-measure/run-stack64k.spec

vgate_name live-browser-js-stack64k "M70d #1456: Elk stack-size=64KiB control still traps"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE
vgate_repeat 1 BOOTS

vgate_file script.txt <<'EOF'
exec WASM.BIN ELK.WASM
echo rx-elk
EOF

vgate_setup_python <<'PY'
import os, shutil, sys

run_dir = os.environ["RUN_DIR"]
share = os.path.join(run_dir, "share")
os.makedirs(share, exist_ok=True)

wasm_bin = "zig-out/bin/WASM.BIN"
if not os.path.exists(wasm_bin):
    sys.exit("ERROR: zig-out/bin/WASM.BIN missing — zig build first")
shutil.copy(wasm_bin, os.path.join(share, "WASM.BIN"))

elk = "artifacts/js-wasm-measure/build/elk-stack65536.wasm"
if not os.path.exists(elk):
    sys.exit("ERROR: " + elk + " missing — STACK_SIZE=65536 bash tests/js-wasm-measure/measure.sh")
shutil.copy(elk, os.path.join(share, "ELK.WASM"))
PY

vgate_run 01 -- --script '$RUN_DIR/script.txt' --script-after "tasks user-el0 exited status=7" --script-expect "wasm: trap during exec" --timeout 90

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'wasm: trap during exec'
vgate_assert 01 serial-contains 'tasks user-exec exited status=3'
vgate_assert 01 serial-absent 'wasm: module too large'
vgate_assert 01 serial-absent 'wasm: parse error'
vgate_assert 01 serial-absent 'wasm: validate error'
vgate_assert 01 serial-absent 'wasm: instantiate trap'
vgate_assert 01 serial-absent '[EXC] parking:'
