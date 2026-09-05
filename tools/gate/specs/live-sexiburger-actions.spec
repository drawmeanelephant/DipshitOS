# live-sexiburger-actions.spec -- M19 Sexiburger Action Registry & Tab Model

vgate_name live-sexiburger-actions "M19 Sexiburger Action Registry & Tab Model"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script-A.txt <<'EOF'
wnd start
exec NOTEPAD.BIN
EOF

vgate_file s2-A.txt <<'EOF'
exec SEXITEST.BIN
echo sexitest-go
EOF

vgate_file s3-A.txt <<'EOF'
dui
wm
sexiburger
echo sexitest-done
EOF

vgate_run A -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --script '$RUN_DIR/script-A.txt' \
    --script2 '$RUN_DIR/s2-A.txt' --script2-after "notepad: ready" --script2-delay 6 \
    --script3 '$RUN_DIR/s3-A.txt' --script3-after "sexitest: done" --script3-delay 8 \
    --script-expect "sexitest-done" --timeout 240

vgate_assert A serial-contains "wnd: action-registered section=2 label=Sexitest Action verb=test-act"
vgate_assert A serial-contains "sexitest: register-ack applied=yes"
vgate_assert A serial-contains "wnd: action-invoked label=Sexitest Action"
vgate_assert A serial-contains "sexitest: action executed: Sexitest Action ok=1"
vgate_assert A serial-contains "wnd: tab-attach"
vgate_assert A serial-contains "sexitest: tab-attached ok=1"
vgate_assert A serial-contains "wnd: tab-cycle"
vgate_assert A serial-contains "sexitest: tab-cycled ok=1"
vgate_assert A serial-contains "wnd: tab-detach"
vgate_assert A serial-contains "sexitest: tab-detached ok=1"
vgate_assert A serial-contains "SEXIBURGER ONLINE"
vgate_assert A serial-absent "[EXC] parking:"
