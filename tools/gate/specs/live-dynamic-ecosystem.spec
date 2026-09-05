# live-dynamic-ecosystem.spec -- Milestone 31 Class-B Gate (claim 4001):
# Dynamic Linking Ecosystem & Userland Migration.

vgate_name live-dynamic-ecosystem "Milestone 31 Dynamic Linking Ecosystem"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script-DYNAPP.txt <<'EOF'
ls
exec DYNAPP.ELF
EOF

vgate_run DYNAPP -- --script '$RUN_DIR/script-DYNAPP.txt' --script-after 'tasks user-el0 exited status=7' --script-expect 'tasks user-exec reaped' --timeout 60
vgate_assert DYNAPP serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert DYNAPP serial-contains 'exec: loaded DYNAPP.ELF'
vgate_assert DYNAPP serial-contains 'dynapp: hello from dynamic executable'
vgate_assert DYNAPP serial-contains 'tasks user-exec exited status=0'
vgate_assert DYNAPP serial-contains 'tasks user-exec reaped'
vgate_assert DYNAPP serial-absent '[EXC] parking:'
vgate_assert DYNAPP python <<'PY'
import os, re
ser = open(os.environ["VG_SER"]).read()
assert not re.search(r"(panic|EXCEPTION|Synchronous|FAULT)", ser), "fault detected"
PY

vgate_file script-CALC.txt <<'EOF'
ls
exec CALC.ELF
EOF

vgate_run CALC -- --script '$RUN_DIR/script-CALC.txt' --script-after 'tasks user-el0 exited status=7' --script-expect 'tasks user-exec reaped' --timeout 60
vgate_assert CALC serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert CALC serial-contains 'exec: loaded CALC.ELF'
vgate_assert CALC serial-contains 'calc.elf: plugin pow(2, 8) = 256 ok'
vgate_assert CALC serial-contains 'tasks user-exec exited status=0'
vgate_assert CALC serial-contains 'tasks user-exec reaped'
vgate_assert CALC serial-absent '[EXC] parking:'
vgate_assert CALC python <<'PY'
import os, re
ser = open(os.environ["VG_SER"]).read()
assert not re.search(r"(panic|EXCEPTION|Synchronous|FAULT)", ser), "fault detected"
PY

vgate_file script-NOTEPAD.txt <<'EOF'
ls
exec NOTEPAD.ELF
EOF

vgate_run NOTEPAD -- --script '$RUN_DIR/script-NOTEPAD.txt' --script-after 'tasks user-el0 exited status=7' --script-expect 'tasks user-exec reaped' --timeout 60
vgate_assert NOTEPAD serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert NOTEPAD serial-contains 'exec: loaded NOTEPAD.ELF'
vgate_assert NOTEPAD serial-contains 'notepad.elf: clipboard roundtrip ok'
vgate_assert NOTEPAD serial-contains 'tasks user-exec exited status=0'
vgate_assert NOTEPAD serial-contains 'tasks user-exec reaped'
vgate_assert NOTEPAD serial-absent '[EXC] parking:'
vgate_assert NOTEPAD python <<'PY'
import os, re
ser = open(os.environ["VG_SER"]).read()
assert not re.search(r"(panic|EXCEPTION|Synchronous|FAULT)", ser), "fault detected"
PY

vgate_file script-FILE.txt <<'EOF'
ls
exec FILE.ELF
EOF

vgate_run FILE -- --script '$RUN_DIR/script-FILE.txt' --script-after 'tasks user-el0 exited status=7' --script-expect 'tasks user-exec reaped' --timeout 60
vgate_assert FILE serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert FILE serial-contains 'exec: loaded FILE.ELF'
vgate_assert FILE serial-contains 'file.elf: file table and ui ok'
vgate_assert FILE serial-contains 'tasks user-exec exited status=0'
vgate_assert FILE serial-contains 'tasks user-exec reaped'
vgate_assert FILE serial-absent '[EXC] parking:'
vgate_assert FILE python <<'PY'
import os, re
ser = open(os.environ["VG_SER"]).read()
assert not re.search(r"(panic|EXCEPTION|Synchronous|FAULT)", ser), "fault detected"
PY

vgate_file script-DESKTOP.txt <<'EOF'
ls
exec DESKTOP.ELF
EOF

vgate_run DESKTOP -- --script '$RUN_DIR/script-DESKTOP.txt' --script-after 'tasks user-el0 exited status=7' --script-expect 'tasks user-exec reaped' --timeout 60
vgate_assert DESKTOP serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert DESKTOP serial-contains 'exec: loaded DESKTOP.ELF'
vgate_assert DESKTOP serial-contains 'desktop.elf: composition session active ok'
vgate_assert DESKTOP serial-contains 'tasks user-exec exited status=0'
vgate_assert DESKTOP serial-contains 'tasks user-exec reaped'
vgate_assert DESKTOP serial-absent '[EXC] parking:'
vgate_assert DESKTOP python <<'PY'
import os, re
ser = open(os.environ["VG_SER"]).read()
assert not re.search(r"(panic|EXCEPTION|Synchronous|FAULT)", ser), "fault detected"
PY
