# live-history.spec -- persistent shell history across reboots: boot
# H1 types distinctive commands (persisted to HISTORY.TXT on the
# share); boot H2 recalls the last one via a keyboard Up chord and
# the host-disk HISTORY.TXT carries the commands. The checkpoint
# disk.img grep in legacy is ||-true diagnostics -- not ported.
# Mirrors tools/verify-live-history.sh (M18 T4, issue #407).

vgate_name live-history "persistent history recall + host-disk HISTORY.TXT on VZ"
vgate_share arm
vgate_runner_flags -Xswiftc -DSPIKE
vgate_fmt boot/src/*.zig kernel/src/*.zig build.zig
vgate_repeat 1 BOOTS

vgate_file script1.txt <<'EOF'
echo T4-first-command
echo T4-second-unique
echo history-live-ready
echo T4-third-marker
EOF

# Boot 2's key files are byte-exact generated fixtures: keys.txt is
# CR-separated (the Enter that submits stays serial -- \n would not
# submit) and empty.txt is truly 0 bytes (any typed line would pollute
# the recalled history top). A literal heredoc cannot express either,
# so they ride the setup hook.
vgate_setup_python <<'PY'
import os
rd = os.environ["RUN_DIR"]
open(os.path.join(rd, "keys.txt"), "wb").write(b"\rinput\recho history-live-ok\r")
open(os.path.join(rd, "empty.txt"), "wb").write(b"")
print("history key files ok")
PY

vgate_run H1 -- --script '$RUN_DIR/script1.txt' --script-expect 'T4-third-marker' --timeout 30
vgate_run H2 -- --input --display --script '$RUN_DIR/empty.txt' --input-chords 'up' --input-chords-after 'virelai> ' --input-chords-delay 2.0 --script2 '$RUN_DIR/keys.txt' --script2-after 'virelai> ' --script2-delay 15 --script-expect 'history-live-ok' --timeout 60

vgate_assert H2 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert H2 serial-contains 'T4-third-marker'
vgate_assert H2 serial-contains 'input: armed=1 fifo=0/64 dropped=0 events=1'
vgate_assert H2 serial-contains 'history-live-ok'
vgate_assert H2 output-contains 'input-chords: ENABLED'
vgate_assert H2 python <<'PY'
import os, sys
# HF5-DISK: HISTORY.TXT on the host share carries the T4 commands.
p = os.path.join(os.environ["VG_SHARE"], "HISTORY.TXT")
try:
    body = open(p, errors="replace").read()
except OSError:
    sys.exit("FAIL: HISTORY.TXT missing from the host share")
if "T4-first-command" not in body or "T4-third-marker" not in body:
    sys.exit("FAIL: HISTORY.TXT incomplete on the host share")
print("history host-disk ok")
PY
