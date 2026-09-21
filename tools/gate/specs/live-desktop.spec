# live-desktop.spec -- claim 2427 (Milestone 11, Card A5) Desktop Platform & GUI Apps (ADR 0011)
#
# M62h: Zig CALC.BIN is gone. Return on the menu launches catalog[0] from
# APPS.TXT, which is now GOCALC.ELF (tabapp: present even if declare is
# refused under DESKTOP.BIN rather than a tab WM).
# M66c (#1485): the Zig notepad is retired too; the text client is NOTE.ELF
# (Go), staged alongside GOCALC.ELF. Only its `notepad:`->`note:` prefix moved.
vgate_name live-desktop "Milestone 11 Desktop Platform & GUI Apps"
vgate_share seed
# GF6 closeout (issue #1020): seed arms the host file channel, whose
# --cvc-file implies the full custom-virtio device shape — SPIKE-only.
vgate_runner_flags -Xswiftc -DSPIKE

# M66c (#1485): the CLIENT execs first and the desktop LAST, or the desktop
# never holds focus. The Return chord below goes to the FOCUSED window, and
# NOTE.ELF's window lands after DESKTOP's (the Go runtime start is slower
# than a Zig app's open), so exec'ing all three in one burst left NOTE.ELF
# focused and the menu chord went to it (observed: `desktop: menu ready`, the
# chord typed, no launch). Waiting on the client's own READY marker before the
# other two exec is what makes DESKTOP's window the newest — and therefore the
# focused — one.
#
# M71g (#1566) MEASURED the same race in the other direction and fixed it: with
# GOTOP.ELF (Go) exec'd in the same burst as the Zig DESKTOP.BIN, the GO window
# landed LAST — `open: id=3 owner=3` (DESKTOP) then `open: id=4 owner=2`
# (GOTOP), so GOTOP held focus and the Return chord went to the task manager
# (observed: `desktop: menu ready`, chord typed, `desktop: launch GOCALC.ELF`
# zero times, run timed out). The two Go clients therefore exec in the FIRST
# burst (their order follows exec order, and neither can steal focus from a
# window that opens later), and DESKTOP.BIN waits for NOTE.ELF's own `note:
# ready`. Focus itself is not re-asserted: `desktop: launch GOCALC.ELF` is
# printed only by DESKTOP's own menu handler, so a chord delivered to any other
# window leaves it absent and the run fails — the launch marker IS the
# focus proof (there is no free script stage to snapshot `dui` before it).
vgate_file script.txt <<'EOF'
exec GOTOP.ELF
exec NOTE.ELF
EOF

# DESKTOP.BIN is exec'd only once both Go clients are up: a Zig window opened
# after a Go window is the newest, which is what focus follows.
vgate_file script2.txt <<'EOF'
exec DESKTOP.BIN
EOF

vgate_file script3.txt <<'EOF'
procs
syscalls
echo done-desktop-sweep
EOF

vgate_setup_python <<'PY'
import os, shutil, sys
share = os.environ.get("VG_SHARE") or os.path.join(os.environ["RUN_DIR"], "share")
apps = (("NOTE.ELF", "build-note.sh"), ("GOCALC.ELF", "build-gocalc.sh"))
for name, script in apps:
    src = os.path.join(".build", "go", name)
    if not os.path.exists(src):
        sys.exit("%s missing (expected %s) - build it first: bash tools/go/%s"
                 % (name, src, script))
    shutil.copy(src, os.path.join(share, name))
    print("staged %s into share (%d bytes)"
          % (name, os.path.getsize(os.path.join(share, name))))
PY

# HOST PREREQUISITE (fails the gate honestly when missing):
#   bash tools/go/build-gotop.sh   ->  .build/go/GOTOP.ELF
vgate_setup_python <<'PY'
import os, shutil, sys
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
src = os.path.join(".build", "go", "GOTOP.ELF")
if not os.path.exists(src):
    sys.exit("GOTOP.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-gotop.sh")
shutil.copy(src, os.path.join(share, "GOTOP.ELF"))
print("staged GOTOP.ELF into share (%d bytes)" % os.path.getsize(os.path.join(share, "GOTOP.ELF")))
PY

vgate_run A -- \
    --display --input --screen '$RUN_DIR/gpu-screen' \
    --script '$RUN_DIR/script.txt' \
    --script-after "tasks user-el0 exited status=7" \
    --script2 '$RUN_DIR/script2.txt' --script2-after "note: ready" \
    --input-chords "return" \
    --input-chords-after "desktop: menu ready" \
    --script3 '$RUN_DIR/script3.txt' \
    --script3-after "gocalc: present" \
    --script-expect "done-desktop-sweep" \
    --timeout 180

vgate_assert A serial-contains "gocalc: present"
vgate_assert A serial-contains "note: ready"
vgate_assert A serial-contains "top: ready"
vgate_assert A serial-contains "desktop: ready"
vgate_assert A serial-contains "desktop: menu ready"
vgate_assert A serial-contains "desktop: manifest apps="
vgate_assert A serial-contains "desktop: launch GOCALC.ELF"
vgate_assert A serial-contains "28 sys_exec calls=1"
vgate_assert A serial-contains "done-desktop-sweep"
vgate_assert A serial-absent "[EXC] parking:"
