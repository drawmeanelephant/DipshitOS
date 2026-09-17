# go-r3d.spec -- class-B gate for the moonshot: a from-scratch Go EL0
# software triangle rasterizer (GOR3D.ELF, user/go/r3d) full-viewport inside
# Zig TABWM, painted through the ADR 0007 fill batcher via user/go/tabapp.
#
# The proof is a committed golden: the host-side framebuffer snapshot
# (custom-virtio scanout stream, raw BGRX) taken after `gor3d: present` must
# SHA-256-match user/go/r3d/golden/viewport.sha256 over the app viewport the
# rasterizer owns (scene pixels scaled x5 into the 1100x720 tab canvas by
# windowSink; TABWM chrome is excluded by cropping it out).
#
# HOST PREREQUISITE (fails the gate honestly when missing):
#   bash tools/go/build-gor3d.sh   ->  .build/go/GOR3D.ELF
#
# exec-order: assert-proven -- the run ends on `rx-gor3d-ok`, which only the
# script prints, and the stage gate that forwards the close waits on the
# app's own `gor3d: present`; a program that never ran cannot pass.

vgate_name go-r3d "moonshot: a from-scratch Go EL0 software triangle rasterizer full-viewport in Zig TABWM on VZ, matched against a committed golden"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script.txt <<'EOF'
tabwm
tabwm start
EOF

vgate_file script2.txt <<'EOF'
exec GOR3D.ELF
EOF

vgate_file script3.txt <<'EOF'
dui close 2
echo rx-gor3d-ok
EOF

vgate_setup_python <<'PY'
import os, shutil, sys
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
src = os.path.join(".build", "go", "GOR3D.ELF")
if not os.path.exists(src):
    sys.exit("GOR3D.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-gor3d.sh")
shutil.copy(src, os.path.join(share, "GOR3D.ELF"))
print("staged GOR3D.ELF into share (%d bytes)" %
      os.path.getsize(os.path.join(share, "GOR3D.ELF")))
PY

vgate_run 01 -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --snapshot-out '$RUN_DIR/snap-01' \
    --snapshot-after 'gor3d: present' \
    --script '$RUN_DIR/script.txt' \
    --script2 '$RUN_DIR/script2.txt' \
    --script2-after 'tabwm: sidebar-rendered' \
    --script3 '$RUN_DIR/script3.txt' \
    --script3-after 'gor3d: present' \
    --script-expect 'rx-gor3d-ok' --timeout 240

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'tabwm: starting TABWM.BIN'
vgate_assert 01 serial-contains 'tabwm: registered'
vgate_assert 01 serial-contains 'tabwm: sidebar-rendered'
vgate_assert 01 serial-contains 'exec: loaded GOR3D.ELF'
vgate_assert 01 serial-contains 'gor3d: open id='
vgate_assert 01 serial-contains 'gor3d: declare accepted'
vgate_assert 01 serial-contains 'gor3d: present'
vgate_assert 01 serial-contains 'rx-gor3d-ok'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 serial-absent 'exited status=139'

# The load-bearing assert: the raw BGRX scanout snapshot, cropped to the
# rasterizer's canvas minus TABWM chrome, must SHA-256-match the committed
# golden. The app canvas is the 1100x720 viewport at x=180 (TABWM sidebar);
# TABWM paints its 16px tab strip over the top and a 1-3px border ring right/
# bottom, so the chrome-free interior is x 184..1276, y 16..716 (1093x701).
# The scene is the fixed 0.6 rad cube pose (five-times upscaled by
# windowSink), so any rasterizer regression (wrong triangle, wrong depth
# order, missing face, broken clip) moves the hash.
vgate_assert 01 snapshot 'snap-01-*.raw' <<'PY'
import hashlib, os, sys
path = sys.argv[1]
data = open(path, "rb").read()
W = 1280
STRIDE = W * 4
if len(data) < STRIDE * 720:
    sys.exit("snapshot too small: %d bytes" % len(data))
X0, X1 = 184, 1276
Y0, Y1 = 16, 716
gold = os.path.join("user", "go", "r3d", "golden", "viewport.sha256")
want = open(gold).read().strip()
h = hashlib.sha256()
for y in range(Y0, Y1 + 1):
    base = y * STRIDE + X0 * 4
    h.update(data[base:base + (X1 - X0 + 1) * 4])
got = h.hexdigest()
if got != want:
    sys.exit("VIEWPORT MISMATCH: got %s want %s (%s)" % (got, want, path))
print("viewport golden matched: %s" % got)
PY
