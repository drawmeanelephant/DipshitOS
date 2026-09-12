# go-args.spec -- issue #1163 B2 (phase 0b round 1): raw-ELF exec argv.
#
# Proves the whole argv chain for GOOS=virelai programs on real VZ:
#   1. `exec GOARGS.ELF alpha beta` — the gap loader prepends the program
#      name and packs the card-3e argv block into the writable segment's
#      reserved tail page.
#   2. The GOOS rt0 stub converts the block to a SysV char* array and
#      hands it to rt0_go (R0=argc, R1=argv).
#   3. goenvs builds runtime.argslice from argc/argv.
#   4. The fixture prints the vector through runtime.VirelaiArgs (the
#      linkname accessor os.Args will use once the os package lands in
#      phase 2).
#
# SCOPE: argv is wired on the GAP-layout path only (the Go linker shape).
# The contiguous ELF path still refuses args (.no_args_room) — DSK1's own
# argv block covers native Zig tools today; extending contiguous ELFs is a
# follow-up card if a need shows up.
#
# HOST PREREQUISITE (not hermetic — see tools/go/README.md):
# `just go-toolchain` must have produced .build/go/GOARGS.ELF + GOHELLO.ELF.
#
# exec-order: assert-proven -- the run cannot go green without the program's
# own output (`go-args n=3 [GOARGS.ELF] [alpha] [beta]`), so `echo
# go-args-done` is not what proves it ran. Same residual risk as go-hello:
# a flaky FAIL on a loaded host, never a false pass (tools/gate/SPEC.md).
#
# Note: the go-args fixture asserts the program NAME too — argv[0] is the
# exec'd file, matching the Go convention.

vgate_name go-args "issue #1163 B2: raw-ELF exec argv -> Go os.Args chain on VZ"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script.txt <<'EOF'
exec GOARGS.ELF alpha beta
echo go-args-done
EOF

vgate_setup_python <<'PY'
import os, shutil, sys
share = os.path.join(os.environ["RUN_DIR"], "share")
for name in ("GOARGS.ELF", "GOHELLO.ELF"):
    src = os.path.join(".build", "go", name)
    if not os.path.exists(src):
        sys.exit(name + " missing (expected " + src + ") - "
                 "build the fork binaries first: just go-toolchain "
                 "(fork prerequisites in tools/go/README.md)")
    shutil.copy(src, os.path.join(share, name))
print("staged GOARGS.ELF + GOHELLO.ELF into share")
PY

vgate_run 01 -- --script '$RUN_DIR/script.txt' --script-expect 'go-args-done' --timeout 120

vgate_assert 01 serial-contains 'exec: loaded GOARGS.ELF'
vgate_assert 01 serial-contains 'go-args n=3'
vgate_assert 01 serial-contains '[GOARGS.ELF] [alpha] [beta]'
vgate_assert 01 serial-absent '[EXC] parking:'
