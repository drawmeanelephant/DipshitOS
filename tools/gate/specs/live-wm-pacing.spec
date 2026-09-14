# live-wm-pacing.spec -- M53 card 1 (#1247): what the desktop's frame cadence
# and input latency ACTUALLY are, measured rather than assumed.
#
# The question this gate exists to answer: in WM mode the kind-18
# COMPOSITE_TICK is 1 Hz (timer.zig `period_ns`), but `pointer_tick` returns
# early once a seat is registered and the present is the WM's own
# REQUEST_PRESENT — so 1 Hz is the HEARTBEAT, not necessarily the cadence.
# Nothing bounded either the rate or the latency before this card.
#
# The latency is measured in its two halves, because they have different
# owners: input sample -> REQUEST_PRESENT (the WM's loop turn) and
# REQUEST_PRESENT -> transfer+flush complete (the kernel + GPU cost). The
# `wm` monitor row reports both, plus the present and tick rates side by side.
#
# This gate proves the INSTRUMENT is live and sane on real hardware. The
# measured VALUES are the card's finding and are reported on the issue, not
# frozen here as a threshold nobody has justified.

vgate_name live-wm-pacing "M53 card 1: measured present cadence + input latency on VZ"
vgate_share seed
# The custom-virtio INPUT queue (the headless-safe pointer transport) is
# SPIKE-gated, exactly like live-wnd-server run 02.
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script.txt <<'EOF'
wm
wnd start
EOF

# Dumped after the burst has had time to land: the `wm` row carries the
# rate window and both latency aggregates.
vgate_file script2.txt <<'EOF'
wm
echo pacing-done
EOF

# ONE headless boot with WND.BIN registered, then a pointer burst.
#
# `--pointer-virtio` injects one HID report per step over the cv-input queue;
# each report becomes one kind-19 pointer sample fanned to the WM
# (`fan_pointer`), which is the LEFT edge of the latency sample. The WM
# answering with REQUEST_PRESENT is the right edge. Steps pace at 2.5 s, so
# 8 steps is a 20 s burst; script2 fires 30 s after `wnd: registered`, i.e.
# comfortably after the burst. The distinct positions matter: a repeated
# coordinate is a sample the WM may coalesce away, which would under-count
# the samples this gate is counting.
vgate_run 01 -- --screen '$RUN_DIR/screen' --via-virtio --cvc-snap \
    --script '$RUN_DIR/script.txt' \
    --pointer-virtio '180,180;340,180;500,180;660,180;820,180;180,360;340,360;500,360' \
    --pointer-virtio-after 'wnd: registered' \
    --script2 '$RUN_DIR/script2.txt' --script2-after 'wnd: registered' --script2-delay 30 \
    --script-expect 'pacing-done' --timeout 260

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'wnd: registered'
vgate_assert 01 serial-contains 'wm: registered pid='
vgate_assert 01 serial-contains 'wm: rate window_ms='
vgate_assert 01 serial-contains 'pacing-done'
vgate_assert 01 serial-absent '[EXC] parking:'

# The instrument is live, tied to a real input burst, and physically sane.
# Deliberately loose: the observed VALUES are the finding (reported on #1247),
# and a tightened bound belongs in the follow-up card that fixes the cadence.
vgate_assert 01 python <<'PY'
import os, re
ser = open(os.environ["VG_SER"]).read()

# The LAST rate row is the one after the burst; an earlier `wm` (the script's
# first command, before `wnd start`) has no registered WM at all.
rows = [l for l in ser.splitlines() if "wm: rate window_ms=" in l]
assert rows, "no 'wm: rate' row in the serial log — the M53 instrument never printed"
row = rows[-1]

def field(name, line):
    m = re.search(name + r"=(\d+)", line)
    assert m, "field %s missing from: %s" % (name, line)
    return int(m.group(1))

window_ms = field("window_ms", row)
present_avg_ms = field("present_avg_ms", row)
tick_avg_ms = field("tick_avg_ms", row)
lat_n = field("lat_n", row)
lat_avg_us = field("lat_avg_us", row)
lat_max_us = field("lat_max_us", row)
flush_n = field("flush_n", row)
flush_max_us = field("flush_max_us", row)

# The desktop presents, more than once (a cadence needs a positive window),
# and the interval is stated rather than a rate that truncates to 0.
assert flush_n >= 2, "fewer than two presents: %s" % row
assert window_ms > 0, "no positive present window: %s" % row
assert present_avg_ms >= 1, "present interval unmeasurable: %s" % row
# The 1 Hz heartbeat is the design, not a measurement — if this row claims
# otherwise the instrument (or the tick period) moved and every comparison
# built on it is wrong. Ticks are counted over the register's whole life, so
# a per-tick drift shows up here; 800..1200 ms is a drift allowance, not a
# target.
assert 800 <= tick_avg_ms <= 1200, "tick_avg_ms=%d is not the 1 Hz heartbeat: %s" % (tick_avg_ms, row)
# Input samples were recorded AND answered: the left edge (a fanned pointer
# sample) and the right edge (the WM's present) both happened.
assert lat_n >= 1, "no input->present latency sample was recorded: %s" % row
assert lat_avg_us > 0, "latency recorded as zero — the clock never advanced: %s" % row
# Sanity ceiling only: the heartbeat period is the worst case for a WM that
# answers on the tick, so anything beyond a few seconds means the accounting
# is broken rather than slow.
assert lat_max_us < 5_000_000, "impossible latency (%d us): %s" % (lat_max_us, row)
assert flush_max_us < 5_000_000, "impossible flush cost (%d us): %s" % (flush_max_us, row)

# The latency samples must come from the INJECTED burst, not a stray sample:
# `ptr_fan` is the kernel's own count of fanned pointer samples, printed in
# the same dump's sibling row. Without this, one incidental sample would
# satisfy lat_n>=1 and the gate would pass on a run whose burst never landed.
fan_rows = [l for l in ser.splitlines() if "wm: ptr_fan=" in l]
assert fan_rows, "no ptr_fan row: the input seam never reported"
ptr_fan = field("ptr_fan", fan_rows[-1])
assert ptr_fan >= 4, "only %d pointer samples fanned — the burst did not land: %s" % (ptr_fan, fan_rows[-1])

print("M53 pacing OBSERVED: window_ms=%d present_avg_ms=%d tick_avg_ms=%d ptr_fan=%d lat_n=%d lat_avg_us=%d lat_max_us=%d flush_n=%d flush_max_us=%d"
      % (window_ms, present_avg_ms, tick_avg_ms, ptr_fan, lat_n, lat_avg_us, lat_max_us, flush_n, flush_max_us))
PY
