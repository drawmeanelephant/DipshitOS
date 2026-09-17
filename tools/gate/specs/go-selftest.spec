# go-selftest.spec -- M61b/M61c (issues #1382/#1383) class-B gate: the first
# guest-owned pass/fail in the fleet. GOSELF.ELF runs a built-in case list on
# the fixtures the host seeded under IN/, writes /host/SELFTEST/REPORT.txt +
# OUT/ receipts on the share, then prints the serial contract of ADR 0031
# (`selftest: FAIL n=<N>`, `selftest OK`).
#
# Serial is the heartbeat; the files are the proof. The load-bearing asserts
# read $VG_SHARE on the HOST, so an app that printed `selftest: FAIL n=0`
# without writing the report cannot pass. The run ends on the program's own
# summary marker (SPEC.md idiom 1): a run whose summary never appears fails on
# the expect deadline.
#
# The intake cases (M61c) are the anti-embedding test. The host seeds two
# fixtures with DIFFERENT bodies (IN/fixture.txt = the canonical bytes,
# IN/altered.txt = the same bytes with one character changed) and the guest
# copies the bytes it actually READ into OUT/. An app that answered from a
# constant compiled into the binary cannot pass this: the copies would not
# match the files macOS holds in the share, and `intake-altered` — which must
# find the altered body, not the canonical one — would report the wrong bytes.
#
# The END-TO-END mutation form of ADR 0031 D2 (rewrite IN/fixture.txt itself,
# watch `intake` FAIL) was run once during M61c and is recorded on issue #1383:
# seed IN/fixture.txt with the altered bytes in the setup hook below and the run
# must end on `case intake fail fixture mismatch: got=25 want=25` +
# `selftest: FAIL n=1`. It is deliberately not a second boot in this spec — the
# mismatch path is regression-tested off-guest (`go test ./selftest`,
# TestIntakeFailsOnAMutatedSeed) and the anti-embedding property is what the
# asserts here cover continuously.
#
# KNOWN ISSUE (#1391, root-caused while building this card): the FIRST
# kernel->user copy into a user buffer whose pages EL0 has never written is
# silently lost on VZ — the syscall reports the right byte count and the app
# reads zeros. The guest's read helper touches its buffer first, which is a
# documented workaround for that defect, not a retry and not a warm-up read:
# the case still requires the fixture's exact bytes and fails, naming #1391
# (`case intake fail read returned 25B of zeros (issue #1391)`), on anything
# else. The host's file channel is not involved (its stdout shows the bytes
# served). Removing the workaround is part of fixing #1391.
#
# The report fixture below is byte-exact on purpose — the report is
# deterministic (ADR 0031). Adding a case in M61d/e updates this fixture.
#
# HOST PREREQUISITE (fails the gate honestly when missing):
#   bash tools/go/build-goself.sh   ->  .build/go/GOSELF.ELF

vgate_name go-selftest "issues #1382/#1383 M61b/M61c: GOSELF.ELF runs the guest self-test cases over host-seeded intake fixtures; the host reads REPORT.txt and the OUT/ receipts on the share"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script.txt <<'EOF'
tabwm
tabwm start
EOF

vgate_file script2.txt <<'EOF'
exec GOSELF.ELF
EOF

vgate_setup_python <<'PY'
import os, shutil, sys
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
src = os.path.join(".build", "go", "GOSELF.ELF")
if not os.path.exists(src):
    sys.exit("GOSELF.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-goself.sh")
shutil.copy(src, os.path.join(share, "GOSELF.ELF"))
st = os.path.join(share, "SELFTEST")
for d in ("IN", "OUT"):
    os.makedirs(os.path.join(st, d), exist_ok=True)
# The intake fixtures (ADR 0031 D2). The two bodies must differ, and the guest
# must report them differently: see the header.
fixture = b"goself intake fixture v1\n"
altered = b"goself intake fixture v2\n"
for name, body in (("fixture.txt", fixture), ("altered.txt", altered)):
    with open(os.path.join(st, "IN", name), "wb") as fh:
        fh.write(body)
print("staged GOSELF.ELF into share (%d bytes) and %s/{IN,OUT}; seeded "
      "IN/fixture.txt %r and IN/altered.txt %r"
      % (os.path.getsize(os.path.join(share, "GOSELF.ELF")), st, fixture, altered))
PY

