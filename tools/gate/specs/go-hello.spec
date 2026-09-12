# go-hello.spec -- issue #1163, GOOS=virelai phase 0a: the gc Go runtime
# runs on VirelaiOS.
#
# Builds (outside this spec; a machine prerequisite like the Go toolchain
# itself): a fork of the gc toolchain patched with a GOOS=virelai runtime
# (tools/go/ — overlay + wiring, apply.sh), then GOHELLO.ELF linked as a
# static ET_EXEC at the 0x400000 text aperture. The program exercises:
#   * the svc #0 console path (println -> write1 -> sys_write chunking),
#   * the sbrk heap over demand-backed sys_mmap (1 MiB growth + churn),
#   * a full GC cycle (STW at cooperative safe points, mark, sweep),
#   * nanotime via CNTPCT_EL0 (timers + runtime.GC pacing).
# Every assert reads vm-serial.log on real Apple Silicon VZ hardware.
#
# Prerequisite: `bash tools/go/build-go.sh` must have produced
# .build/go/GOHELLO.ELF (the setup hook fails with that exact hint).

vgate_name go-hello "issue #1163 GOOS=virelai phase 0a: gc Go runtime first target on VZ"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE
vgate_repeat 1 BOOTS

vgate_file script.txt <<'EOF'
exec GOHELLO.ELF
echo go-hello-done
EOF

vgate_setup_python <<'PY'
import os, shutil, sys
share = os.path.join(os.environ["RUN_DIR"], "share")
src = os.path.join(".build", "go", "GOHELLO.ELF")
if not os.path.exists(src):
    sys.exit("GOHELLO.ELF missing (expected " + src + ") — "
             "build the fork binary first: bash tools/go/build-go.sh "
             "(fork prerequisites in tools/go/README.md)")
shutil.copy(src, os.path.join(share, "GOHELLO.ELF"))
print("staged GOHELLO.ELF into share (%d bytes)" %
      os.path.getsize(os.path.join(share, "GOHELLO.ELF")))
PY

vgate_run 01 -- --script '$RUN_DIR/script.txt' --script-expect 'go-hello-done' --timeout 120

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'exec: loaded GOHELLO.ELF'
vgate_assert 01 serial-contains 'hello from virelai'
vgate_assert 01 serial-contains 'heap: wrote 1048576 bytes'
vgate_assert 01 serial-contains 'gc: cycle completed'
vgate_assert 01 serial-contains 'virelai-go OK'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 serial-absent 'exited status=139'
