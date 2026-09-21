# go-top.spec -- M71g (issue #1566) class-B gate: GOTOP.ELF lists a live
# process, kills it with `k`, and closes -- full-viewport inside Zig TABWM.
#
# user/go/top is a tabapp client: init -> declare (kind-8 WM_RPC) -> sys_procs
# (slot 7) -> paint -> `k` arms the selected pid through sys_kill (slot 29) ->
# the kernel converts it into the reserved status 137 -> window close.
#
# The card's D2 is "kill is the live proof, not a pretty chart", so this spec
# proves the kill against a process it first listed by NAME (the pid is read
# out of GOTOP's own row line, not pinned, so the boot's pid allocation stays
# free to move). GOTOP.ELF is the successor to Zig TOP.BIN and SYSMON.BIN, both
# deleted by this card; it keeps TOP's `top:` marker vocabulary and its
# 40,40 512x384 declaration, so the retargeted live-* specs moved by binary
# name.
#
# exec-order: assert-proven -- the run ends on `rx-gotop-ok`, which only the
# script prints, and the stage gate that forwards the close waits on the
# kernel's own `tasks user-exec exited status=137` (the kill's consequence),
# so a boot in which the kill never landed cannot reach the echo.
#
# HOST PREREQUISITE (fails the gate honestly when missing):
#   bash tools/go/build-gotop.sh   ->  .build/go/GOTOP.ELF

vgate_name go-top "issue #1566 M71g: GOTOP.ELF lists a live pid and kills it in Zig TABWM on VZ"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script.txt <<'EOF'
tabwm
tabwm start
EOF

vgate_file script2.txt <<'EOF'
exec COUNTER.BIN
exec GOTOP.ELF
EOF

# The close is driven from the harness only AFTER the kernel has reported the
# killed process's exit, so both the kill and its consequence are on the serial
# log before the window goes away. `procs` is the kernel's OWN table read-back:
# the killed pid must show exited/137 there, which is what makes the kill more
# than a marker.
vgate_file script3.txt <<'EOF'
procs
dui close 2
echo rx-gotop-ok
EOF

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

vgate_run 01 -- \
    --screen '$RUN_DIR/screen' \
    --script '$RUN_DIR/script.txt' \
    --script2 '$RUN_DIR/script2.txt' \
    --script2-after 'tabwm: sidebar-rendered' \
    --input-string 'k' \
    --input-string-after 'top: ready' \
    --script3 '$RUN_DIR/script3.txt' \
    --script3-after 'tasks user-exec exited status=137' \
    --script-expect 'rx-gotop-ok' --timeout 150

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'tabwm: registered'
vgate_assert 01 serial-contains 'tabwm: sidebar-rendered'
vgate_assert 01 serial-contains 'exec: loaded GOTOP.ELF'
vgate_assert 01 serial-contains 'top: open id='
vgate_assert 01 serial-contains 'top: tab-aware (full-viewport)'
vgate_assert 01 serial-contains 'top: procs n='
vgate_assert 01 serial-contains 'name=COUNTER.BIN state=running'
vgate_assert 01 serial-contains 'top: kill pid='
vgate_assert 01 serial-contains 'tasks user-exec exited status=137'
vgate_assert 01 serial-contains 'top: refreshed ok'
vgate_assert 01 serial-contains 'top: win_close'
vgate_assert 01 serial-contains 'top: exiting 43'
vgate_assert 01 serial-contains 'rx-gotop-ok'
vgate_assert 01 serial-absent '[EXC] parking:'

# The kill is real: the pid GOTOP ARMED is the pid its own listing showed for
# COUNTER.BIN, the listing came first, and the counter stops afterwards.
vgate_assert 01 python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
lines = ser.splitlines()
listed = next((i for i, l in enumerate(lines)
               if l.startswith("top: row pid=") and "name=COUNTER.BIN state=running" in l), None)
if listed is None:
    sys.exit("FAIL: GOTOP never listed COUNTER.BIN as a running row")
m = re.search(r"top: row pid=(\d+) name=COUNTER\.BIN state=running", lines[listed])
pid = m.group(1)
killed = next((i for i, l in enumerate(lines) if l.strip() == "top: kill pid=" + pid), None)
if killed is None:
    cands = [repr(l) for l in lines if "top: kill" in l]
    sys.exit("FAIL: no exact `top: kill pid=%s` for the listed COUNTER.BIN row; saw: %s"
             % (pid, "; ".join(cands) or "nothing"))
if killed < listed:
    sys.exit("FAIL: the kill preceded the listing it names")
after = sum(1 for l in lines[killed + 1:] if "counter: alive" in l)
if after != 0:
    sys.exit("FAIL: the killed process produced %d markers after the kill" % after)
if not re.search(r"procs: id=%s name=COUNTER\.BIN .*state=exited .*exit=137" % pid, ser):
    sys.exit("FAIL: no exited/137 row for the killed pid %s" % pid)
print("gotop kill ok: listed+armed pid=%s, status 137, no markers after" % pid)
PY
