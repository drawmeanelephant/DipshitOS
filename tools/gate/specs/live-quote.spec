# live-quote.spec -- quoting & escaping: single-quote grouping,
# double-quote expansion, backslash and quoted/escaped operators.
# Mirrors tools/verify-live-quote.sh (M19 P5, issue #294).

vgate_name live-quote "quoting and escaping on VZ"
vgate_repeat 1 BOOTS
vgate_fmt boot/src/*.zig kernel/src/*.zig build.zig

vgate_file script.txt <<'EOF'
echo 'hello world'
set FOO=bar
echo "value $FOO"
echo '$FOO'
echo \$FOO
echo a\;b
echo 'q;b'
echo quote-done
EOF

vgate_run 01 -- --script '$RUN_DIR/script.txt' --script-expect 'quote-done' --timeout 30

vgate_assert 01 serial-contains 'VirelaiOS kernel'
vgate_assert 01 serial-exact 'hello world' 1
vgate_assert 01 serial-exact '$FOO' 2
vgate_assert 01 serial-exact 'a;b' 1
vgate_assert 01 serial-exact 'q;b' 1
vgate_assert 01 serial-contains 'quote-done'
vgate_assert 01 python <<'PY'
import os, sys
# Legacy grep -x -q: at least one whole line exactly 'value bar'.
lines = open(os.environ["VG_SER"], errors="replace").read().splitlines()
if sum(1 for l in lines if l == "value bar") < 1:
    sys.exit("FAIL: no whole 'value bar' line")
print("value expansion ok")
PY