vgate_run 01 -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio \
    --script '$RUN_DIR/script.txt' \
    --script2 '$RUN_DIR/script2.txt' \
    --script2-after 'tabwm: sidebar-rendered' \
    --script-expect 'selftest: FAIL n=' --timeout 240

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'tabwm: starting TABWM.BIN'
vgate_assert 01 serial-contains 'tabwm: registered'
vgate_assert 01 serial-contains 'tabwm: sidebar-rendered'
vgate_assert 01 serial-contains 'exec: loaded GOSELF.ELF'
vgate_assert 01 serial-contains 'goself: open id='
vgate_assert 01 serial-contains 'goself: declare accepted'
# Per-case heartbeat lines, printed only after the case's syscalls returned.
vgate_assert 01 serial-contains 'selftest: case intake pass'
vgate_assert 01 serial-contains 'selftest: case intake-altered pass'
vgate_assert 01 serial-contains 'selftest: case clock-monotonic pass'
vgate_assert 01 serial-contains 'selftest: case file-write pass'
# The files were written BEFORE the summary (ADR 0031 ordering).
vgate_assert 01 serial-contains 'selftest: report /host/SELFTEST/REPORT.txt n='
vgate_assert 01 serial-contains 'selftest: summary /host/SELFTEST/OUT/summary.txt n='
vgate_assert 01 serial-contains 'goself: present'
# The contract line: n=0 means every case passed (the spec stops on this line).
vgate_assert 01 serial-contains 'selftest: FAIL n=0'
vgate_assert 01 serial-contains 'selftest OK'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 serial-absent 'exited status=139'

# The load-bearing assert: the report, the intake copies and the receipts on the
# host's own filesystem must be byte-exact. A marker that reported success
# without writing the bytes cannot pass this. The share is a per-run temp dir
# deleted at gate_end, so the files this spec relied on are copied into
# artifacts/ as evidence (ADR 0031 D4).
#
# The report copy is named `go-selftest-share-report.txt`, NOT
# `go-selftest-report.txt`: the harness already owns `artifacts/NAME-report.txt`
# (SPEC.md's per-gate report), and a copy to that name clobbers it.
vgate_assert 01 python <<'PY'
import os, shutil
share = os.environ["VG_SHARE"]
suffix = os.environ.get("VIRELAI_GATE_SUFFIX", "")
fixture = b"goself intake fixture v1\n"
altered = b"goself intake fixture v2\n"
want_report = (b"case intake pass\n"
               b"case intake-altered pass\n"
               b"case clock-monotonic pass\n"
               b"case file-write pass\n"
               b"summary cases=4 failed=0\n")
want_summary = b"summary cases=4 failed=0\n"
want_hello = b"goself smoke\n"
want_intake_receipt = b"case intake path=IN/fixture.txt bytes=25 match=yes\n"
want_altered_receipt = b"case intake-altered path=IN/altered.txt bytes=25 differs=yes\n"

st = os.path.join(share, "SELFTEST")
out = os.path.join(st, "OUT")


def read(path, what):
    with open(path, "rb") as fh:
        return fh.read()


def require(path, want, what):
    got = read(path, what)
    if got != want:
        print("%s MISMATCH (%s):\n got %r\nwant %r" % (what, path, got, want))
        raise SystemExit(1)
    return got


report = require(os.path.join(st, "REPORT.txt"), want_report, "REPORT")
require(os.path.join(out, "summary.txt"), want_summary, "SUMMARY")
require(os.path.join(out, "hello.txt"), want_hello, "HELLO")
# The guest read the fixtures it says it read: these copies hold the bytes the
# share held, not the constant the binary carries.
require(os.path.join(out, "fixture.copy"), fixture, "FIXTURE COPY")
require(os.path.join(out, "altered.copy"), altered, "ALTERED COPY")
require(os.path.join(out, "intake.txt"), want_intake_receipt, "INTAKE RECEIPT")
require(os.path.join(out, "intake-altered.txt"), want_altered_receipt, "ALTERED RECEIPT")
# The host owns IN/: neither case may have written there (ADR 0031 D2).
require(os.path.join(st, "IN", "fixture.txt"), fixture, "IN/FIXTURE (guest wrote it?)")
require(os.path.join(st, "IN", "altered.txt"), altered, "IN/ALTERED (guest wrote it?)")

os.makedirs("artifacts", exist_ok=True)
for name, path in (("report", os.path.join(st, "REPORT.txt")),
                   ("intake.txt", os.path.join(out, "intake.txt")),
                   ("intake-altered.txt", os.path.join(out, "intake-altered.txt")),
                   ("fixture.copy", os.path.join(out, "fixture.copy")),
                   ("altered.copy", os.path.join(out, "altered.copy"))):
    shutil.copy(path, "artifacts/go-selftest-share-%s%s" % (name, suffix))
print("host read-back byte-exact: REPORT.txt %d B, OUT/fixture.copy %d B, "
      "OUT/altered.copy %d B, receipts %d + %d B"
      % (len(report), len(fixture), len(altered),
         len(want_intake_receipt), len(want_altered_receipt)))
PY
