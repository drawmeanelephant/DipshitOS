# Real VZ machine-state restore, not a framebuffer snapshot or a reboot.
vgate_name live-vz-restore "Real VZ pause/save/stop/restore/resume preserves a RAM-only clipboard marker"
vgate_share none

vgate_run 01 -- --vz-restore --timeout 90

vgate_assert 01 output-contains 'VZ-RESTORE: validateSaveRestoreSupport passed'
vgate_assert 01 output-contains 'VZ-RESTORE: pause completed state=2'
vgate_assert 01 output-contains 'VZ-RESTORE: saveMachineStateTo completed state=2'
vgate_assert 01 output-contains 'VZ-RESTORE: stop completed state=0'
vgate_assert 01 output-contains 'VZ-RESTORE: restoreMachineStateFrom completed state=2'
vgate_assert 01 output-contains 'VZ-RESTORE: resume completed state=1'
vgate_assert 01 output-contains 'VZ-RESTORE: PASS CPU/memory/device restore; fresh serial query recovered RAM marker'
vgate_assert 01 serial-absent '[EXC]'
vgate_assert 01 python <<'PY'
import os
import re
from pathlib import Path
serial = Path(os.environ['VG_SER']).read_bytes()
markers = re.findall(rb'^clip: (VZSR-[0-9A-F-]{36})$', serial, re.M)
assert len(markers) == 2 and markers[0] == markers[1], markers
assert serial.count(b'VirelaiOS kernel has seized control.') == 1, 'reboot is not restore'
assert serial.count(b'clip: stored') == 1, 'marker must only be written before save'
PY

vgate_run incompatible -- --vz-restore --cvc-snap
vgate_allow_rc incompatible 1
vgate_assert incompatible output-contains 'ERROR: --vz-restore is a standalone headless save/restore probe'

vgate_run unbounded -- --vz-restore --timeout 0
vgate_allow_rc unbounded 1
vgate_assert unbounded output-contains 'ERROR: --vz-restore requires --timeout in (0, 600] seconds'

vgate_run missing -- --timeout --vz-restore
vgate_allow_rc missing 1
vgate_assert missing output-contains 'ERROR: --vz-restore: --timeout requires a value.'

vgate_run invalid -- --vz-restore --timeout banana
vgate_allow_rc invalid 1
vgate_assert invalid output-contains 'ERROR: --vz-restore: --timeout requires a numeric value.'
