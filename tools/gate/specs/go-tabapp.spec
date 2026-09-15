# go-tabapp.spec -- M56d (issue #1315) class-B gate: one Go app full-viewport
# inside the Zig TABWM tabbed desktop.
#
# user/go/tabapp (+ user/go/tabapp/demo) is the Go mirror of lib/tabapp.zig:
# init -> declare (kind-8 WM_RPC) -> draw -> present -> dispatch WIN_RESIZE ->
# relayout/redraw -> close. One headless boot arms the GPU, starts TABWM, then
# execs the Go app; TABWM ACCEPTS the declare and hands the tab a WIN_RESIZE on
# activation. Serial markers are the proof; each is printed only after its
# syscall returned.
#
# HOST PREREQUISITE (fails the gate honestly when missing):
#   bash tools/go/build-tabapp.sh   ->  .build/go/GOTABAPP.ELF
#
# exec-order: assert-proven -- the run ends on `rx-gotabapp-ok`, which only the
# script prints, and the stage gate that forwards the close waits on the app's
# own `gotabapp: present`; a program that never ran cannot pass.

vgate_name go-tabapp "issue #1315 M56d: a Go EL0 app full-viewport inside Zig TABWM on VZ"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script.txt <<'EOF'
tabwm
tabwm start
EOF

vgate_file script2.txt <<'EOF'
exec GOTABAPP.ELF
EOF

# The close is driven from the harness after the app's own `gotabapp: present`
# (the stage gate), so the frame is on the scanout before the window closes.
vgate_file script3.txt <<'EOF'
dui close 2
echo rx-gotabapp-ok
EOF

vgate_setup_python <<'PY'
import os, shutil, sys
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
src = os.path.join(".build", "go", "GOTABAPP.ELF")
if not os.path.exists(src):
    sys.exit("GOTABAPP.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-tabapp.sh")
shutil.copy(src, os.path.join(share, "GOTABAPP.ELF"))
print("staged GOTABAPP.ELF into share (%d bytes)" %
      os.path.getsize(os.path.join(share, "GOTABAPP.ELF")))
PY

vgate_run 01 -- \
    --screen '$RUN_DIR/screen' \
    --script '$RUN_DIR/script.txt' \
    --script2 '$RUN_DIR/script2.txt' \
    --script2-after 'tabwm: sidebar-rendered' \
    --script3 '$RUN_DIR/script3.txt' \
    --script3-after 'gotabapp: present' \
    --script-expect 'rx-gotabapp-ok' --timeout 120

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'tabwm: starting TABWM.BIN'
vgate_assert 01 serial-contains 'tabwm: registered'
vgate_assert 01 serial-contains 'tabwm: sidebar-rendered'
vgate_assert 01 serial-contains 'exec: loaded GOTABAPP.ELF'
vgate_assert 01 serial-contains 'gotabapp: open id='
vgate_assert 01 serial-contains 'gotabapp: declare accepted'
vgate_assert 01 serial-contains 'gotabapp: draw'
vgate_assert 01 serial-contains 'gotabapp: present'
vgate_assert 01 serial-contains 'gotabapp: resize'
vgate_assert 01 serial-contains 'gotabapp: close'
vgate_assert 01 serial-contains 'gotabapp OK'
vgate_assert 01 serial-contains 'rx-gotabapp-ok'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 serial-absent 'exited status=139'
