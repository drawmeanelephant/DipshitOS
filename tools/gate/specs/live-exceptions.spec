# live-exceptions.spec -- exception vectors live on VZ. Mirrors
# tools/verify-live-exceptions.sh (claim 9746): VBAR_EL1 installed, `fault`
# triggers a real sync exception the handler reports and resumes from.

vgate_name live-exceptions "VBAR_EL1 vectors + sync handler, resume"
vgate_repeat 1 BOOTS
vgate_fmt boot/src/*.zig kernel/src/*.zig build.zig
vgate_note "script: help / fault / echo rx-exc-ok"

vgate_file script.txt <<'EOF'
help
fault
echo rx-exc-ok
EOF

vgate_run 01 -- --script '$RUN_DIR/script.txt' --script-expect rx-exc-ok --timeout 40

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'available commands:'
vgate_assert 01 serial-contains 'fault: triggering udf (synchronous exception)...'
vgate_assert 01 serial-contains '[EXC] sync from EL1'
vgate_assert 01 serial-contains 'ec=0x00 unknown-reason'
vgate_assert 01 serial-contains '[EXC] resume-armed: skipping faulting instruction'
vgate_assert 01 serial-contains 'fault: handled, resumed after faulting instruction'
vgate_assert 01 serial-contains 'rx-exc-ok'
