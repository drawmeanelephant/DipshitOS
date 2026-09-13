# go-args.spec -- issue #1163 B2 (phase 0b round 1) + issue #1226 envp half.
#
# Proves the whole argv+envp chain for GOOS=virelai programs on real VZ:
#   1. `set GOMAXPROCS=1` then `exec GOARGS.ELF alpha beta` — the gap
#      loader prepends the program name, packs the card-3e argv block and
#      the envp block (kernel shell env table as KEY=VALUE slots) into the
#      writable segment's reserved tail page.
#   2. The GOOS rt0 stub converts both blocks to a SysV char* array
#      (argv…/NULL/envp…/NULL) and hands it to rt0_go (R0=argc, R1=argv).
#   3. goenvs builds runtime.argslice and runtime.envs.
#   4. The fixture prints both vectors through runtime.VirelaiArgs /
#      VirelaiEnvs, and runtime.GOMAXPROCS(0) == 1 — the env override
#      (numCPUStartup stays 2; ADR 0027 D6).
#
# SCOPE: argv/envp are wired on the GAP-layout path only (the Go linker
# shape). The contiguous ELF path still refuses args (.no_args_room) —
# DSK1's own argv block covers native Zig tools today; extending
# contiguous ELFs is a follow-up card if a need shows up.
#
# HOST PREREQUISITE (not hermetic — see tools/go/README.md):
# `just go-toolchain` must have produced .build/go/GOARGS.ELF + GOHELLO.ELF.
#
# exec-order: assert-proven -- the run's --script-expect IS the program's
# own output (`go-args n=3 ...`), so a green run always proves the exec'd
# program ran; there is no script-echo race (the go-hello/go-args echo
# waits were removed after one live flake — a flaky FAIL on a loaded host,
# never a false pass, tools/gate/SPEC.md).
#
# Note: the go-args fixture asserts the program NAME too — argv[0] is the
# exec'd file, matching the Go convention.

vgate_name go-args "issue #1163 B2 / #1226: raw-ELF exec argv+envp -> Go os.Args / GOMAXPROCS on VZ"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

# Wait on the program's own output line (same race fix as go-hello).
vgate_file script.txt <<'EOF'
set GOMAXPROCS=1
exec GOARGS.ELF alpha beta
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

vgate_run 01 -- --script '$RUN_DIR/script.txt' --script-expect 'go-args n=3' --timeout 120

vgate_assert 01 serial-contains 'exec: loaded GOARGS.ELF'
vgate_assert 01 serial-contains 'go-args n=3'
vgate_assert 01 serial-contains '[GOARGS.ELF] [alpha] [beta]'
vgate_assert 01 serial-contains 'go-args env n=1'
vgate_assert 01 serial-contains '[GOMAXPROCS=1]'
vgate_assert 01 serial-contains 'go-args procs=1'
vgate_assert 01 serial-absent '[EXC] parking:'
