# go-calc.spec -- Go calculator (CALC.BIN successor, issue #1378) class-B
# gate: a Go integer calc opens full-viewport inside Zig TABWM, types a short
# expression, and reports the result.
#
# user/go/calc is a tabapp client: init -> declare (kind-8 WM_RPC) -> present
# -> accept injected keystrokes (Win_DOWN arg1 is the Unicode codepoint) ->
# evaluate -> write /host/CALC/RESULT.TXT -> WIN_CLOSE exits. Zig CALC.BIN
# stays; kernel untouched. Not CALC's programmer-mode feature list.
#
# The load-bearing evidence is NOT only the app's own markers: the run's last
# assert reads the share file back ON THE HOST and requires it to equal the
# typed expression plus the result, so a stub that printed success without
# doing the arithmetic cannot pass.
#
# HOST PREREQUISITE (fails the gate honestly when missing):
#   bash tools/go/build-gocalc.sh   ->  .build/go/GOCALC.ELF
#
# exec-order: assert-proven -- the run ends on `rx-gocalc-ok`, which only the
# script prints, and the stage gate that forwards the close waits on the app's
# own `gocalc: result `; a program that never ran cannot pass.

vgate_name go-calc "issue #1378: a Go integer calc evaluates a short expression in Zig TABWM on VZ"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script.txt <<'EOF'
tabwm
tabwm start
EOF

vgate_file script2.txt <<'EOF'
exec GOCALC.ELF
EOF

# The close is driven from the harness after the app's own `gocalc: result `
# (the stage gate), so the bytes are on the share before the window closes.
vgate_file script3.txt <<'EOF'
dui close 2
echo rx-gocalc-ok
EOF

vgate_setup_python <<'PY'
import os, shutil, sys
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
src = os.path.join(".build", "go", "GOCALC.ELF")
if not os.path.exists(src):
    sys.exit("GOCALC.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-gocalc.sh")
shutil.copy(src, os.path.join(share, "GOCALC.ELF"))
calc = os.path.join(share, "CALC")
os.makedirs(calc, exist_ok=True)
print("staged GOCALC.ELF into share (%d bytes) and %s" %
      (os.path.getsize(os.path.join(share, "GOCALC.ELF")), calc))
PY

# HID chord vocabulary maps '-', '/', '=', digits, and return — not '+' or
# '*' as single tokens (those still work from a real keyboard via shift).
# 12-3=9 is the short expression this run types.
vgate_run 01 -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio \
    --script '$RUN_DIR/script.txt' \
    --script2 '$RUN_DIR/script2.txt' \
    --script2-after 'tabwm: sidebar-rendered' \
    --input-chords '1,2,-,3,=' \
    --input-chords-after 'gocalc: present' \
    --script3 '$RUN_DIR/script3.txt' \
    --script3-after 'gocalc: result ' \
    --script-expect 'rx-gocalc-ok' --timeout 240

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'tabwm: starting TABWM.BIN'
vgate_assert 01 serial-contains 'tabwm: registered'
vgate_assert 01 serial-contains 'tabwm: sidebar-rendered'
vgate_assert 01 serial-contains 'exec: loaded GOCALC.ELF'
vgate_assert 01 serial-contains 'gocalc: open id='
vgate_assert 01 serial-contains 'gocalc: declare accepted'
vgate_assert 01 serial-contains 'gocalc: present'
vgate_assert 01 serial-contains 'gocalc: result 12-3=9'
vgate_assert 01 serial-contains 'gocalc: close'
vgate_assert 01 serial-contains 'gocalc OK'
vgate_assert 01 serial-contains 'rx-gocalc-ok'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 serial-absent 'exited status=139'

# The load-bearing assert: the share file on the HOST must now hold exactly
# the typed expression plus the result. A marker that reported success
# without writing the bytes cannot pass this.
vgate_assert 01 python <<'PY'
import os
share = os.environ["VG_SHARE"]
path = os.path.join(share, "CALC", "RESULT.TXT")
want = b"12-3=9\n"
got = open(path, "rb").read()
if got != want:
    print("RESULT CONTENT MISMATCH: got %r want %r" % (got, want))
    raise SystemExit(1)
print("result verified on the host: %r (%d bytes)" % (got, len(got)))
PY
