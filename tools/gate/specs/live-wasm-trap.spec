# live-wasm-trap.spec -- M70d #1518: exec traps NAME their class.
#
# #1456 (PR #1517) could not tell `max_frames = 32` from C-stack exhaustion
# because `exec` printed only `wasm: trap during exec`; a 64 KiB stack control
# still trapped, leaving the class off the serial. This spec proves the line
# now carries class + module + the faulting instruction's module byte offset:
# a trivial wasm module whose `_start` is `unreachable` prints
# `kind=unreachable`, names its module, and exits 3. One invocation per boot
# (SPEC.md exec ordering; exit status pins that the named line is a real trap).

vgate_name live-wasm-trap "M70d #1518: WASM.BIN exec traps name class + module + offset"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE
vgate_repeat 1 BOOTS

vgate_file trap.c <<'EOF'
void _start(void) {
    __builtin_trap();
}
EOF

vgate_file script.txt <<'EOF'
exec WASM.BIN TRAP.WASM
echo rx-wasm-trap
EOF

vgate_setup_python <<'PY'
import os, shutil, subprocess, sys

run_dir = os.environ["RUN_DIR"]
share = os.path.join(run_dir, "share")
os.makedirs(share, exist_ok=True)

wasm_bin = "zig-out/bin/WASM.BIN"
if not os.path.exists(wasm_bin):
    sys.exit("ERROR: zig-out/bin/WASM.BIN missing — zig build first")
shutil.copy(wasm_bin, os.path.join(share, "WASM.BIN"))

subprocess.run([
    "zig", "cc", "-target", "wasm32-freestanding", "-nostdlib",
    "-fno-sanitize=undefined", "-g0",
    os.path.join(run_dir, "trap.c"), "-o", os.path.join(share, "TRAP.WASM")
], check=True)
PY

vgate_run 01 -- --script '$RUN_DIR/script.txt' --script-after "tasks user-el0 exited status=7" --script-expect "wasm: trap during exec" --timeout 60

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'wasm: trap during exec kind=unreachable module=TRAP.WASM offset=0x'
vgate_assert 01 serial-contains 'tasks user-exec exited status=3'
vgate_assert 01 serial-absent 'wasm: parse error'
vgate_assert 01 serial-absent 'wasm: validate error'
vgate_assert 01 serial-absent 'wasm: instantiate trap'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 python <<'PY'
import os, re
serial = open(os.environ["VG_SER"], "rb").read()
m = re.search(rb"wasm: trap during exec kind=unreachable module=TRAP\.WASM offset=0x([0-9a-f]+)\n", serial)
if m is None:
    raise SystemExit("named trap line missing or malformed")
if int(m.group(1), 16) == 0:
    raise SystemExit("trap offset is zero -- not the faulting instruction")
PY
