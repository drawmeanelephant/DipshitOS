# go-sh.spec -- M68a (issue #1449) class-B gate: GOSH, the Go shell, hosts
# the M49 daily-use bar as a tabapp window in Zig TABWM. The seeded
# STARTUP.SH drives the scripting subset through the same engine a typed
# line uses: env/variables ($GREET, $?), one pipe, and > redirects -- each
# file read back ON THE HOST so a success marker without bytes cannot pass
# -- a foreground exec of a Go ELF (GOSH itself, headless -c) whose exit
# status is captured through $?, and a background job cycled through
# jobs/fg (the serial markers `gosh: job 1 pid=` / `gosh: job 1 done
# exit=`). Then the harness types at the prompt: a fresh line, a backspace
# edit, and an Up-arrow recall edited with one more character -- each
# visible as a `gosh: line ` marker.
#
# HOST PREREQUISITE (fails the gate honestly when missing):
#   bash tools/go/build-gosh.sh   ->  .build/go/GOSH.ELF
#
# exec-order: assert-proven -- the run ends on `rx-gosh-ok`, which only the
# stage script prints, and the stage gate waits on the editor marker
# `gosh: line echo azx` that only the typed recall can produce; a shell
# that never ran cannot pass.

vgate_name go-sh "issue #1449 M68a: GOSH runs the M49 bar as a tab (exec, pipe, redirect, jobs/fg, editing) on VZ"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script.txt <<'EOF'
tabwm
tabwm start
EOF

vgate_file script2.txt <<'EOF'
exec GOSH.ELF
EOF

# The close is driven from the harness after the typed-history marker, so
# every interactive line reached the shell before the window closes.
vgate_file script3.txt <<'EOF'
dui close 2
echo rx-gosh-ok
EOF

# The startup contract: STARTUP.SH (then PROFILE.SH, absent here) runs
# before the first prompt. `exec` inside GOSH is the monitor vocabulary --
# it runs the named ELF; the -c child form is GOSH's own headless mode
# (no window, no tty, exits with the line's status). Two children, in this
# order: the foreground `exit 7` pins exec+wait status propagation through
# $?; the background `echo nested-child-ok` cycles the job table
# (jobs -> fg) AND proves a child's own console output reaches the serial
# log -- the old `sleep 2` there printed nothing, which is why the
# `nested-child-ok` assert below could never fire. A THIRD
# sequential exec from one EL0 parent currently dies in the Go runtime's
# own schedinit (observed twice: "refill of span with reusable pointers"
# -> fatal exit 2) -- surfaced by this card, documented on #1449, follow-up
# owed to the runtime/kernel owners; this scenario stays at two children
# until that lands.
vgate_file STARTUP.SH <<'EOF'
echo gosh-startup-ran
set GREET=hello-vars
echo V=$GREET > /host/GOSHVARS.TXT
echo alpha-beta | grep alpha > /host/GOSHPIPE.TXT
exec GOSH.ELF -c "exit 7"
echo rc=$? > /host/GOSHRC.TXT
exec GOSH.ELF -c "echo nested-child-ok" &
jobs
fg 1
echo jobrc=$? > /host/GOSHJOB.TXT
EOF

vgate_setup_python <<'PY'
import os, shutil, sys
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
src = os.path.join(".build", "go", "GOSH.ELF")
if not os.path.exists(src):
    sys.exit("GOSH.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-gosh.sh")
shutil.copy(src, os.path.join(share, "GOSH.ELF"))
shutil.copy(os.path.join(rd, "STARTUP.SH"), os.path.join(share, "STARTUP.SH"))
print("staged GOSH.ELF (%d bytes) + STARTUP.SH into share" %
      os.path.getsize(os.path.join(share, "GOSH.ELF")))
PY

# Typed at the prompt -- THREE submitted lines, because `gosh: line ` is
# emitted on submit only: `echo abc` is typed and returned; Up recalls it,
# two backspaces and a z turn it into `echo az`, returned; Up recalls THAT
# and x appends -> `echo azx`, the marker the stage gate waits on.
vgate_run 01 -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio \
    --script '$RUN_DIR/script.txt' \
    --script2 '$RUN_DIR/script2.txt' \
    --script2-after 'tabwm: sidebar-rendered' \
    --input-chords 'e,c,h,o,space,a,b,c,return,up,backspace,backspace,z,return,up,x,return' \
    --input-chords-after 'gosh: prompt' \
    --script3 '$RUN_DIR/script3.txt' \
    --script3-after 'gosh: line echo azx' \
    --script-expect 'rx-gosh-ok' --timeout 240

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'tabwm: starting TABWM.BIN'
vgate_assert 01 serial-contains 'tabwm: registered'
vgate_assert 01 serial-contains 'tabwm: sidebar-rendered'
vgate_assert 01 serial-contains 'exec: loaded GOSH.ELF'
vgate_assert 01 serial-contains 'gosh: ready'
vgate_assert 01 serial-contains 'gosh: open id='
vgate_assert 01 serial-contains 'gosh: declare accepted'
vgate_assert 01 serial-contains 'gosh: tty'
vgate_assert 01 serial-contains 'gosh: attached'
# The startup contract ran before the first prompt; its lines are visible
# as the same `gosh: line ` markers a typed line gets.
vgate_assert 01 serial-contains 'gosh: line echo gosh-startup-ran'
vgate_assert 01 serial-contains 'gosh: prompt'
# The background Go child's own console output is serial-visible (its
# `echo` is the only source of this marker), and the job cycled through
# the reaper with a zero exit.
vgate_assert 01 serial-contains 'nested-child-ok'
vgate_assert 01 serial-contains 'gosh: job 1 pid='
vgate_assert 01 serial-contains 'gosh: job 1 done exit=0'
# The interactive editor, one marker per submitted line: a fresh line, a
# line edited with real Backspace keystrokes after an Up recall, and a
# second recall edited by one character.
vgate_assert 01 serial-contains 'gosh: line echo abc'
vgate_assert 01 serial-contains 'gosh: line echo az'
vgate_assert 01 serial-contains 'gosh: line echo azx'
vgate_assert 01 serial-contains 'gosh: close'
vgate_assert 01 serial-contains 'gosh OK'
vgate_assert 01 serial-contains 'rx-gosh-ok'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 serial-absent 'exited status=139'
# The scripting subset's byte proof ON THE HOST: a marker that reported
# success without writing the bytes cannot pass these.
vgate_assert 01 share-contains GOSHVARS.TXT 'V=hello-vars'
vgate_assert 01 share-contains GOSHPIPE.TXT 'alpha-beta'
vgate_assert 01 share-contains GOSHRC.TXT 'rc=7'
vgate_assert 01 share-contains GOSHJOB.TXT 'jobrc=0'
