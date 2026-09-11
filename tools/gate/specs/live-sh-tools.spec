# live-sh-tools.spec -- M49 card SD3 class-B gate (issue #1130).
#
# The freestanding tool multicall (lib/toolbox.zig) two ways:
#   1. the standalone TOOL.BIN from the monitor (`exec TOOL.BIN wc -l FILE`),
#      with the first argument selecting the tool;
#   2. the same engine as SH.BIN builtins, sourced from a share script:
#      head/wc/grep/sort/cut/printf/test/[/case/read plus a pipe
#      (`env | grep PWD`) and redirection (`read RV < DATA.TXT`).
# Boot default unchanged; markers single writes.

vgate_name live-sh-tools "#1130 SD3: TOOL.BIN multicall + shell tool builtins over the host share"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script.txt <<'EOF'
exec TOOL.BIN wc -l DATA.TXT
EOF

vgate_setup_python <<'PY'
import os
run = os.environ["RUN_DIR"]
share = os.path.join(run, "share")
with open(os.path.join(share, "DATA.TXT"), "w") as f:
    f.write("beta\nalpha\ngamma\n")
with open(os.path.join(share, "CUT.TXT"), "w") as f:
    f.write("one:two:three\n")
lines = [
    "echo TOOLS-START",
    "cd /",
    "head -n 2 DATA.TXT",
    "wc -l DATA.TXT",
    "grep alpha DATA.TXT",
    "sort DATA.TXT",
    "printf TOOL-OK",
    "set V=beta",
    "case $V in beta) echo CASE-B;; *) echo CASE-X;; esac",
    "cut -d : -f 1 CUT.TXT",
    "read RV < DATA.TXT; echo READ=$RV",
    "env | grep PWD",
    "echo TOOLS-END",
]
with open(os.path.join(share, "TOOLS.SH"), "w") as f:
    f.write("\n".join(lines) + "\n")
with open(os.path.join(run, "edit2.bin"), "wb") as f:
    f.write(b"exec SH.BIN\r")
with open(os.path.join(run, "edit3.bin"), "wb") as f:
    f.write(b"source TOOLS.SH\r")
PY

vgate_run 01 -- --screen '$RUN_DIR/screen' --script '$RUN_DIR/script.txt' --script2 '$RUN_DIR/edit2.bin' --script2-after 'tool: done status=0' --script3 '$RUN_DIR/edit3.bin' --script3-after 'sh: attached' --script-expect 'TOOLS-END' --timeout 120

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'tool: ready'
vgate_assert 01 serial-contains 'tool: done status=0'
vgate_assert 01 serial-contains '3 DATA.TXT'
vgate_assert 01 serial-contains 'sh: attached'
vgate_assert 01 serial-contains 'TOOLS-START'
vgate_assert 01 serial-contains 'alpha'
vgate_assert 01 serial-contains 'gamma'
vgate_assert 01 serial-contains 'TOOL-OK'
vgate_assert 01 serial-contains 'CASE-B'
vgate_assert 01 serial-contains 'READ=beta'
vgate_assert 01 serial-contains 'PWD=/'
vgate_assert 01 serial-contains 'TOOLS-END'
vgate_assert 01 serial-absent 'CASE-X'
vgate_assert 01 serial-absent '\[EXC\]'
vgate_assert 01 serial-absent '[EXC] parking:'
