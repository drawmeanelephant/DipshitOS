# go-selftest.spec -- M61b/M61c/M61d (issues #1382/#1383/#1384) class-B gate:
# the first guest-owned pass/fail in the fleet. GOSELF.ELF runs a built-in case
# list on the fixtures the host seeded under IN/, writes
# /host/SELFTEST/REPORT.txt + OUT/ receipts on the share, then prints the
# serial contract of ADR 0031 (`selftest: FAIL n=<N>`, `selftest OK`).
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
# M61d (#1384) adds the file-ABI pack, all of it on the share under
# OUT/_scratch-ish per-case paths: create/write/close/reopen/read-back,
# truncate-then-read, delete-then-reopen-fails, and a directory listing that
# sees a file and then does not. Each case leaves TWO pieces of host-readable
# evidence — a one-line `case <id> …` receipt and, where bytes came back, a
# `.copy` of the bytes it READ (never the bytes it intended) — and the asserts
# below byte-compare all of it. A case that printed a verdict without landing
# the bytes cannot pass.
#
# The M61d cases are checked twice, on purpose. The receipts are the guest's
# claim about itself; the block below ALSO reads the share's own directory
# state on macOS (OUT/deleted.txt absent, OUT/LIST empty, roundtrip.txt 525 B,
# truncate.txt holding exactly the reconstructed 105-byte prefix). Those are
# facts about the filesystem the guest's syscalls left behind, which no receipt
# can fake — and the reconstructed bodies come from the same one-expression
# units the app writes (`b"goself file abi line\n" * n`), not from a fixture
# file. A `.copy` that does not equal the reconstruction fails the gate.
#
# REGRESSION TEST for #1391 (fixed in the kernel, ADR 0032): the first
# kernel->user copy into a user buffer whose pages EL0 has never written used
# to be silently lost on VZ — the syscall reported the right byte count and the
# app read zeros, because the destination page still resolved for EL1 into the
# kernel's EL1-only identity overlay. The guest's read helper does not touch its
# buffer first (that workaround is deleted), and `intake` reads a host-seeded
# fixture into a fresh buffer; the asserts below require the fixture bytes
# back — in the report, in the OUT/ copies and in the receipts. With the defect
# live, this run ended on `case intake fail read returned 25B of zeros (issue
# #1391)` + `selftest: FAIL n=1` (recorded on #1391). The host's file channel
# was never involved (its stdout shows the bytes served). The M61d read-backs
# ride the same path.
#
# The report fixture below is byte-exact on purpose — the report is
# deterministic (ADR 0031). Adding a case in M61e updates this fixture.
#
# HOST PREREQUISITE (fails the gate honestly when missing):
#   bash tools/go/build-goself.sh   ->  .build/go/GOSELF.ELF

vgate_name go-selftest "issues #1382/#1383/#1384 M61b/M61c/M61d: GOSELF.ELF runs the guest self-test cases over host-seeded intake fixtures and the file-ABI case pack; the host reads REPORT.txt and every OUT/ receipt on the share"
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
vgate_assert 01 serial-contains 'selftest: case file-roundtrip pass'
vgate_assert 01 serial-contains 'selftest: case file-truncate pass'
vgate_assert 01 serial-contains 'selftest: case file-delete pass'
vgate_assert 01 serial-contains 'selftest: case file-list pass'
# The files were written BEFORE the summary (ADR 0031 ordering).
vgate_assert 01 serial-contains 'selftest: report /host/SELFTEST/REPORT.txt n='
vgate_assert 01 serial-contains 'selftest: summary /host/SELFTEST/OUT/summary.txt n='
vgate_assert 01 serial-contains 'goself: present'
# The contract line: n=0 means every case passed (the spec stops on this line).
vgate_assert 01 serial-contains 'selftest: FAIL n=0'
vgate_assert 01 serial-contains 'selftest OK'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 serial-absent 'exited status=139'

# The load-bearing assert: the report, the copies and the receipts on the
# host's own filesystem must be byte-exact, and the share's directory state must
# agree with what the cases claim they did. A marker that reported success
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

# The names and bodies are the app's own constants (user/go/selftest). The
# payloads are reconstructed from ONE expression each, so a case that wrote or
# kept the wrong bytes cannot match them.
fixture = b"goself intake fixture v1\n"
altered = b"goself intake fixture v2\n"
unit = b"goself file abi line\n"
roundtrip_body = unit * 25          # 525 B, written then read back whole
truncate_full = unit * 40           # 840 B written, then shrunk
truncate_kept = unit * 5            # 105 B expected after the shrink

want_report = (b"case intake pass\n"
               b"case intake-altered pass\n"
               b"case clock-monotonic pass\n"
               b"case file-write pass\n"
               b"case file-roundtrip pass\n"
               b"case file-truncate pass\n"
               b"case file-delete pass\n"
               b"case file-list pass\n"
               b"summary cases=8 failed=0\n")
