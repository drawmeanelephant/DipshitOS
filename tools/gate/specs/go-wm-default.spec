# go-wm-default.spec -- M59 (issue #1298) class-B gate: the boot-default flip.
#
# Boot 01 carries NO `wm` setting, so the compiled default seats the GO desktop
# (GOTABWM.ELF) from the shell idle, and GOCALC.ELF is hosted by it (declare ->
# focus -> full viewport -> close). Zig CALC.BIN is gone (M62h / #1406).
#
# M71f (#1565): the run then persists `wm=tabwm` FROM THE GO PANEL. GOSET.ELF
# is exec'd under the seat as its first hosted tab, typed into, and applies
# `wm=tabwm` with one command line -- the panel publishes it crash-safe. That is
# the card's premise repaired in place: on the DEFAULT seat, a Go UI changes the
# seat. The published bytes are then compared to settings-healed.expected, the
# same fixture boot 04's kernel-side save is pinned against, so the panel's
# serializer and the kernel's must agree byte-for-byte.
#
# The panel is the FIRST hosted tab on purpose: it must be focused and typed
# into early (the runner's --input-string watcher gives up after 40 s, well
# before a second single-tab close cycle would finish). GOCALC.ELF is exec'd
# after the panel's window closes and the strip empties, so each app owns the
# strip alone -- no two-tab choreography, no SESSION.TABS snapshot, which would
# otherwise change what boots 03/04 see.
#
# Boot 02 proves the flip is a SETTING, not a hardcode: the same share boots
# the Zig TABWM seat -- the fallback the card requires to stay reachable.
# M63f (#1463): re-verified green after GOTABWM maxTicks 48. No HID here.
#
# M66b (#1444): boots 03/04 add the corrupt-settings story. Boot 03 stages
# real corruption (the monitor's vf verbs overwrite SETTINGS.TXT with
# probe-pattern garbage); boot 04 boots on it -- the kernel refuses the
# file whole (one honest line, compiled defaults, the Go seat again), the
# seat's own decode reports `gotabwm: settings bad`, and the closing
# `settings set` heals the file through the crash-safe save (temp + fsync
# + delete/rename). The healed bytes are byte-compared on the host.
#
# HOST PREREQUISITE (fails the gate honestly when missing):
#   bash tools/go/build-gotabwm.sh   ->  .build/go/GOTABWM.ELF
#   bash tools/go/build-gocalc.sh    ->  .build/go/GOCALC.ELF
#
# exec-order: assert-proven -- every stage gate is anchored on guest output the
# kernel, the seat or the hosted app produced (`gotabwm: win focus`,
# `gotabwm: win gone`, `gotabwm: tabs empty`, `goset: ready`, `tabwm:
# registered`). Runs 02-04 end on a marker only their own script prints. Run 01
# ends on the PANEL's publish line (`goset: saved `) and carries
# --script-expect-tail so the hold covers the seat's own clean exit -- the
# panel's save is the thing under test, and the tail keeps the `gotabwm OK` /
# `wm: unregistered, shim resumed` asserts honest rather than dropping them.

vgate_name go-wm-default "issue #1298 M59 / M71f #1565: a DEFAULT boot seats the Go desktop (GOTABWM.ELF hosting GOCALC.ELF), and the GO PANEL (GOSET.ELF) writing wm=tabwm keeps the Zig fallback reachable across a reboot"
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
# is in its WM_RPC serve loop. `wm` reports the live seat; then the Go panel
# GOSET.ELF is exec'd under it and takes the (empty) strip as its only tab.
vgate_file script2.txt <<'EOF'
set GOMAXPROCS=1
wm
exec GOSET.ELF
EOF

# Boot 01, stage 3: the panel's single-tab window has closed and the strip is
# empty again, so GOCALC.ELF is exec'd as the M59 hosted-client proof -- again
# as the strip's only tab. The save under test already happened in stage 2 and
# was the PANEL's, never the monitor's `settings set`.
vgate_file script3.txt <<'EOF'
exec GOCALC.ELF
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
src = os.path.join(".build", "go", "GOCALC.ELF")
if not os.path.exists(src):
    sys.exit("GOCALC.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-gocalc.sh")
shutil.copy(src, os.path.join(share, "GOCALC.ELF"))
print("staged GOCALC.ELF into share (%d bytes)" %
      os.path.getsize(os.path.join(share, "GOCALC.ELF")))
# M71f (#1565): the panel boot 01 launches from the catalogue. It must be
# staged, or the launcher's exec is the honest `launcher missing` path.
src = os.path.join(".build", "go", "GOSET.ELF")
if not os.path.exists(src):
    sys.exit("GOSET.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-goset.sh")
