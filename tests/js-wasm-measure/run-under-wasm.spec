# One-shot VZ measurement: the Elk module inspects clean, then traps.
# NOT a fleet member. Reproduce:
#   bash tests/js-wasm-measure/measure.sh
#   VGATE_NO_BUILD=1 bash tools/gate/vgate.sh tests/js-wasm-measure/run-under-wasm.spec
#
# Observed 2026-09-19: `exec WASM.BIN ELK.WASM` prints `wasm: trap during exec`
# and exits 3. Control with `-Wl,-z,stack-size=65536` still traps (see
# run-stack64k.spec), so the 8 KiB C stack is not the cause. Remaining
# inference: `max_frames = 32`.

vgate_name live-browser-js-measure "M70d #1456: Elk under WASM.BIN traps (measurement)"
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

elk = "artifacts/js-wasm-measure/build/elk.wasm"
if not os.path.exists(elk):
    sys.exit("ERROR: " + elk + " missing — bash tests/js-wasm-measure/measure.sh")
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
