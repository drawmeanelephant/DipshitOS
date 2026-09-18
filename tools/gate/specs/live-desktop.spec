# live-desktop.spec -- claim 2427 (Milestone 11, Card A5) Desktop Platform & GUI Apps (ADR 0011)
#
# M62h: Zig CALC.BIN is gone. Return on the menu launches catalog[0] from
# APPS.TXT, which is now GOCALC.ELF (tabapp: present even if declare is
# refused under DESKTOP.BIN rather than a tab WM).
vgate_name live-desktop "Milestone 11 Desktop Platform & GUI Apps"
vgate_share seed
# GF6 closeout (issue #1020): seed arms the host file channel, whose
# --cvc-file implies the full custom-virtio device shape — SPIKE-only.
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script.txt <<'EOF'
exec NOTEPAD.BIN
exec TOP.BIN
exec DESKTOP.BIN
EOF

vgate_file script2.txt <<'EOF'
procs
syscalls
echo done-desktop-sweep
EOF

vgate_setup_python <<'PY'
import os, shutil, sys
share = os.environ.get("VG_SHARE") or os.path.join(os.environ["RUN_DIR"], "share")
src = os.path.join(".build", "go", "GOCALC.ELF")
if not os.path.exists(src):
    sys.exit("GOCALC.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-gocalc.sh")
shutil.copy(src, os.path.join(share, "GOCALC.ELF"))
print("staged GOCALC.ELF into share (%d bytes)" %
      os.path.getsize(os.path.join(share, "GOCALC.ELF")))
PY

vgate_run A -- \
    --display --input --screen '$RUN_DIR/gpu-screen' \
    --script '$RUN_DIR/script.txt' \
    --script-after "tasks user-el0 exited status=7" \
    --input-chords "return" \
    --input-chords-after "desktop: menu ready" \
    --script2 '$RUN_DIR/script2.txt' \
    --script2-after "gocalc: present" \
    --script-expect "done-desktop-sweep" \
    --timeout 180

vgate_assert A serial-contains "gocalc: present"
vgate_assert A serial-contains "notepad: ready"
vgate_assert A serial-contains "top: ready"
vgate_assert A serial-contains "desktop: ready"
vgate_assert A serial-contains "desktop: menu ready"
vgate_assert A serial-contains "desktop: manifest apps="
vgate_assert A serial-contains "desktop: launch GOCALC.ELF"
vgate_assert A serial-contains "28 sys_exec calls=1"
vgate_assert A serial-contains "done-desktop-sweep"
vgate_assert A serial-absent "[EXC] parking:"
