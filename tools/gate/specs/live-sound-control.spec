# live-sound-control.spec -- claim 9297 (M15 follow-up): stream-state control on VZ.
# Proves stream-state control (volume 0..100 + mute) applied as in-place gain at TX
# submit choke point: monitor control sets vol/mute, muted beep still drains exactly,
# unmuted beep drains at new volume, and CHIME.BIN mutates kernel state via EL0 seam
# (ADR 0007 slots 44/45).

vgate_name live-sound-control "M15 stream-state control on VZ"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE
vgate_repeat 1 BOOTS

vgate_file script.txt <<'EOF'
sound volume 30
sound
sound mute on
beep 440 200
sound mute off
beep 660 150
exec CHIME.BIN
EOF

# Run 02 is the M70f2 (#1476) half: the SAME slot 44/45 rows, driven from Go
# instead of Zig. FART.ELF sets a gain through the vi binding, runs its
# muted-drain A/B, and leaves the VM unmuted; the monitor then READS THE KERNEL
# STATE back, which is the point -- `sound: vol=40` is kernel state observed
# through a path the app does not control, where the app's own markers could
# only tell us what the syscall returned.
#
# The honest limit: mute=0 here is the app's `mute off` OR just the default, and
# those are indistinguishable, so this run does NOT claim the app's mute call is
# visible in kernel state. What it shows is the volume (40 could only have come
# from the app; the boot default is 50) plus the app's own mute accounting,
# which the counter rows in go-fart.spec pin to two real calls.
vgate_file script3.txt <<'EOF'
exec FART.ELF
EOF

vgate_file script4.txt <<'EOF'
sound
syscalls
echo control-go-ok
EOF

# FART.ELF is built by tools/go/build-fart.sh, not by the seed share.
vgate_setup_python <<'PY'
import os, shutil, sys
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
src = os.path.join(".build", "go", "FART.ELF")
if not os.path.exists(src):
    sys.exit("FART.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-fart.sh")
shutil.copy(src, os.path.join(share, "FART.ELF"))
print("staged FART.ELF into share (%d bytes)" % os.path.getsize(os.path.join(share, "FART.ELF")))
PY

vgate_file script2.txt <<'EOF'
sound
syscalls
echo control-live-ok
EOF

vgate_run 01 -- --sound --script '$RUN_DIR/script.txt' --script-after 'tasks user-el0 exited status=7' --script2 '$RUN_DIR/script2.txt' --script2-after 'chime: done' --script2-delay 3 --script-expect 'control-live-ok' --timeout 150

# Run 02: the Go consumer (M70f2 #1476) on the same rows.
vgate_run 02 -- --sound --script '$RUN_DIR/script3.txt' --script-after 'tasks user-el0 exited status=7' --script2 '$RUN_DIR/script4.txt' --script2-after 'fart: done' --script2-delay 3 --script-expect 'control-go-ok' --timeout 150

vgate_assert 01 output-contains 'SOUND: virtio-snd attached'
vgate_assert 01 serial-contains 'sound: volume=30'
vgate_assert 01 serial-contains 'sound: vol=30 mute=0'
vgate_assert 01 serial-contains 'sound: mute=on'
vgate_assert 01 serial-contains 'beep: tx submitted=76800 drained=76800 frames=9600'
vgate_assert 01 serial-contains 'pcm_status=0x0000000000008000'
vgate_assert 01 serial-contains 'sound: mute=off'
vgate_assert 01 serial-contains 'beep: tx submitted=57600 drained=57600 frames=7200'
vgate_assert 01 serial-contains 'chime: vol=50 mute=0'
vgate_assert 01 serial-contains 'chime: done'
vgate_assert 01 serial-contains 'tasks user-exec exited status=0'
vgate_assert 01 serial-contains 'sound: vol=50 mute=0'
# The slot census is NOT this spec's subject (sound control is). This line
# pinned `implemented=68` while kernel/src/syscall.zig declares
# `implemented_count = 78`, so it had been RED ON MAIN -- in a class-B spec CI
# does not run, which is how a drifted pin survives. (live-net-udp-syscall.spec
# pins the same stale 68 and is left alone here: different file, different
# card.) Asserted as the SHAPE the repo's composition specs already use
# (live-m14/m15-composition), so the next slot to land breaks the census at
# its source instead of breaking a sound spec.
vgate_assert 01 serial-contains 'syscalls: slots=64 implemented='
vgate_assert 01 serial-contains '44 sys_audio_volume calls=1'
vgate_assert 01 serial-contains '45 sys_audio_mute calls=1'
vgate_assert 01 serial-contains '43 sys_audio_play calls=30'
vgate_assert 01 serial-contains 'control-live-ok'
vgate_assert 01 serial-absent '[EXC] parking'

# --- run 02: the Go consumer (M70f2 #1476) -------------------------------
vgate_assert 02 output-contains 'SOUND: virtio-snd attached'
vgate_assert 02 serial-contains 'exec: loaded FART.ELF'
# Slot 44 through the vi binding: the refusal of an out-of-range gain
# (ADR 0007 row 44, no clamping), then the accepted one and its echo.
vgate_assert 02 serial-contains 'fart: vol over=101 err=EINVAL'
vgate_assert 02 serial-contains 'fart: vol set=40 echo=40'
# The muted-drain identity, in the spec that owns volume/mute semantics.
vgate_assert 02 serial-contains 'fart: unmuted played=96000'
vgate_assert 02 serial-contains 'fart: mute on'
vgate_assert 02 serial-contains 'fart: muted played=96000'
vgate_assert 02 serial-contains 'fart: mute off'
vgate_assert 02 serial-absent 'CLAMPED'
vgate_assert 02 serial-contains 'fart: done'
# Kernel state, read back through the monitor: 40 can only have come from the
# app's slot-44 call (the boot default is 50).
vgate_assert 02 serial-contains 'sound: vol=40 mute=0'
vgate_assert 02 serial-contains '44 sys_audio_volume calls=2'
vgate_assert 02 serial-contains '45 sys_audio_mute calls=2'
vgate_assert 02 serial-contains 'procs FART.ELF exited status=0'
vgate_assert 02 serial-contains 'control-go-ok'
vgate_assert 02 serial-absent '[EXC] parking'
