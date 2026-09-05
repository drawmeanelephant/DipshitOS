# live-sound-app.spec -- claim 7636 (Milestone 15 Card A3): EL0 audio seam on VZ.
# The runner boots with --sound and execs JINGLE.BIN. The app asks sys_audio_info
# for negotiated state (FLOAT 19 / 48000 7 / stereo 2), then plays 14 notes of
# "Twinkle Twinkle Little Star" via sys_audio_play (slots 42/43) in bounded chunks,
# followed by the syscalls report.

vgate_name live-sound-app "M15 A3 EL0 audio seam on VZ"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE
vgate_repeat 1 BOOTS

vgate_file script.txt <<'EOF'
exec JINGLE.BIN
EOF

vgate_file script2.txt <<'EOF'
syscalls
echo sound-app-live-ok
EOF

vgate_run 01 -- --sound --script '$RUN_DIR/script.txt' --script-after 'tasks user-el0 exited status=7' --script2 '$RUN_DIR/script2.txt' --script2-after 'jingle: done' --script2-delay 3 --script-expect 'sound-app-live-ok' --timeout 150

vgate_assert 01 output-contains 'SOUND: virtio-snd attached'
vgate_assert 01 serial-contains 'jingle: info fmt=19 rate=7 ch=2 period=4096 max=65536'
vgate_assert 01 serial-contains 'jingle: done'
vgate_assert 01 serial-contains '42 sys_audio_info calls=1'
vgate_assert 01 serial-contains 'sound-app-live-ok'
vgate_assert 01 serial-absent '[EXC] parking'

vgate_assert 01 python <<'PY'
import os, sys, re

ser = open(os.environ["VG_SER"], "rb").read().decode("latin1", errors="replace")

notes = [
    (1, 262, 250, 96000),
    (2, 262, 250, 96000),
    (3, 392, 250, 96000),
    (4, 392, 250, 96000),
    (5, 440, 250, 96000),
    (6, 440, 250, 96000),
    (7, 392, 500, 192000),
    (8, 349, 250, 96000),
    (9, 349, 250, 96000),
    (10, 330, 250, 96000),
    (11, 330, 250, 96000),
    (12, 294, 250, 96000),
    (13, 294, 250, 96000),
    (14, 262, 500, 192000),
]

for n, f, dur, played in notes:
    pattern = rf"jingle: note {n} f={f} dur={dur} chunks=\d+ played={played}"
    if not re.search(pattern, ser):
        sys.exit(f"ERROR: missing note {n} marker (f={f} dur={dur} played={played})")

m = re.search(r"43 sys_audio_play calls=(\d+)", ser)
if not m or int(m.group(1)) < 14:
    sys.exit(f"ERROR: sys_audio_play calls < 14: {m.group(0) if m else 'none'}")
PY
