# go-files.spec -- M58a (issue #1305) class-B gate: a Go file manager lists a
# known host-share file, full-viewport inside Zig TABWM.
#
# user/go/files is a tabapp client: init -> declare (kind-8 WM_RPC) ->
# sys_dir_list the seeded /host/FM directory -> find KNOWN.TXT -> read it ->
# present -> close. Serial markers are the proof; each is printed only after
# its syscall returned. Zig FILE.BIN is gone (M60 / #1374); the file manager
# is GOFILES.ELF. Kernel untouched.
#
# HOST PREREQUISITE (fails the gate honestly when missing):
#   bash tools/go/build-files.sh   ->  .build/go/GOFILES.ELF
#
# exec-order: assert-proven -- the run ends on `rx-gofiles-ok`, which only the
# script prints, and the stage gate that forwards the close waits on the app's
# own `gofiles: present`; a program that never ran cannot pass.

vgate_name go-files "issue #1305 M58a: a Go file manager lists a known share file in Zig TABWM on VZ"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script.txt <<'EOF'
tabwm
tabwm start
EOF

vgate_file script2.txt <<'EOF'
exec GOFILES.ELF /host/FM
EOF

# The close is driven from the harness after the app's own `gofiles: present`
# (the stage gate), so the listing has already printed before the window closes.
vgate_file script3.txt <<'EOF'
dui close 2
echo rx-gofiles-ok
EOF

vgate_setup_python <<'PY'
import os, shutil, sys
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
src = os.path.join(".build", "go", "GOFILES.ELF")
if not os.path.exists(src):
    sys.exit("GOFILES.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-files.sh")
shutil.copy(src, os.path.join(share, "GOFILES.ELF"))
fm = os.path.join(share, "FM")
os.makedirs(fm, exist_ok=True)
known = os.path.join(fm, "KNOWN.TXT")
with open(known, "w") as f:
    f.write("hello-from-gofiles\n")
print("staged GOFILES.ELF into share (%d bytes) and %s (%d bytes)" %
      (os.path.getsize(os.path.join(share, "GOFILES.ELF")),
       known, os.path.getsize(known)))
PY

vgate_run 01 -- \
    --screen '$RUN_DIR/screen' \
    --script '$RUN_DIR/script.txt' \
    --script2 '$RUN_DIR/script2.txt' \
    --script2-after 'tabwm: sidebar-rendered' \
    --script3 '$RUN_DIR/script3.txt' \
    --script3-after 'gofiles: present' \
    --script-expect 'rx-gofiles-ok' --timeout 120

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'tabwm: starting TABWM.BIN'
vgate_assert 01 serial-contains 'tabwm: registered'
vgate_assert 01 serial-contains 'tabwm: sidebar-rendered'
vgate_assert 01 serial-contains 'exec: loaded GOFILES.ELF'
vgate_assert 01 serial-contains 'gofiles: open id='
vgate_assert 01 serial-contains 'gofiles: declare accepted'
vgate_assert 01 serial-contains 'gofiles: list /host/FM n='
vgate_assert 01 serial-contains 'gofiles: entry KNOWN.TXT'
vgate_assert 01 serial-contains 'gofiles: found KNOWN.TXT'
vgate_assert 01 serial-contains 'gofiles: view KNOWN.TXT'
vgate_assert 01 serial-contains 'gofiles: present'
vgate_assert 01 serial-contains 'gofiles: close'
vgate_assert 01 serial-contains 'gofiles OK'
vgate_assert 01 serial-contains 'rx-gofiles-ok'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 serial-absent 'exited status=139'
