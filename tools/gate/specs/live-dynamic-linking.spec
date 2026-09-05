# live-dynamic-linking.spec -- Milestone 30 Class-B Gate (issue #599, claim 7921):
#
# Freestanding Runtime Linker & Shared Libraries (LD.SO, LIBUI.SO, LIBFONT.SO, DYNAPP.ELF).
#
# The chain, all asserted in vm-serial.log on real Apple Silicon VZ hardware:
#   1. DYNAPP.ELF, LD.SO, LIBUI.SO, LIBFONT.SO live in the host share.
#   2. `exec DYNAPP.ELF` sniffs ELF dynamic executable, loads PT_INTERP (LD.SO),
#      maps interpreter segments and executable segments with strict W^X roots,
#      and constructs the initial Auxiliary Vector (AT_PHDR, AT_ENTRY, AT_BASE, etc.).

vgate_name live-dynamic-linking "Milestone 30 Class-B Gate (issue #599, claim 7921):"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE
vgate_repeat 1 BOOTS

vgate_file script.txt <<'EOF'
ls
exec DYNAPP.ELF
echo rx-dyn-ok
EOF

vgate_run 01 -- --script '$RUN_DIR/script.txt' --script-after "tasks user-el0 exited status=7" --script-expect "tasks user-exec reaped" --timeout 60

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'DYNAPP.ELF'
vgate_assert 01 serial-contains 'exec: loaded DYNAPP.ELF'
vgate_assert 01 serial-contains 'ld.so:'
vgate_assert 01 serial-contains 'dynapp:'
vgate_assert 01 serial-contains 'tasks user-exec exited status=0'
vgate_assert 01 serial-contains 'tasks user-exec reaped'
vgate_assert 01 serial-contains 'rx-dyn-ok'
vgate_assert 01 serial-absent '[EXC] parking:'
