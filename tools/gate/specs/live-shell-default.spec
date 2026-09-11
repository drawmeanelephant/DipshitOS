# live-shell-default.spec -- M45 card SH8 class-B gate (issue #1084, ADR 0021 D5).
#
# The default-shell flip. Boot 1 (share has no SETTINGS.TXT) lands in the
# kernel monitor: `settings set shell sh` + `settings set prompt SH8PROMPT`
# persist a SETTINGS.TXT, then `reboot`. Boot 2 reads it, and the boot login
# hands the raw console to SH.BIN (`login: shell=sh -> SH.BIN`) -- which
# attaches the serial front-end, adopts the persisted prompt, and runs a
# typed command. The untouched default (boot 1) stays the monitor; the
# existing live-sh* gates prove the monitor default on a clean share.

vgate_name live-shell-default "#1084 SH8 default-shell flip: shell=sh boots into SH.BIN, default stays the monitor"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script.txt <<'EOF'
settings set prompt SH8PROMPT
settings set shell sh
reboot
EOF

vgate_file edit.txt <<'EOF'
echo sh8-ok
EOF

vgate_run 01 -- --screen '$RUN_DIR/screen' \
    --script '$RUN_DIR/script.txt' \
    --script2 '$RUN_DIR/edit.txt' \
    --script2-after 'sh: attached' \
    --script-expect 'sh8-ok' \
    --timeout 120

# Boot 1 = the untouched default: the monitor ran the settings + reboot.
vgate_assert 01 serial-count 'kernel has seized control' 2
vgate_assert 01 serial-contains 'settings: shell=sh (persisted)'
vgate_assert 01 serial-contains 'settings: prompt=SH8PROMPT (persisted)'
# Boot 2 = shell=sh: the login handed the console to SH.BIN.
vgate_assert 01 serial-contains 'login: shell=sh -> SH.BIN'
vgate_assert 01 serial-contains 'sh: ready'
vgate_assert 01 serial-contains 'sh: attached'
vgate_assert 01 serial-contains 'sh8-ok'
vgate_assert 01 serial-absent '\[EXC\]'
vgate_assert 01 serial-absent '[EXC] parking:'

vgate_assert 01 python <<'PY'
import os, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
# Boot 1 is the monitor; boot 2 is SH.BIN. Prove the ORDER: the monitor-side
# settings write precedes the login handoff, which precedes SH.BIN's ready.
i_settings = ser.find("settings: shell=sh (persisted)")
i_login = ser.find("login: shell=sh -> SH.BIN")
i_ready = ser.find("sh: ready")
assert i_settings >= 0 and i_login >= 0 and i_ready >= 0, "missing marker(s)"
assert i_settings < i_login < i_ready, f"wrong order: settings={i_settings} login={i_login} ready={i_ready}"
# SH.BIN adopted the persisted prompt (it appears after its ready marker).
assert "SH8PROMPT" in ser[i_ready:], "SH.BIN did not adopt the settings prompt"
print("shell-default boot ordering + prompt adoption OK")
PY