shutil.copy(src, os.path.join(share, "GOSET.ELF"))
print("staged GOSET.ELF into share (%d bytes)" %
      os.path.getsize(os.path.join(share, "GOSET.ELF")))
# No SETTINGS.TXT: boot 01 must run on the COMPILED default. That is the
# whole point -- staging a settings file here would test the setting, not
# the flip. It is also what makes the panel's FIRST save a create.
if os.path.exists(os.path.join(share, "SETTINGS.TXT")):
    sys.exit("SETTINGS.TXT already present in the share; boot 01 must boot "
             "with no persisted `wm`")
PY

# The default-seat table with `wm=tabwm`, in the kernel's settings.zig init()
# order (the `prompt` row's trailing space is part of the value). It is shared
# by TWO runs ON PURPOSE, because two different writers must produce it: boot 01
# publishes it from the GO PANEL (vi.WriteFileSafe), boot 04 heals a corrupt
# file through the MONITOR's crash-safe save. If the Go serializer ever drifts
# from the kernel's, one of those runs fails.
vgate_file settings-healed.expected <<'EOF'
#v2
hostname=virelai
prompt=virelai> 
theme=dark
scrollback=1000
shadow=off
focus_follows_mouse=off
shell=monitor
wm=tabwm
EOF

# M71f (#1565): the run gains HID. Once the panel says it is ready, one typed
# line edits and saves in a single keypress (Enter applies then publishes). The
# keys ride the custom-virtio INPUT queue (headless HID reports, no view), the
# same channel go-wm-hid's type-in boot uses, and they land in the FOCUSED
# window -- which is the panel, because its declare took focus.
vgate_run 01 -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio \
    --script '$RUN_DIR/script.txt' \
    --script-after 'gotabwm: win focus' \
    --script2 '$RUN_DIR/script2.txt' \
    --script2-after 'gotabwm: win gone' \
    --input-string $'wm=tabwm\n' \
    --input-string-after 'goset: ready ' \
    --script3 '$RUN_DIR/script3.txt' \
    --script3-after 'gotabwm: tabs empty' \
    --script-expect 'goset: saved ' --script-expect-tail 90 --timeout 300

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

# --- M71f (#1565): the DEFAULT seat's Go panel writes the setting ----------
# The panel is the strip's FIRST tab: exec'd under the live default seat, it
# decodes the ABSENT settings file as the compiled defaults (so `wm` is a row it
# can set -- card D2), takes the typed command line, and publishes.
vgate_assert 01 serial-contains 'exec: loaded GOSET.ELF'
vgate_assert 01 serial-contains 'goset: open id='
vgate_assert 01 serial-contains 'goset: ready keys=8 wm=gotabwm theme=dark mode=rw'
vgate_assert 01 serial-contains 'goset: set wm=tabwm'
vgate_assert 01 serial-contains 'goset: saved keys=8 wm=tabwm theme=dark'
vgate_assert 01 serial-contains 'goset OK'
# The publish is a real file on the share, byte-identical to what the kernel's
# own serializer emits for the same table -- the fixture boot 04's kernel-side
# save is pinned against too. Two writers, one byte shape.
vgate_assert 01 share-equals SETTINGS.TXT settings-healed.expected
# The panel's window closed before the second client was exec'd: the strip
# really emptied, so GOCALC never shared the strip with it.
vgate_assert 01 serial-contains 'gotabwm: tabs empty'

# --- and still hosts GOCALC.ELF (M59) ---------------------------------------
vgate_assert 01 serial-contains 'exec: loaded GOCALC.ELF'
vgate_assert 01 serial-contains 'gotabwm: rpc declare id='
vgate_assert 01 serial-contains 'gocalc: declare accepted'
vgate_assert 01 serial-contains 'gotabwm: host focus id='
vgate_assert 01 serial-contains 'gotabwm: host view id='
vgate_assert 01 serial-contains 'gocalc: present'
vgate_assert 01 serial-contains 'gotabwm: host close id='
vgate_assert 01 serial-contains 'gocalc: close'
vgate_assert 01 serial-contains 'gotabwm: host done'

vgate_assert 01 serial-contains 'gotabwm: close'
vgate_assert 01 serial-contains 'gotabwm OK'
vgate_assert 01 serial-contains 'wm: unregistered, shim resumed'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 serial-absent 'exited status=139'

