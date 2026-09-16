# go-wm-default.spec -- M59 (issue #1298) class-B gate: the boot-default flip.
#
# Boot 01 carries NO `wm` setting, so the compiled default seats the GO desktop
# (GOTABWM.ELF) from the shell idle, and the leftover Zig CALC.BIN is hosted by
# it (declare -> focus -> full viewport -> close) -- the same app-side markers
# the M57c interop and TABWM parity gates assert, reached here by DEFAULT
# rather than by an explicit `exec GOTABWM.ELF`. The run then persists
# `settings set wm tabwm`.
#
# Boot 02 proves the flip is a SETTING, not a hardcode: the same share boots
# the Zig TABWM seat -- the fallback the card requires to stay reachable.
#
# HOST PREREQUISITE (fails the gate honestly when missing):
#   bash tools/go/build-gotabwm.sh   ->  .build/go/GOTABWM.ELF
#
# exec-order: assert-proven -- each run ends on a marker only its script
# prints, and every stage gate is anchored on guest output the kernel, the
# seat or the hosted app produced (`gotabwm: win focus`, `gotabwm: win gone`,
# `gotabwm: host done`, `tabwm: registered`).

vgate_name go-wm-default "issue #1298 M59: a DEFAULT boot seats the Go desktop (GOTABWM.ELF hosting a leftover Zig app) and `settings set wm tabwm` keeps the Zig fallback reachable"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

# Boot 01, stage 1: forwarded once the seat holds its window and is WAITING for
# the blur, so `dui focus 0` (the fixed terminal window) hands focus away and
# the kernel routes WIN_BLUR to the seat. No `wm` key anywhere: the autostart
# is what put this seat on the scanout.
vgate_file script.txt <<'EOF'
dui focus 0
EOF

# Boot 01, stage 2: forwarded once the window phase is finished, i.e. the seat
# is in its WM_RPC serve loop. `wm` reports the live seat; then the UNMODIFIED
# Zig app is exec'd under it.
vgate_file script2.txt <<'EOF'
wm
exec CALC.BIN
EOF

# Boot 01, stage 3: the hosted app is done. Persist the fallback seat so boot
# 02 proves the setting wins over the compiled default, then end the run on a
# script-owned marker.
vgate_file script3.txt <<'EOF'
settings set wm tabwm
echo rx-m59-default-ok
EOF

vgate_setup_python <<'PY'
import os, shutil, sys
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
src = os.path.join(".build", "go", "GOTABWM.ELF")
if not os.path.exists(src):
    sys.exit("GOTABWM.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-gotabwm.sh")
shutil.copy(src, os.path.join(share, "GOTABWM.ELF"))
print("staged GOTABWM.ELF into share (%d bytes)" %
      os.path.getsize(os.path.join(share, "GOTABWM.ELF")))
# No SETTINGS.TXT: boot 01 must run on the COMPILED default. That is the
# whole point -- staging a settings file here would test the setting, not
# the flip.
if os.path.exists(os.path.join(share, "SETTINGS.TXT")):
    sys.exit("SETTINGS.TXT already present in the share; boot 01 must boot "
             "with no persisted `wm`")
PY

vgate_run 01 -- \
    --screen '$RUN_DIR/screen' \
    --script '$RUN_DIR/script.txt' \
    --script-after 'gotabwm: win focus' \
    --script2 '$RUN_DIR/script2.txt' \
    --script2-after 'gotabwm: win gone' \
    --script3 '$RUN_DIR/script3.txt' \
    --script3-after 'gotabwm: host done' \
    --script-expect 'rx-m59-default-ok' --timeout 300

# --- the flip: an untouched boot lands in the Go desktop ------------------
vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
# The shell idle seated the Go desktop because nothing else was configured.
vgate_assert 01 serial-contains 'wm: autostart gotabwm (settings wm=gotabwm)'
# The seat's own marker chain (each printed after its syscall succeeded).
vgate_assert 01 serial-contains 'gotabwm: registered'
vgate_assert 01 serial-contains 'gotabwm: seat-taken'
vgate_assert 01 serial-contains 'gotabwm: scanout'
vgate_assert 01 serial-contains 'gotabwm: draw'
vgate_assert 01 serial-contains 'gotabwm: holding seat'
vgate_assert 01 serial-contains 'gotabwm: tick'
vgate_assert 01 serial-contains 'gotabwm: present'
# The kernel's own report of the live seat, queried while it is up.
vgate_assert 01 serial-contains 'wm: registered pid='
vgate_assert 01 serial-contains 'wm: present_seq='
# The seat's own window lifecycle, with the kernel-clamped rect (4000,3000
# clamped to the 1280x720 scanout: x=1024, y=528).
vgate_assert 01 serial-contains 'gotabwm: win open id='
vgate_assert 01 serial-contains 'gotabwm: win rect x=1024 y=528 w=256 h=192'
vgate_assert 01 serial-contains 'gotabwm: win focus'
vgate_assert 01 serial-contains 'gotabwm: win blur'
vgate_assert 01 serial-contains 'gotabwm: win close'
vgate_assert 01 serial-contains 'gotabwm: win gone'

# --- the DEFAULT seat hosts a leftover Zig app -----------------------------
vgate_assert 01 serial-contains 'exec: loaded CALC.BIN'
vgate_assert 01 serial-contains 'gotabwm: rpc declare id='
vgate_assert 01 serial-contains 'calc: tab-aware (full-viewport)'
vgate_assert 01 serial-contains 'gotabwm: host focus id='
vgate_assert 01 serial-contains 'gotabwm: host view id='
vgate_assert 01 serial-contains 'calc: resize relayout'
vgate_assert 01 serial-contains 'gotabwm: host close id='
vgate_assert 01 serial-contains 'calc: win_close'
vgate_assert 01 serial-contains 'gotabwm: host done'

# --- the flip is a setting: the persisted fallback seat wins ----------------
vgate_assert 01 serial-contains 'settings: wm=tabwm (persisted)'
vgate_assert 01 serial-contains 'gotabwm: close'
vgate_assert 01 serial-contains 'gotabwm OK'
vgate_assert 01 serial-contains 'wm: unregistered, shim resumed'
vgate_assert 01 serial-contains 'rx-m59-default-ok'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 serial-absent 'exited status=139'

# --- boot 02: `settings set wm tabwm` from boot 01 -> the Zig fallback seat --
vgate_file script-02.txt <<'EOF'
tabwm
echo rx-m59-fallback-ok
EOF

vgate_run 02 -- \
    --screen '$RUN_DIR/screen-02' \
    --script '$RUN_DIR/script-02.txt' \
    --script-after 'tabwm: registered' \
    --script-expect 'rx-m59-fallback-ok' --timeout 300

# The persisted setting, not a hardcode: the same share that booted the Go
# seat in run 01 boots the Zig seat here.
vgate_assert 02 serial-contains 'wm: autostart tabwm (settings wm=tabwm)'
vgate_assert 02 serial-contains 'tabwm: registered'
vgate_assert 02 serial-contains 'tabwm: sidebar-rendered'
vgate_assert 02 serial-contains 'tabwm: registered pid='
vgate_assert 02 serial-contains 'rx-m59-fallback-ok'
vgate_assert 02 serial-absent '[EXC] parking:'
vgate_assert 02 serial-absent 'exited status=139'
