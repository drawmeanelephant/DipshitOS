# live-wasm-abi.spec -- M70e (#1457) contract v2: capability + delivery
# admission, live on Apple Virtualization.framework.
#
# docs/wasm-import-contract.md §9 is the authority. One boot proves the whole
# refusal surface, plus the two paths that must KEEP WORKING:
#
#   * a v2 module with a matching manifest row runs        (TRIO, TICKER)
#   * a v1 module (no `virelai.abi` section) still runs with NO row at all
#     (WC — the additivity promise, the thing every M35 module depends on)
#
# and each §9 refusal is a NAMED error with its own exit status, never a trap:
#
#   HIABI.WASM   virelai.abi=9            -> unsupported revision   exit 14
#   UNDECL.WASM  imports timers, declares  -> undeclared capability  exit 16
#                `debug` only
#   NOROW.WASM   v2, absent from WASM.TXT -> no row                  exit 17
#   TAMPER.WASM  same length and still    -> digest mismatch         exit 19
#                valid, different bytes
#   SIZE.WASM    one benign custom        -> size mismatch           exit 18
#                section appended
#   ESCAL.WASM   row grants `debug`, the  -> capability not granted  exit 21
#                module uses `timer`
#
# Every variant is produced at gate time from the pinned corpus module by
# tools/wasm-manifest.py, so the rows are generated from the exact delivered
# bytes rather than hand-written into this spec.
#
# Host prerequisite: `zig` on PATH (the setup borrows the §7 compile line for
# nothing here — the modules are the checked-in corpus — but `gen`/`stamp` run
# with the same interpreter the project uses).

vgate_name live-wasm-abi "M70e (#1457): contract v2 capability + manifest admission"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE
vgate_repeat 1 BOOTS

vgate_file script.txt <<'EOF'
exec WASM.BIN TRIO.WASM
echo rx-abi-trio
exec WASM.BIN TICKER.WASM
echo rx-abi-ticker
exec WASM.BIN HIABI.WASM
echo rx-abi-hiabi
exec WASM.BIN UNDECL.WASM
echo rx-abi-undecl
exec WASM.BIN NOROW.WASM
echo rx-abi-norow
exec WASM.BIN TAMPER.WASM
echo rx-abi-tamper
exec WASM.BIN SIZE.WASM
echo rx-abi-size
exec WASM.BIN ESCAL.WASM
echo rx-abi-escal
exec WASM.BIN WC.WASM
echo rx-abi-v1
EOF

vgate_setup_python <<'PY'
import os, shutil, subprocess, sys

run_dir = os.environ["RUN_DIR"]
share = os.path.join(run_dir, "share")
os.makedirs(share, exist_ok=True)

def copy_corpus(name, module):
    dst = os.path.join(share, name)
    shutil.copy(os.path.join("user/src/wasm-corpus", module), dst)
    return dst

def stamp(path, text):
    subprocess.run(["python3", "tools/wasm-manifest.py", "stamp", path, text], check=True)

# 1. WASM.BIN + the two v2 author-proof modules + TRIO.TXT (40 bytes, so the
#    app's exit status is a known number: the byte count).
if os.path.exists("zig-out/bin/WASM.BIN"):
    shutil.copy("zig-out/bin/WASM.BIN", os.path.join(share, "WASM.BIN"))
copy_corpus("TRIO.WASM", "trio.wasm")
copy_corpus("TICKER.WASM", "ticker.wasm")
with open(os.path.join(share, "TRIO.TXT"), "wb") as f:
    f.write(b"trio fixture: 40 bytes exactly. 1234abcd")  # exactly 40 B

# 2. The v1 control: a module with no `virelai.abi` section, runnable with no
#    row at all, plus its input file.
copy_corpus("WC.WASM", "wc.wasm")
shutil.copy("tests/wc-fixture.txt", os.path.join(share, "WC.TXT"))

# 3. Generate the manifest for the modules delivered so far: TRIO + TICKER get
#    rows built from their own bytes.
subprocess.run(["python3", "tools/wasm-manifest.py", "gen", share], check=True)

# 4. The refusal variants. Order matters: `gen` refuses a module whose section
#    is malformed, so the manifest is written first and the variants are added
#    after it (a real operator's mistake, reproduced rather than simulated).
manifest = os.path.join(share, "WASM.TXT")
rows = open(manifest).read()

hiabi = copy_corpus("HIABI.WASM", "ticker.wasm")
stamp(hiabi, "virelai.abi=9\\ncapabilities=debug,timer\\n")

undecl = copy_corpus("UNDECL.WASM", "ticker.wasm")
stamp(undecl, "virelai.abi=2\\ncapabilities=debug\\n")

norow = copy_corpus("NOROW.WASM", "ticker.wasm")   # v2, no row written

tamper = copy_corpus("TAMPER.WASM", "ticker.wasm")
size = copy_corpus("SIZE.WASM", "ticker.wasm")
escal = copy_corpus("ESCAL.WASM", "ticker.wasm")

# Their rows, forged from TICKER's row: TAMPER gets a row that matches before
# the flip (so `digest` is the failure, not `no row`), ESCAL gets a row that
# grants less than the module uses.
ticker_row = [l for l in rows.splitlines() if l.startswith("TICKER.WASM")][0]
def row_for(name, line, caps=None):
    parts = [p.strip() for p in line.split("|")]
    parts[0] = name
    if caps is not None:
        parts[4] = "caps=" + caps
    return " | ".join(parts)

