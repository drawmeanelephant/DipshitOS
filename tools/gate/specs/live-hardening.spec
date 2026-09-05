# live-hardening.spec -- claim 4482 (Milestone 14, Card S4)
#
# class-B gate: security/isolation hardening — the hostile-consumer proof,
# live on Apple Virtualization.framework.
#
# Two SEPARATE EL0 processes in one boot (the claim-0826 capacity exec
# gate, no exclusivity):
#
#   VICTIM.BIN  — opens user window 2 (`sys_win_open`, slot 12), fills it,

vgate_name live-hardening "claim 4482 (Milestone 14, Card S4)"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script.txt <<'EOF'
exec VICTIM.BIN
EOF

vgate_file script2.txt <<'EOF'
exec HARDEN.BIN
EOF

vgate_run 01 -- --display --script '$RUN_DIR/script.txt' --script-after "tasks user-el0 exited status=7" --script2 '$RUN_DIR/script2.txt' --script2-after "victim: window=2 ready" --script-expect "tasks user-exec exited status=44" --timeout 90

vgate_assert 01 serial-contains 'victim: window=2 ready'
vgate_assert 01 serial-contains 'hardening: ${op} NOT REFUSED'
vgate_assert 01 serial-contains 'hardening: refused'
vgate_assert 01 serial-contains 'hardening: survived'
vgate_assert 01 serial-contains 'tasks user-exec exited status=44'
vgate_assert 01 serial-contains 'VICTIM.BIN exited'
vgate_assert 01 serial-absent '[EXC] parking:'
