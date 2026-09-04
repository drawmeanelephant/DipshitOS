# live-scripting.spec -- scripting + tab completion: `sh` runs a
# share file once (no re-execution, no nested scripts, missing file
# diagnosed) and Tab completes commands/cycles candidates/completes
# args and share filenames. The script carries TAB bytes, so it is a
# generated fixture (a heredoc cannot show tabs honestly).
# Mirrors tools/verify-live-scripting.sh (M18 T16 + issue #783).

vgate_name live-scripting "sh scripts + tab completion on VZ"
vgate_share arm
vgate_runner_flags -Xswiftc -DSPIKE
vgate_fmt boot/src/*.zig kernel/src/*.zig build.zig
vgate_repeat 1 BOOTS

vgate_setup_python <<'PY'
import os
script = (b"write SCRIPT.TXT echo t16-first-marker\n"
          b"sh SCRIPT.TXT\n"
          b"write INNER.TXT echo t16-inner-ran\n"
          b"write NESTED.TXT sh INNER.TXT\n"
          b"sh NESTED.TXT\n"
          b"sh MISSING.TXT\n"
          b"write COMPL.TXT echo t16-compl-file-ok\n"
          b"echo t16-scripting-ok\n"
          b"ver\t\n"
          b"ca\t\t\n"
          b"color o\t\t\n"
          b"cat COMP\t\n"
          b"echo t16-completion-ok\n")
open(os.path.join(os.environ["RUN_DIR"], "script.txt"), "wb").write(script)
print("scripting script ok")
PY

vgate_run 01 -- --script '$RUN_DIR/script.txt' --script-expect 't16-completion-ok' --timeout 30

vgate_assert 01 serial-contains 'VirelaiOS kernel'
vgate_assert 01 serial-contains 'sh: scripts cannot call scripts'
vgate_assert 01 serial-contains 'sh: MISSING.TXT: not found (no such file on the host share)'
vgate_assert 01 serial-contains 'virelai-kernel'
vgate_assert 01 serial-contains 'usage: cat <file|path>'
vgate_assert 01 serial-contains 'color: on'
vgate_assert 01 serial-contains 't16-compl-file-ok'
vgate_assert 01 serial-contains 't16-completion-ok'
vgate_assert 01 python <<'PY'
import os, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
# Legacy -oF OCCURRENCE counts (not line counts): the marker twice
# (typed write echo + script output; a re-execution adds a third),
# the inner marker once (it must NOT run).
if ser.count("t16-first-marker") != 2:
    sys.exit("FAIL: first-marker occurrences=%d, want 2" % ser.count("t16-first-marker"))
if ser.count("t16-inner-ran") != 1:
    sys.exit("FAIL: inner-ran occurrences=%d, want 1" % ser.count("t16-inner-ran"))
print("scripting occurrence counts ok")
PY
