# live-forensics.spec -- #1278 class-B gate: the last-words recorder.
#
# What this gate is for: #1261 could not be closed because a dying boot reported
# NOTHING -- no `[EXC]`, no tombstone, just `VZVirtualMachine.State.error` with
# no reason. The recorder's whole claim is that a record reaches serial BEFORE
# the death, so this gate proves the two halves of that claim on real VZ:
#
#   1. OFF BY DEFAULT. The first `forensics status` must report enabled=0, on a
#      boot nothing armed. A recorder that is always on would be paying for
#      itself on every boot, and byte-identical default output is the property
#      that lets it exist at all.
#   2. IT REACHES SERIAL. After `forensics on`, records must appear in the
#      serial log as `fx: site=...` lines -- the IRQ probe (every interrupt the
#      guest services) and the rotation probe (every switch, with the task it
#      switched away from) both have to be there, because those are the two
#      sites a silent death lands between.
#
# The `dump` subcommand is asserted too: it is the path a gate or a human uses
# to force the tail out without waiting for the next ordinary console line.
#
#   3. THE HOST HALF IS WIRED. The runner now reports a stop verdict on every
#      run (`vm-stop: state=… reason=…`). A healthy boot must say VZ reported no
#      reason, which is the one line that disappears if the VZVirtualMachine
#      delegate stops being installed.

vgate_name live-forensics "#1278 -- last-words recorder: off by default, records reach serial"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE
vgate_repeat 1 BOOTS

vgate_file script.txt <<'EOF'
forensics status
forensics on
tasks
forensics dump
forensics status
echo fx-ok
EOF

vgate_run 01 -- --script '$RUN_DIR/script.txt' --script-after "expensive" --timeout 120

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
# (1) Off by default, on a boot nothing armed.
vgate_assert 01 serial-contains 'forensics: enabled=0 pending=0 emitted=0 truncated=0'
# (2) It reaches serial once armed.
vgate_assert 01 serial-contains 'fx: site=irq'
vgate_assert 01 serial-contains 'fx: site=rotate'
vgate_assert 01 serial-contains 'forensics: dump wrote='
vgate_assert 01 serial-contains 'fx-ok'
# (3) The HOST half is wired. The runner now reports a stop verdict on every
# run, and this boot ends with no error, so the verdict must be the explicit
# "none reported" -- the line the pre-#1278 runner never printed at all. It
# fails if the VZ delegate stops being installed (`runner.vm.delegate =`),
# which is precisely how #1261 lost a whole investigation to a bare state=3.
vgate_assert 01 output-contains 'vm-stop: state='
vgate_assert 01 output-contains 'reason=<none reported by VZ>'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"]).read()

rows = re.findall(r'fx: site=(\w+) core=(\d+) seq=(\d+) t=(\d+) arg=(\d+)', ser)
if not rows:
    print("the recorder emitted NOTHING after `forensics on` -- a dying boot "
          "would have gone on reporting nothing", file=sys.stderr)
    sys.exit(1)

sites = {}
for site, core, _seq, _t, _arg in rows:
    sites[site] = sites.get(site, 0) + 1

# The two sites a silent death lands between: the interrupt that was being
# serviced, and the switch that was in flight (with the task it left behind --
# the half an after-the-fact "who is current" dump can never recover).
for required in ("irq", "rotate"):
    if sites.get(required, 0) == 0:
        print("no %s records: %r" % (required, sites), file=sys.stderr)
        sys.exit(1)

# Sequence numbers restart per core and must be dense per core, so a torn or
# dropped record shows up here rather than as a plausible-looking gap.
per_core = {}
for site, core, seq, _t, _arg in rows:
    per_core.setdefault(core, []).append(int(seq))
for core, seqs in per_core.items():
    expected = list(range(len(seqs)))
    if sorted(seqs) != expected:
        print("core %s emitted sequences %r, expected a dense 0..%d"
              % (core, sorted(seqs), len(seqs) - 1), file=sys.stderr)
        sys.exit(1)

# The default-off status line must be the FIRST status the guest printed: if it
# reported enabled=1 there, something armed the recorder without being asked.
first_status = re.search(r'forensics: enabled=(\d+)', ser)
if first_status is None or first_status.group(1) != "0":
    print("the first `forensics status` was not enabled=0: %r"
          % (first_status.group(0) if first_status else None), file=sys.stderr)
    sys.exit(1)

print("forensics OBSERVED: records=%d sites=%s cores=%s"
      % (len(rows), dict(sorted(sites.items())), dict(sorted(per_core.items()))))
PY