extra = [
    row_for("TAMPER.WASM", ticker_row),
    row_for("SIZE.WASM", ticker_row),
    row_for("ESCAL.WASM", ticker_row, caps="debug"),
]
open(manifest, "a").write("\n".join(extra) + "\n")

# TAMPER: edit the module AFTER its row was written while keeping BOTH its
# length and its validity — re-stamp §9.1 with the same capability SET in a
# different order. The delivery is now a different byte string the declaration
# would still accept, so the refusal has to be `digest`. (A structural edit
# would surface as a parse/validate error, and an append as `size`; the three
# cases are deliberately distinct.)
stamp(tamper, "virelai.abi=2\\ncapabilities=timer,debug\\n")

# SIZE: same content plus one appended benign custom section — the loader
# skips custom sections it does not own, so the module stays valid and only
# the length differs from the row.
def uleb(n):
    out = bytearray()
    while True:
        b = n & 0x7F
        n >>= 7
        out.append(b | 0x80 if n else b)
        if not n:
            return bytes(out)

cname = b"extra"
body = uleb(len(cname)) + cname + b"appended after gen"
with open(size, "ab") as f:
    f.write(bytes([0]) + uleb(len(body)) + body)

# 5. The manifest must still verify for everything except TAMPER (which is the
#    point of it) — report the deliberate mismatch rather than failing setup.
r = subprocess.run(["python3", "tools/wasm-manifest.py", "check", share],
                   capture_output=True, text=True)
print(r.stdout.strip())
print(r.stderr.strip(), file=sys.stderr)
PY

# `--script-after` is a FORWARDING GATE (the guest must print it before the
# script is sent) and `--script-expect` ends the run when its marker appears.
# The gate is the boot's own user-el0 line (the marker live-wasm.spec gates on
# too, after the shell is up); the end marker is this script's last echo, so a
# script that never ran cannot pass.
vgate_run 01 -- --display --script '$RUN_DIR/script.txt' --script-after "tasks user-el0 exited status=7" --script-expect "rx-abi-v1" --timeout 180

# --- the v2 module with a row RUNS, and the timer/window/file results are the
#     kernel's answers, not the app's assumptions ---------------------------
vgate_assert 01 serial-contains 'trio: bytes=40'
vgate_assert 01 serial-contains 'trio: win rect=40,40,96,48'
vgate_assert 01 serial-contains 'trio: timers armed=1 canceled=1'
vgate_assert 01 serial-contains 'trio: ok'
vgate_assert 01 serial-contains 'rx-abi-trio'
# NOTE (observed, not a gap in the app): nine execs injected in one script
# produce nine runs but EIGHT `tasks user-exec exited status=` reports — the
# monitor collapses a report when the next run reaps before the previous one
# is drained, and the dropped one is trio's `status=40`. Every refusal's
# report survives, so those statuses are asserted below; trio's byte-count and
# exit-status proof lives in live-wasm.spec, where the runs are staged a phase
# apart and the app's exit line is not racing eight siblings.
vgate_assert 01 serial-contains 'ticker: ok'
vgate_assert 01 serial-contains 'rx-abi-ticker'

# --- §9.1 refusals: named, with their own exit status ---------------------
vgate_assert 01 serial-contains 'wasm: abi: unsupported revision'
vgate_assert 01 serial-contains 'tasks user-exec exited status=14'
vgate_assert 01 serial-contains 'rx-abi-hiabi'
vgate_assert 01 serial-contains 'wasm: abi: undeclared capability'
vgate_assert 01 serial-contains 'tasks user-exec exited status=16'
vgate_assert 01 serial-contains 'rx-abi-undecl'

# --- §9.2 refusals: the delivery is not vouched for ----------------------
vgate_assert 01 serial-contains 'wasm: manifest: no row'
vgate_assert 01 serial-contains 'tasks user-exec exited status=17'
vgate_assert 01 serial-contains 'rx-abi-norow'
vgate_assert 01 serial-contains 'wasm: manifest: digest mismatch'
vgate_assert 01 serial-contains 'tasks user-exec exited status=19'
vgate_assert 01 serial-contains 'rx-abi-tamper'
vgate_assert 01 serial-contains 'wasm: manifest: size mismatch'
vgate_assert 01 serial-contains 'tasks user-exec exited status=18'
vgate_assert 01 serial-contains 'rx-abi-size'
vgate_assert 01 serial-contains 'wasm: manifest: capability not granted'
vgate_assert 01 serial-contains 'tasks user-exec exited status=21'
vgate_assert 01 serial-contains 'rx-abi-escal'

# --- additivity: a v1 module runs with no row, unchanged -----------------
vgate_assert 01 serial-contains '  8  32 320 /host/WC.TXT'
vgate_assert 01 serial-contains 'tasks user-exec exited status=320'
vgate_assert 01 serial-contains 'rx-abi-v1'

# --- and none of this is a trap or a generic parse failure ----------------
vgate_assert 01 serial-absent 'wasm: parse error'
vgate_assert 01 serial-absent 'wasm: validate error'
vgate_assert 01 serial-absent 'wasm: trap'
vgate_assert 01 serial-absent '[EXC] parking:'
