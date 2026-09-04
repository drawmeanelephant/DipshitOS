# live-glob.spec -- shell globbing: *, ?, and [...] all expand to
# both names in sorted order (one shared whole-line count); no match
# stays literal.
# Mirrors tools/verify-live-glob.sh (M19 P6, issue #295). The BRE
# whole-line counts ride serial-exact (fixed-string whole lines).

vgate_name live-glob "glob expansion on VZ"
vgate_share arm
vgate_runner_flags -Xswiftc -DSPIKE
vgate_fmt boot/src/*.zig kernel/src/*.zig build.zig
vgate_repeat 1 BOOTS

vgate_file script.txt <<'EOF'
write ga.bin alpha
write gb.bin beta
echo *.bin
echo g?.bin
echo g[a-b].bin
echo zz*.nomatch
echo glob-done
EOF

vgate_run 01 -- --script '$RUN_DIR/script.txt' --script-expect 'glob-done' --timeout 30

vgate_assert 01 serial-contains 'VirelaiOS kernel'
vgate_assert 01 serial-contains 'ga.bin'
vgate_assert 01 serial-contains 'gb.bin'
vgate_assert 01 serial-exact 'ga.bin gb.bin' 3
vgate_assert 01 serial-exact 'zz*.nomatch' 1
vgate_assert 01 serial-contains 'glob-done'
