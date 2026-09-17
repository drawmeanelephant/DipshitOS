# go-selftest.spec -- M61b (issue #1382) class-B gate: the first guest-owned
# pass/fail in the fleet. GOSELF.ELF runs a built-in case list, writes
# /host/SELFTEST/REPORT.txt + OUT/ receipts on the share, then prints the
# serial contract of ADR 0031 (`selftest: FAIL n=<N>`, `selftest OK`).
#
# Serial is the heartbeat; the files are the proof. The load-bearing asserts
# read $VG_SHARE on the HOST, so an app that printed `selftest: FAIL n=0`
# without writing the report cannot pass. The run ends on the program's own
# summary marker (SPEC.md idiom 1): a run whose summary never appears fails on
# the expect deadline.
#
# The report fixture below is byte-exact on purpose — the report is
# deterministic (ADR 0031). Adding a case in M61c/d/e updates this fixture.
#
# HOST PREREQUISITE (fails the gate honestly when missing):
#   bash tools/go/build-goself.sh   ->  .build/go/GOSELF.ELF

vgate_name go-selftest "issue #1382 M61b: GOSELF.ELF runs the guest self-test cases; the host reads REPORT.txt on the share"
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
print("staged GOSELF.ELF into share (%d bytes) and %s/{IN,OUT}" %
      (os.path.getsize(os.path.join(share, "GOSELF.ELF")), st))
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

# The load-bearing assert: the report and the receipts on the host's own
# filesystem must be byte-exact. A marker that reported success without
# writing the bytes cannot pass this. The share is a per-run temp dir deleted
# at gate_end, so the report is copied into artifacts/ as evidence (ADR 0031).
#
# The copy is named `go-selftest-share-report.txt`, NOT `go-selftest-report.txt`:
# the harness already owns `artifacts/NAME-report.txt` (SPEC.md's per-gate
# report), and a copy to that name clobbers it.
vgate_assert 01 python <<'PY'
import os, shutil
share = os.environ["VG_SHARE"]
suffix = os.environ.get("VIRELAI_GATE_SUFFIX", "")
want_report = (b"case clock-monotonic pass\n"
               b"case file-write pass\n"
               b"summary cases=2 failed=0\n")
want_hello = b"goself smoke\n"
want_summary = b"summary cases=2 failed=0\n"

report_path = os.path.join(share, "SELFTEST", "REPORT.txt")
got_report = open(report_path, "rb").read()
if got_report != want_report:
    print("REPORT MISMATCH:\n got %r\nwant %r" % (got_report, want_report))
    raise SystemExit(1)

got_hello = open(os.path.join(share, "SELFTEST", "OUT", "hello.txt"), "rb").read()
if got_hello != want_hello:
    print("HELLO MISMATCH: got %r want %r" % (got_hello, want_hello))
    raise SystemExit(1)

got_summary = open(os.path.join(share, "SELFTEST", "OUT", "summary.txt"), "rb").read()
if got_summary != want_summary:
    print("SUMMARY MISMATCH: got %r want %r" % (got_summary, want_summary))
    raise SystemExit(1)

os.makedirs("artifacts", exist_ok=True)
shutil.copy(report_path, "artifacts/go-selftest-share-report%s.txt" % suffix)
print("host read-back byte-exact: REPORT.txt %d B, OUT/hello.txt %d B, "
      "OUT/summary.txt %d B" % (len(got_report), len(got_hello), len(got_summary)))
PY
