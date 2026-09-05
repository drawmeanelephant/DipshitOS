# live-tabs.spec -- M20 U5: tab stops in guest-streamed pixels on VZ

vgate_name live-tabs "M20 U5: tab stops in guest-streamed pixels"
vgate_share none
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file input-A.txt <<'EOF'
text clear
text putraw "AAAAAAAB\tZ"
echo m20-tabs-probeA
EOF

vgate_file settle-A.txt <<'EOF'
text clear
text putraw "AAAAAAAB\tZ"
echo m20-tabs-probeA-settled
EOF

vgate_file done-A.txt <<'EOF'
echo m20-tabs-probeA-done
EOF

vgate_file input-B.txt <<'EOF'
text clear
text putraw "AAAAAAAABZ"
echo m20-tabs-probeB
EOF

vgate_file settle-B.txt <<'EOF'
text clear
text putraw "AAAAAAAABZ"
echo m20-tabs-probeB-settled
EOF

vgate_file done-B.txt <<'EOF'
echo m20-tabs-probeB-done
EOF

# --- boot A: the tabbed probe ---
vgate_run A -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --snapshot-after "m20-tabs-probeA-settled" \
    --snapshot-out '$RUN_DIR/snap-A' \
    --script '$RUN_DIR/input-A.txt' \
    --script2 '$RUN_DIR/settle-A.txt' --script2-after "m20-tabs-probeA" --script2-delay 25 \
    --script3 '$RUN_DIR/done-A.txt' --script3-after "m20-tabs-probeA-settled" --script3-delay 25 \
    --script-expect "m20-tabs-probeA-done" --timeout 150

vgate_assert A snapshot 'snap-A-*.raw' <<'PY'
import sys, subprocess, re
path = sys.argv[1]
res = subprocess.run(["python3", "tools/decode-screen-glyphs.py", "--raw", "1280", "720", path], capture_output=True, text=True)
assert res.returncode == 0, f"decoder failed: {res.stderr}"
out = res.stdout
assert re.search(r'^ {3}AAAAB {8}Ztext put: ok$', out, re.M), f"decoded probe failed: {out}"
m = re.search(r'fwd_unknowns=([0-9]*)', out)
assert m and int(m.group(1)) <= 2, f"too many unknowns: {m}"
PY

# --- boot B: the adjacent control ---
vgate_run B -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --snapshot-after "m20-tabs-probeB-settled" \
    --snapshot-out '$RUN_DIR/snap-B' \
    --script '$RUN_DIR/input-B.txt' \
    --script2 '$RUN_DIR/settle-B.txt' --script2-after "m20-tabs-probeB" --script2-delay 25 \
    --script3 '$RUN_DIR/done-B.txt' --script3-after "m20-tabs-probeB-settled" --script3-delay 25 \
    --script-expect "m20-tabs-probeB-done" --timeout 150

vgate_assert B snapshot 'snap-B-*.raw' <<'PY'
import sys, subprocess, re
path = sys.argv[1]
res = subprocess.run(["python3", "tools/decode-screen-glyphs.py", "--raw", "1280", "720", path], capture_output=True, text=True)
assert res.returncode == 0, f"decoder failed: {res.stderr}"
out = res.stdout
assert re.search(r'^ {3}AAAAABZtext put: ok$', out, re.M), f"decoded control failed: {out}"
m = re.search(r'fwd_unknowns=([0-9]*)', out)
assert m and int(m.group(1)) <= 2, f"too many unknowns: {m}"
PY