want_summary = b"summary cases=8 failed=0\n"
want_hello = b"goself smoke\n"
want_intake_receipt = b"case intake path=IN/fixture.txt bytes=25 match=yes\n"
want_altered_receipt = b"case intake-altered path=IN/altered.txt bytes=25 differs=yes\n"
want_write_receipt = b"case file-write path=OUT/hello.txt bytes=13\n"
want_roundtrip_receipt = b"case file-roundtrip path=OUT/roundtrip.txt bytes=525 match=yes\n"
want_truncate_receipt = (b"case file-truncate path=OUT/truncate.txt wrote=840 kept=105 "
                         b"bytes=105 match=yes\n")
want_delete_receipt = b"case file-delete path=OUT/deleted.txt delete=0 reopen=-6\n"
want_list_receipt = (b"case file-list dir=OUT/LIST file=listed.txt "
                     b"first=seen second=absent\n")

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
# M61d: one receipt per file-ABI case, then the two read-back copies. The
# roundtrip copy is the bytes READ back out of the file the case had just
# written; the truncated copy is the prefix left after the shrink.
require(os.path.join(out, "file-write.ok"), want_write_receipt, "WRITE RECEIPT")
require(os.path.join(out, "file-roundtrip.ok"), want_roundtrip_receipt, "ROUNDTRIP RECEIPT")
require(os.path.join(out, "file-truncate.ok"), want_truncate_receipt, "TRUNCATE RECEIPT")
require(os.path.join(out, "file-delete.ok"), want_delete_receipt, "DELETE RECEIPT")
require(os.path.join(out, "file-list.ok"), want_list_receipt, "LIST RECEIPT")
require(os.path.join(out, "roundtrip.copy"), roundtrip_body, "ROUNDTRIP COPY")
require(os.path.join(out, "truncated.copy"), truncate_kept, "TRUNCATED COPY")

# The guest's claims, cross-checked against the filesystem its syscalls left
# behind. These are independent of the receipts: the receipts say what the case
# believed, this says what the share holds.
require(os.path.join(out, "roundtrip.txt"), roundtrip_body, "ROUNDTRIP FILE")
require(os.path.join(out, "truncate.txt"), truncate_kept, "TRUNCATE FILE (kept prefix)")
if os.path.exists(os.path.join(out, "deleted.txt")):
    print("OUT/deleted.txt still exists - the delete case did not remove it")
    raise SystemExit(1)
list_dir = os.path.join(out, "LIST")
if not os.path.isdir(list_dir):
    print("OUT/LIST is not a directory - the guest's MKDIR did not create it")
    raise SystemExit(1)
if os.listdir(list_dir):
    print("OUT/LIST is not empty after the delete: %r" % sorted(os.listdir(list_dir)))
    raise SystemExit(1)

# The host owns IN/: neither intake case may have written there (ADR 0031 D2).
require(os.path.join(st, "IN", "fixture.txt"), fixture, "IN/FIXTURE (guest wrote it?)")
require(os.path.join(st, "IN", "altered.txt"), altered, "IN/ALTERED (guest wrote it?)")

os.makedirs("artifacts", exist_ok=True)
for name, path in (("report", os.path.join(st, "REPORT.txt")),
                   ("intake.txt", os.path.join(out, "intake.txt")),
                   ("intake-altered.txt", os.path.join(out, "intake-altered.txt")),
                   ("fixture.copy", os.path.join(out, "fixture.copy")),
                   ("altered.copy", os.path.join(out, "altered.copy")),
                   ("file-write.ok", os.path.join(out, "file-write.ok")),
                   ("file-roundtrip.ok", os.path.join(out, "file-roundtrip.ok")),
                   ("file-truncate.ok", os.path.join(out, "file-truncate.ok")),
                   ("file-delete.ok", os.path.join(out, "file-delete.ok")),
                   ("file-list.ok", os.path.join(out, "file-list.ok")),
                   ("roundtrip.copy", os.path.join(out, "roundtrip.copy")),
                   ("truncated.copy", os.path.join(out, "truncated.copy"))):
    shutil.copy(path, "artifacts/go-selftest-share-%s%s" % (name, suffix))
print("host read-back byte-exact: REPORT.txt %d B (%d cases); file-ABI evidence "
      "roundtrip.copy %d B, truncated.copy %d B; OUT/deleted.txt absent, "
      "OUT/LIST empty, OUT/truncate.txt holds the %d-byte prefix"
      % (len(report), len(want_report.splitlines()) - 1,
         len(roundtrip_body), len(truncate_kept), len(truncate_kept)))
PY
