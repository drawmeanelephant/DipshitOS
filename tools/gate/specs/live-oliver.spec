# live-oliver.spec -- a REAL Zig HTML tool (oliver) as a native AArch64 ELF
# app: `exec OLIVER.ELF` reads /host/MD.TXT through the ADR 0010 file table,
# renders Markdown with oliver's own library (commit 3f05bacb, vendored slice
# source in tests/oliver-spike/), and writes /host/OLIVER.HTML back through
# the M34 HF host share. The HTML is asserted HOST-SIDE byte-exact against the
# reference tool's own native CLI output; serial carries the order of events.
# The image is one PT_LOAD R+X at 0x0040_0000, 248,776 B of memory (47.5% of
# `exec_program_max` / `elf.load_max` = 512 KiB; contract check: python3
# tools/check-zc-host-contract.py tests/oliver-spike/OLIVER.ELF).

vgate_name live-oliver "real Zig HTML tool (oliver) as a native ELF app, host-side HTML compare"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE
vgate_repeat 1 BOOTS

vgate_file script1.txt <<'EOF'
exec OLIVER.ELF
echo rx-oliver-rendered
EOF

vgate_setup_python <<'PY'
import os, shutil

run_dir = os.environ["RUN_DIR"]
share = os.path.join(run_dir, "share")
os.makedirs(share, exist_ok=True)

# The pinned native app (tests/oliver-spike/OLIVER.ELF) and its input.
shutil.copy("tests/oliver-spike/OLIVER.ELF", os.path.join(share, "OLIVER.ELF"))
shutil.copy("tests/oliver-spike/md-fixture.txt", os.path.join(share, "MD.TXT"))

# The expected HTML: oliver's own native CLI over the same fixture
# (`oliver render --from markdown < md-fixture.txt`). The app renders with the
# same library entry point (renderOptionsFor's defaults for `render`), so the
# compare is byte-exact -- no timestamp/version stamp is emitted by either
# path (checked: the CLI output has no generated-at or version text).
shutil.copy("tests/oliver-spike/expect.html", os.path.join(run_dir, "EXPECT.HTML"))
PY

vgate_run 01 -- --display --screen '$RUN_DIR/gpu-screen' --script '$RUN_DIR/script1.txt' --script-after "virelai>" --timeout 180

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
# Host-side: the file the GUEST wrote through the share is byte-identical to
# the reference tool's output. Both sha256s are printed so the report carries
# the pin, not just a verdict.
vgate_assert 01 python <<'PY'
import hashlib, os, shutil, sys

run_dir = os.environ["RUN_DIR"]
written = os.path.join(os.environ["VG_SHARE"], "OLIVER.HTML")
expect = os.path.join(run_dir, "EXPECT.HTML")
if not os.path.exists(written):
    print("FAIL: the guest wrote no OLIVER.HTML into the share")
    sys.exit(1)
got = open(written, "rb").read()
want = open(expect, "rb").read()
print("guest share/OLIVER.HTML %d B sha256 %s" % (len(got), hashlib.sha256(got).hexdigest()))
print("host  expect.html      %d B sha256 %s" % (len(want), hashlib.sha256(want).hexdigest()))
# Publish the observed bytes as evidence (the snapshot assert keeps them).
shutil.copy(written, os.path.join(run_dir, "oliver-html-guest.html"))
if got != want:
    for i in range(min(len(got), len(want))):
        if got[i] != want[i]:
            print("FAIL: first byte difference at %d: guest=%r host=%r" % (i, got[i:i+1], want[i:i+1]))
            break
    else:
        print("FAIL: length differs (guest %d, host %d)" % (len(got), len(want)))
    sys.exit(1)
print("byte-exact: guest-written HTML == the reference tool's own output")
PY

vgate_assert 01 snapshot 'oliver-html-guest.html' <<'PY'
import hashlib, sys
data = open(sys.argv[1], "rb").read()
print("evidence: guest-written HTML %d B sha256 %s" % (len(data), hashlib.sha256(data).hexdigest()))
PY

# Order of events + the app's own report (exit status == emitted byte count).
vgate_assert 01 serial-contains 'oliver: wrote 754 bytes'
vgate_assert 01 serial-echo 'exec OLIVER.ELF'
vgate_assert 01 serial-contains 'rx-oliver-rendered'
# FAIL needles: the loader's own refusal/abort shapes (monitor.zig err_prefix +
# the honest-ELF refusals), never the success line `exec: loaded ...`.
vgate_assert 01 serial-absent 'error: '
vgate_assert 01 serial-absent 'not found on the host share'
vgate_assert 01 serial-absent 'image larger than the'
vgate_assert 01 serial-absent 'leaves no room for the argv block'
vgate_assert 01 serial-absent '[EXC] parking:'