# --- boot 02: the PANEL's `wm=tabwm` from boot 01 -> the Zig fallback seat ---
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
# seat in run 01 boots the Zig seat here. This is ALSO M71f's D2 -- the value
# the GO PANEL wrote is what makes the named Zig fallback (ADR 0034) reachable
# from the default seat. Panel-driven save, and the panel-driven fallback.
vgate_assert 02 serial-contains 'wm: autostart tabwm (settings wm=tabwm)'
vgate_assert 02 serial-contains 'tabwm: registered'
vgate_assert 02 serial-contains 'tabwm: sidebar-rendered'
vgate_assert 02 serial-contains 'tabwm: registered pid='
vgate_assert 02 serial-contains 'rx-m59-fallback-ok'
vgate_assert 02 serial-absent '[EXC] parking:'
vgate_assert 02 serial-absent 'exited status=139'

# --- M66b (#1444): corrupt settings fail closed, then heal ------------------
# Boot 03 stages the corruption the M66b design exists for: the monitor's
# `vf` verbs overwrite SETTINGS.TXT with 64 probe-pattern bytes -- the exact
# shape a partial in-place write used to leave (binary garbage, no valid
# `#v` header). Handle 0 is the first host write handle of a fresh boot.
# The boot itself seated the Zig tabwm (run 01's persisted `wm=tabwm`).
vgate_file script-03.txt <<'EOF'
vf open SETTINGS.TXT
vf truncate 0 0
vf write 0 64
vf close 0
echo rx-m66b-corrupt-staged
EOF

vgate_run 03 -- \
    --screen '$RUN_DIR/screen-03' \
    --script '$RUN_DIR/script-03.txt' \
    --script-expect 'rx-m66b-corrupt-staged' --timeout 300

vgate_assert 03 serial-contains 'wm: autostart tabwm (settings wm=tabwm)'
vgate_assert 03 serial-contains 'vf: open SETTINGS.TXT h=0'
vgate_assert 03 serial-contains 'vf: truncate 0 size=0 ok'
vgate_assert 03 serial-contains 'vf: write 0 n=64 wrote=64 chunks=1'
vgate_assert 03 serial-contains 'vf: close 0 ok'
vgate_assert 03 serial-contains 'rx-m66b-corrupt-staged'
vgate_assert 03 serial-absent '[EXC] parking:'
vgate_assert 03 serial-absent 'exited status=139'

# Boot 04 boots ON the corrupt file. The kernel refuses it whole (no valid
# schema header -> one honest line, compiled defaults), so the compiled
# default seats the GO desktop again, and the seat's own decode reports the
# corruption and runs on defaults -- corrupt-fails-closed, never a boot
# failure. The closing `settings set` then heals the file through the
# crash-safe save (temp + fsync + delete/rename, never an in-place
# truncate), and the share assert below byte-compares the healed bytes.
vgate_file script-04.txt <<'EOF'
settings set wm tabwm
echo rx-m66b-corrupt-ok
EOF

vgate_run 04 -- \
    --screen '$RUN_DIR/screen-04' \
    --script '$RUN_DIR/script-04.txt' \
    --script-after 'gotabwm: settings bad' \
    --script-expect 'rx-m66b-corrupt-ok' --timeout 300

vgate_assert 04 serial-contains 'settings: SETTINGS.TXT refused (defaults in force)'
vgate_assert 04 serial-contains 'wm: autostart gotabwm (settings wm=gotabwm)'
vgate_assert 04 serial-contains 'gotabwm: registered'
vgate_assert 04 serial-contains 'gotabwm: settings bad'
vgate_assert 04 serial-contains 'settings: wm=tabwm (persisted)'
vgate_assert 04 serial-contains 'rx-m66b-corrupt-ok'
vgate_assert 04 serial-absent '[EXC] parking:'
vgate_assert 04 serial-absent 'exited status=139'

# The healed file, byte-exact: the same settings-healed.expected boot 01's Go
# panel published (declared above). `share-equals` lifts the compared file
# into evidence automatically.
vgate_assert 04 share-equals SETTINGS.TXT settings-healed.expected
# The publish consumed its temp: a crash-safe save leaves no SETTINGS.TXT.tmp
# on the share (the rename is the publish).
vgate_assert 04 python <<'PY'
import os, sys
share = os.environ["VG_SHARE"]
stale = os.path.join(share, "SETTINGS.TXT.tmp")
if os.path.exists(stale):
    sys.exit("SETTINGS.TXT.tmp survived the publish - the rename did not run")
print("crash-safe publish left no SETTINGS.TXT.tmp on the share")
PY
