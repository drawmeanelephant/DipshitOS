# go-term.spec -- M58c (issue #1307) class-B gate: a Go terminal window opens
# over the existing /dev/tty seam, attaches selector 2, types a line, and
# closes, full-viewport inside Zig TABWM.
#
# user/go/term is a tabapp client: init -> declare (kind-8 WM_RPC) -> open
# /dev/tty -> sys_tty_attach(2, window_id) -> write a prompt through the tty
# (kernel-painted grid, ADR 0020 A4) -> accept injected keystrokes into the
# terminal input queue (A5) -> echo the line -> WIN_CLOSE detaches and exits.
# Zig TERM.BIN / SH.BIN are untouched; kernel untouched; no second renderer.
#
# HOST PREREQUISITE (fails the gate honestly when missing):
#   bash tools/go/build-goterm.sh   ->  .build/go/GOTERM.ELF
#
# exec-order: assert-proven -- the run ends on `rx-goterm-ok`, which only the
# script prints, and the stage gate that forwards the close waits on the app's
# own `goterm: line `; a program that never ran cannot pass.

vgate_name go-term "issue #1307 M58c: a Go terminal attaches /dev/tty selector 2 in Zig TABWM on VZ"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script.txt <<'EOF'
tabwm
tabwm start
EOF

vgate_file script2.txt <<'EOF'
exec GOTERM.ELF
EOF

# The close is driven from the harness after the app's own `goterm: line `
# (the stage gate), so the typed line reached the tty before the window closes.
vgate_file script3.txt <<'EOF'
dui close 2
echo rx-goterm-ok
EOF

vgate_setup_python <<'PY'
import os, shutil, sys
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
src = os.path.join(".build", "go", "GOTERM.ELF")
if not os.path.exists(src):
    sys.exit("GOTERM.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-goterm.sh")
shutil.copy(src, os.path.join(share, "GOTERM.ELF"))
print("staged GOTERM.ELF into share (%d bytes)" %
      os.path.getsize(os.path.join(share, "GOTERM.ELF")))
PY

vgate_run 01 -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio \
    --script '$RUN_DIR/script.txt' \
    --script2 '$RUN_DIR/script2.txt' \
    --script2-after 'tabwm: sidebar-rendered' \
    --input-chords 'e,c,h,o,space,h,i,return' \
    --input-chords-after 'goterm: prompt' \
    --script3 '$RUN_DIR/script3.txt' \
    --script3-after 'goterm: line ' \
    --script-expect 'rx-goterm-ok' --timeout 240

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'tabwm: starting TABWM.BIN'
vgate_assert 01 serial-contains 'tabwm: registered'
vgate_assert 01 serial-contains 'tabwm: sidebar-rendered'
vgate_assert 01 serial-contains 'exec: loaded GOTERM.ELF'
vgate_assert 01 serial-contains 'goterm: open id='
vgate_assert 01 serial-contains 'goterm: declare accepted'
vgate_assert 01 serial-contains 'goterm: tty'
vgate_assert 01 serial-contains 'goterm: attached'
# Prompt bytes went through /dev/tty so the kernel has something to paint.
vgate_assert 01 serial-contains 'goterm: prompt'
# The injected keystrokes reached the tty input queue and submitted a line.
vgate_assert 01 serial-contains 'goterm: line echo hi'
vgate_assert 01 serial-contains 'goterm: close'
vgate_assert 01 serial-contains 'goterm OK'
vgate_assert 01 serial-contains 'rx-goterm-ok'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 serial-absent 'exited status=139'
