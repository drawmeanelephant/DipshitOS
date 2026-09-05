# live-settings.spec -- claim 2649: persistent settings on host share across reboot

vgate_name live-settings "persistent settings on host share across reboot"
vgate_share arm
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script-A.txt <<'EOF'
settings
settings set hostname elephant-box
settings set prompt elephant> 
settings get hostname
EOF

vgate_file script-B.txt <<'EOF'
settings get hostname
settings list
EOF

# --- run A: set settings and persist ---
vgate_run A -- \
    --script '$RUN_DIR/script-A.txt' \
    --script-expect $'settings: hostname=elephant-box\n' \
    --timeout 40

vgate_assert A serial-contains "settings: hostname=elephant-box (persisted)"
vgate_assert A serial-contains "settings: prompt=elephant> (persisted)"
vgate_assert A serial-contains "settings: hostname=elephant-box"
vgate_assert A serial-absent "[EXC] parking:"

# --- run B: persistence across reboot, same share ---
vgate_run B -- \
    --script '$RUN_DIR/script-B.txt' \
    --script-expect $'hostname=elephant-box\n' \
    --timeout 40

vgate_assert B serial-contains "hostname=elephant-box"
vgate_assert B serial-contains "elephant>"
vgate_assert B serial-absent "[EXC] parking:"

vgate_assert B python <<'PY'
import os
p = os.path.join(os.environ["VG_SHARE"], "SETTINGS.TXT")
assert os.path.exists(p), "SETTINGS.TXT missing on share"
txt = open(p).read()
assert "hostname=elephant-box" in txt, "hostname missing from SETTINGS.TXT"
assert "prompt=elephant>" in txt, "prompt missing from SETTINGS.TXT"
PY
