# live-sound-playback.spec -- claim 5877 (Milestone 15 Card A2): PCM playback on VZ.
# The runner boots with --sound and executes `beep 440 300`. The guest drives virtio-snd
# PCM_INFO -> PCM_SET_PARAMS -> PCM_PREPARE -> PCM_START -> TX submission (4096-B
# periods of FLOAT/stereo/48 kHz) -> drain -> PCM_STOP -> PCM_RELEASE.

vgate_name live-sound-playback "M15 A2 PCM playback on VZ"
vgate_repeat 1 BOOTS

vgate_file script.txt <<'EOF'
beep 440 300
EOF

vgate_run 01 -- --sound --script '$RUN_DIR/script.txt' --script-after 'tasks user-el0 exited status=7' --script-expect 'beep: ok' --timeout 150

vgate_assert 01 output-contains 'SOUND: virtio-snd attached'
vgate_assert 01 serial-contains 'snd: pre-rearm st=0f'
vgate_assert 01 serial-contains 'beep: info st=0x0000000000008000'
vgate_assert 01 serial-contains 'formats=0x00000000000a0020'
vgate_assert 01 serial-contains 'rates=0x0000000000000480'
vgate_assert 01 serial-contains 'ch=1..2 dir=0'
vgate_assert 01 serial-contains 'beep: params fmt=19 rate=7 ch=2'
vgate_assert 01 serial-contains 'st=0x0000000000008000 prepare=0x0000000000008000 start=0x0000000000008000'
vgate_assert 01 serial-contains 'beep: tx submitted=115200 drained=115200 frames=14400'
vgate_assert 01 serial-contains 'pcm_status=0x0000000000008000'
vgate_assert 01 serial-contains 'beep: stop=0x0000000000008000 release=0x0000000000008000'
vgate_assert 01 serial-contains 'beep: ok'
vgate_assert 01 serial-absent '[EXC] parking'

# M70f2 (#1476): the accounting IDENTITY, asserted as arithmetic instead of as
# a verbatim line. A pinned `submitted=115200 drained=115200` catches a change
# but cannot catch a *consistent wrong* pair (a period dropped and a frame count
# adjusted to match), whereas the three relations below each fail on their own
# for their own reason: the geometry (300 ms at 48 kHz), the format width
# (FLOAT/stereo = 8 bytes a frame), and the identity itself (every submitted
# byte drained). The card's rule is to assert the identity, not "sound came
# out" -- and this is the PCM path, so it belongs here.
vgate_assert 01 python <<'PY'
import os, re, sys

ser = open(os.environ["VG_SER"], "rb").read().decode("latin1", errors="replace")
m = re.search(r"beep: tx submitted=(\d+) drained=(\d+) frames=(\d+)", ser)
if not m:
    sys.exit("ERROR: no beep tx marker in serial")
submitted, drained, frames = (int(g) for g in m.groups())
if frames != 300 * 48:
    sys.exit(f"ERROR: frames={frames}, want 300 ms at 48 kHz")
if submitted != frames * 8:
    sys.exit(f"ERROR: submitted={submitted} is not frames={frames} * 8 (FLOAT/stereo)")
if drained != submitted:
    sys.exit(f"ERROR: ACCOUNTING IDENTITY BROKEN: drained={drained} of submitted={submitted}")

# The device agreed, from the other side of the same submission: a period that
# never reached the queue would leave a non-zero status here.
if "pcm_status=0x0000000000008000" not in ser:
    sys.exit("ERROR: pcm_status is not the virtio-snd OK value 0x8000")
PY
