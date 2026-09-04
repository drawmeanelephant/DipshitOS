# live-ipc.spec -- the 8-slot kernel mailbox: PEER.BIN echoes
# COUNTER.BIN's bursty sends byte-exact (echoes track sends, all but
# the last in-flight burst echoed, ring peak 5..8, zero ENOSPC, send
# before echo); the mbox invariant holds; both stay running, never
# exit. The pool-full ninth-exec refusal is DIAGNOSTIC in legacy
# (scheduler race) -- recorded nowhere, not asserted here either.
# Mirrors tools/verify-live-ipc.sh (claims 5965/3179). No
# --script-expect (the full window must elapse).

vgate_name live-ipc "mailbox ping/echo flow between live processes on VZ"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE
vgate_repeat 1 BOOTS

vgate_file script1.txt <<'EOF'
ls
exec PEER.BIN
exec COUNTER.BIN 1
procs
echo rx-ipc-phase1
EOF

vgate_file script2.txt <<'EOF'
mbox
procs
exec USER.BIN
exec USER.BIN
exec USER.BIN
exec USER.BIN
exec USER.BIN
exec USER.BIN
exec USER.BIN
echo rx-ipc-ok
EOF

vgate_run 01 -- --script '$RUN_DIR/script1.txt' --script-after 'tasks user-el0 exited status=7' --script2 '$RUN_DIR/script2.txt' --script2-after 'peer: got ping 1' --timeout 60

vgate_assert 01 serial-exact 'VirelaiOS kernel has seized control.' 1
vgate_assert 01 serial-count 'PEER.BIN' 2
vgate_assert 01 serial-count 'exec: loaded PEER.BIN size=' 1
vgate_assert 01 serial-count 'exec: loaded COUNTER.BIN size=' 1
vgate_assert 01 serial-exact 'rx-ipc-phase1' 1
vgate_assert 01 serial-exact 'rx-ipc-ok' 1
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
lines = ser.splitlines()
# Two live processes at phase 1: distinct tasks + distinct stacks.
def first_row(name):
    for l in lines:
        if re.search(r"procs: id=[0-9]+ name=%s state=running" % name, l):
            return l
    return None
pr, cr = first_row("PEER.BIN"), first_row("COUNTER.BIN")
if pr is None or cr is None:
    sys.exit("FAIL: peer/counter running rows absent")
nums = {}
for tag, l in (("peer", pr), ("counter", cr)):
    mt = re.search(r".*task=([0-9]+).*", l)
    ms = re.search(r".*stack=0x([0-9a-f]{16}).*", l)
    if not mt or not ms:
        sys.exit("FAIL: %s row missing task/stack" % tag)
    nums[tag] = (mt.group(1), ms.group(1))
if nums["peer"][0] == nums["counter"][0]:
    sys.exit("FAIL: task ids not distinct")
if nums["peer"][1] == nums["counter"][1]:
    sys.exit("FAIL: stack VAs not distinct")
# Data flow: the counter's sends and the peer's byte-exact echoes.
sends = sorted({int(m.group(1)) for m in
                (re.search(r"ipc: ping ([0-9]+)", l) for l in lines) if m})
echoes = sorted({int(m.group(1)) for m in
                 (re.search(r"peer: got ping ([0-9]+)", l) for l in lines) if m})
if len(sends) < 3 or len(echoes) < 3:
    sys.exit("FAIL: sends=%d echoes=%d, want >= 3 each" % (len(sends), len(echoes)))
if [e for e in echoes if e not in sends]:
    sys.exit("FAIL: echoes without sends")
# Every send except the last in-flight burst window (<= 6) is echoed.
rest = [s for s in sends if s <= sends[-1] - 6]
if [s for s in rest if s not in echoes]:
    sys.exit("FAIL: non-tail sends without echoes")
# Burst peak: walk line-anchored events (as legacy's awk does).
sent = echoed = peak = 0
for l in lines:
    if l.startswith("ipc: ping "):
        sent += 1
        peak = max(peak, sent - echoed)
    elif l.startswith("peer: got ping "):
        echoed += 1
if not (5 <= peak <= 8):
    sys.exit("FAIL: ring peak=%d, want 5..8" % peak)
# ZERO refusals (bursts never overflow the 8-slot ring).
if sum(1 for l in lines if "ipc: enospc" in l) != 0:
    sys.exit("FAIL: enospc refusals present")
# First echo lands AFTER the first send (legacy: unanchored grep).
fs = next((i for i, l in enumerate(lines) if "ipc: ping " in l), None)
fe = next((i for i, l in enumerate(lines) if "peer: got ping " in l), None)
if fs is None or fe is None or not (fs < fe):
    sys.exit("FAIL: send/echo order off fs=%s fe=%s" % (fs, fe))
# Mbox drain snapshot: peer pending <= 8 with sent-recv == pending;
# the counter's ring is empty (triple zero).
def mbox(name):
    rows = [l for l in lines if re.search(r"mbox: id=[0-9]+ name=%s" % name, l)]
    return rows[-1] if rows else None
mp = mbox("PEER.BIN")
if mp is None:
    sys.exit("FAIL: no PEER.BIN mbox row")
pp = int(re.search(r".*pending=([0-9]+) .*", mp).group(1))
ps = int(re.search(r".*sent=([0-9]+) .*", mp).group(1))
pr = int(re.search(r".*recv=([0-9]+).*", mp).group(1))
if not (pp <= 8 and ps - pr == pp):
    sys.exit("FAIL: peer mbox invariant off: %r" % mp)
mc = mbox("COUNTER.BIN")
if mc is None:
    sys.exit("FAIL: no COUNTER.BIN mbox row")
cp = int(re.search(r".*pending=([0-9]+) .*", mc).group(1))
cs = int(re.search(r".*sent=([0-9]+) .*", mc).group(1))
cr = int(re.search(r".*recv=([0-9]+).*", mc).group(1))
if not (cp == 0 and cs == 0 and cr == 0):
    sys.exit("FAIL: counter mbox not empty: %r" % mc)
# Both STILL running at the final read; neither ever exited.
if first_row("PEER.BIN") is None or first_row("COUNTER.BIN") is None:
    sys.exit("FAIL: final running rows absent")
if (sum(1 for l in lines if "name=PEER.BIN state=exited" in l) != 0 or
        sum(1 for l in lines if "name=COUNTER.BIN state=exited" in l) != 0):
    sys.exit("FAIL: a party exited")
print("ipc flow + mbox + liveness ok (peak=%d)" % peak)
PY
