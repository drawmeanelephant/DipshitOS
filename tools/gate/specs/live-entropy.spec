# live-entropy.spec -- REAL virtio entropy (DID 0x1044) seeds the
# ChaCha20 CSPRNG: per-boot `random 32` shape + ASLR-band boot stack
# + nonzero exec stack, and the cross-boot non-determinism proof
# (two boots, different hex AND different stack VAs).
# Mirrors tools/verify-live-entropy.sh (claim 2665). Format decision
# (explicit): TWO vgate_run TAGs (E1, E2) with identical flags instead
# of vgate_repeat -- per-boot asserts are declared per TAG, and E2's
# python reads E1's persisted serial ($RUN_DIR/vm-serial-E1.log) for
# the cross-boot comparison. No harness change needed.

vgate_name live-entropy "virtio entropy seed + cross-boot non-determinism on VZ"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE
vgate_repeat 1 BOOTS

vgate_file script.txt <<'EOF'
pci
random 32
exec USER.BIN
echo rx-entropy-ok
EOF

vgate_run E1 -- --script '$RUN_DIR/script.txt' --script-after 'tasks user-el0 exited status=7' --script-expect 'tasks user-exec reaped' --timeout 60
vgate_run E2 -- --script '$RUN_DIR/script.txt' --script-after 'tasks user-el0 exited status=7' --script-expect 'tasks user-exec reaped' --timeout 60

vgate_assert E1 serial-exact 'VirelaiOS kernel has seized control.' 1
vgate_assert E1 serial-exact 'entropy: seeded n=64' 1
vgate_assert E1 serial-count 'DID=0x0000000000001044' 1
vgate_assert E1 serial-count 'exec: loaded USER.BIN size=' 1
vgate_assert E1 serial-exact 'rx-entropy-ok' 1
vgate_assert E1 serial-absent '[EXC] parking:'
vgate_assert E1 python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
lines = ser.splitlines()
# Boot-time ASLR: the static payload's stack VA is in-band.
m = None
for l in lines:
    if "aslr: boot user stack=" in l:
        m = re.search(r".*stack=0x([0-9a-f]{16}).*", l)
        break
if not m:
    sys.exit("FAIL: no boot ASLR stack line")
if not (0x10000000 <= int(m.group(1), 16) < 0x80000000):
    sys.exit("FAIL: boot stack out of band: %s" % m.group(1))
# `random 32`: exactly 64 lowercase hex chars after hex= (anchored).
rline = next((l for l in lines if "random: n=32 hex=" in l), None)
if rline is None:
    sys.exit("FAIL: no random line")
mh = re.search(r".*hex=([0-9a-f]+)$", rline)
if not mh or len(mh.group(1)) != 64:
    sys.exit("FAIL: random hex not 64 chars")
# The exec'd stack VA is nonzero.
me = None
for l in lines:
    if "exec: loaded USER.BIN" in l:
        me = re.search(r".*stack=0x([0-9a-f]{16}).*", l)
        break
if not me or me.group(1) == "0000000000000000":
    sys.exit("FAIL: exec stack VA missing or zero")
print("entropy per-boot ok")
PY

vgate_assert E2 serial-exact 'VirelaiOS kernel has seized control.' 1
vgate_assert E2 serial-exact 'entropy: seeded n=64' 1
vgate_assert E2 serial-count 'DID=0x0000000000001044' 1
vgate_assert E2 serial-count 'exec: loaded USER.BIN size=' 1
vgate_assert E2 serial-exact 'rx-entropy-ok' 1
vgate_assert E2 serial-absent '[EXC] parking:'
vgate_assert E2 python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
lines = ser.splitlines()
# Same per-boot shape as E1.
m = None
for l in lines:
    if "aslr: boot user stack=" in l:
        m = re.search(r".*stack=0x([0-9a-f]{16}).*", l)
        break
if not m:
    sys.exit("FAIL: no boot ASLR stack line")
if not (0x10000000 <= int(m.group(1), 16) < 0x80000000):
    sys.exit("FAIL: boot stack out of band: %s" % m.group(1))
rline = next((l for l in lines if "random: n=32 hex=" in l), None)
if rline is None:
    sys.exit("FAIL: no random line")
mh = re.search(r".*hex=([0-9a-f]+)$", rline)
if not mh or len(mh.group(1)) != 64:
    sys.exit("FAIL: random hex not 64 chars")
me = None
for l in lines:
    if "exec: loaded USER.BIN" in l:
        me = re.search(r".*stack=0x([0-9a-f]{16}).*", l)
        break
if not me or me.group(1) == "0000000000000000":
    sys.exit("FAIL: exec stack VA missing or zero")
print("entropy per-boot ok")
PY
vgate_assert E2 python <<'PY'
import os, re, sys
def grab(path):
    ser = open(path, errors="replace").read()
    lines = ser.splitlines()
    rline = next((l for l in lines if "random: n=32 hex=" in l), None)
    hexv = re.search(r".*hex=([0-9a-f]+)$", rline).group(1) if rline else None
    eline = next((l for l in lines if "exec: loaded USER.BIN" in l), None)
    stack = re.search(r".*stack=0x([0-9a-f]{16}).*", eline).group(1) if eline else None
    bline = next((l for l in lines if "aslr: boot user stack=" in l), None)
    boot = re.search(r".*stack=0x([0-9a-f]{16}).*", bline).group(1) if bline else None
    return hexv, stack, boot
run_dir = os.environ["RUN_DIR"]
e1 = grab(os.path.join(run_dir, "vm-serial-E1.log"))
e2 = grab(os.environ["VG_SER"])
# Cross-boot non-determinism: all three pairs differ (legacy
# requires BOOTS distinct values with BOOTS=2).
for tag, a, b in (("random hex", e1[0], e2[0]), ("exec stack", e1[1], e2[1]), ("boot stack", e1[2], e2[2])):
    if a is None or b is None or a == b:
        sys.exit("FAIL: %s not distinct across boots: %s vs %s" % (tag, a, b))
print("entropy non-determinism ok")
PY
