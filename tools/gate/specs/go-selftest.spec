# go-selftest.spec -- M61b/M61c/M61d/M61e (issues #1382/#1383/#1384/#1385)
# class-B gate: the first guest-owned pass/fail in the fleet. GOSELF.ELF runs a
# built-in case list on the fixtures the host seeded under IN/, writes
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
# M61d (#1384) adds the file-ABI pack, all of it on the share under per-case
# paths: create/write/close/reopen/read-back, truncate-then-read,
# delete-then-reopen-fails, and a directory listing that sees a file and then
# does not. Each case leaves TWO pieces of host-readable evidence — a one-line
# `case <id> …` receipt and, where bytes came back, a `.copy` of the bytes it
# READ (never the bytes it intended) — and the asserts below byte-compare all of
# it. A case that printed a verdict without landing the bytes cannot pass.
#
# The M61d cases are checked twice, on purpose. The receipts are the guest's
# claim about itself; the block below ALSO reads the share's own directory state
# on macOS (OUT/deleted.txt absent, OUT/LIST empty, roundtrip.txt 525 B,
# truncate.txt holding exactly the reconstructed 105-byte prefix). Those are
# facts about the filesystem the guest's syscalls left behind, which no receipt
# can fake — and the reconstructed bodies come from the same one-expression
# units the app writes (`b"goself file abi line\n" * n`), not from a fixture
# file. A `.copy` that does not equal the reconstruction fails the gate.
#
# M61e (#1385) adds the window receipt. Its evidence file is the only one whose
# bytes depend on a RUNTIME value (the id the kernel assigned), so it is matched
# rather than fixed — and then held to the two reporters of that same window
# that are NOT this process:
#
#   * the KERNEL's own open record, `open: id=<N> owner=<pid> rect=<x>,<y>
#     <W>x<H> ws=<k>` (driving_award.zig, the open-attribution marker of issue
#     #990), which also gives the rect as REQUESTED — 32,32 640x400, the app's
#     tabapp.Config;
#   * TABWM's `tabwm: tab-switch idx=<i> id=<N>` line, the WM naming the tab it
#     made active.
#
# The receipt's `win=` must equal both ids, and its `w=`/`h=` must be the
# tab-aware CONTENT VIEWPORT the WM proposed (1100x720 at x=180 — tabwm's
# compute_tab_viewport) rather than the 640x400 the kernel logged at open. That
# last point is what makes the window case worth a boot: a case that restated
# its own request would report 640x400, a number the kernel's open line
# contains, and fail here. The geometry in the receipt therefore comes from
# sys_win_query's read-back of the kernel's window record — a kernel->user copy
# into a fresh buffer, the same path issue #1391 broke and ADR 0032 fixed.
#
# This is NOT a framebuffer golden (the card's non-goal): no pixels are read
# anywhere, no PNG is compared, and nothing in the case knows what the window
# looks like.
#
# REGRESSION TEST for #1391 (fixed in the kernel, ADR 0032): the first
# kernel->user copy into a user buffer whose pages EL0 has never written used to
# be silently lost on VZ — the syscall reported the right byte count and the app
# read zeros, because the destination page still resolved for EL1 into the
# kernel's EL1-only identity overlay. The guest's read helper does not touch its
# buffer first (that workaround is deleted), and `intake` reads a host-seeded
# fixture into a fresh buffer; the asserts below require the fixture bytes
# back — in the report, in the OUT/ copies and in the receipts. With the defect
# live, this run ended on `case intake fail read returned 25B of zeros (issue
# #1391)` + `selftest: FAIL n=1` (recorded on #1391). The host's file channel
# was never involved (its stdout shows the bytes served). The M61d read-backs
# and M61e's win_query land in fresh buffers on the same path.
#
# The report fixture below is byte-exact on purpose — the report is
# deterministic (ADR 0031). Adding a case in M61f updates this fixture.
#
# HOST PREREQUISITE (fails the gate honestly when missing):
#   bash tools/go/build-goself.sh   ->  .build/go/GOSELF.ELF

vgate_name go-selftest "issues #1382-#1385 M61b-e: GOSELF.ELF runs the guest self-test cases over host-seeded intake fixtures, the file-ABI case pack and the window receipt; the host reads REPORT.txt and every OUT/ receipt on the share"
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
vgate_assert 01 serial-contains 'selftest: case window pass'
# The files were written BEFORE the summary (ADR 0031 ordering).
vgate_assert 01 serial-contains 'selftest: report /host/SELFTEST/REPORT.txt n='
vgate_assert 01 serial-contains 'selftest: summary /host/SELFTEST/OUT/summary.txt n='
vgate_assert 01 serial-contains 'goself: present'
# The contract line: n=0 means every case passed (the spec stops on this line).
vgate_assert 01 serial-contains 'selftest: FAIL n=0'
vgate_assert 01 serial-contains 'selftest OK'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 serial-absent 'exited status=139'
# The window the kernel opened is named by the kernel and by the WM — the two
# reporters the receipt's `win=` is held to below. The id is a runtime value,
# so these are the fixed substrings; the python assert extracts and compares it.
vgate_assert 01 serial-contains 'owner='
vgate_assert 01 serial-contains 'rect=32,32 640x400 ws='
vgate_assert 01 serial-contains 'tabwm: tab-switch idx='

# The load-bearing assert: the report, the copies and the receipts on the
# host's own filesystem must be byte-exact, the share's directory state must
# agree with what the cases claim they did, and the window receipt must agree
# with the kernel's and the WM's own record of that window. A marker that
# reported success without writing the bytes cannot pass this. The share is a
# per-run temp dir deleted at gate_end, so the files this spec relied on are
# copied into artifacts/ as evidence (ADR 0031 D4).
#
# The report copy is named `go-selftest-share-report.txt`, NOT
# `go-selftest-report.txt`: the harness already owns `artifacts/NAME-report.txt`
# (SPEC.md's per-gate report), and a copy to that name clobbers it.
vgate_assert 01 python <<'PY'
import os, re, shutil
share = os.environ["VG_SHARE"]
rd = os.environ["RUN_DIR"]
serial_path = os.environ.get("VG_SER") or os.path.join(rd, "vm-serial-01.log")
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

# The window, from the outside: the app's tabapp.Config at open, and the
# tab-aware content viewport TABWM proposes afterwards
# (user/src/tabwm.zig compute_tab_viewport: 180,0 1100x720).
win_open_rect = (32, 32, 640, 400)
win_viewport_w = 1100
win_viewport_h = 720

want_report = (b"case intake pass\n"
               b"case intake-altered pass\n"
               b"case clock-monotonic pass\n"
               b"case file-write pass\n"
               b"case file-roundtrip pass\n"
               b"case file-truncate pass\n"
               b"case file-delete pass\n"
               b"case file-list pass\n"
               b"case window pass\n"
               b"summary cases=9 failed=0\n")
want_summary = b"summary cases=9 failed=0\n"
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


def read(path):
    with open(path, "rb") as fh:
        return fh.read()


def require(path, want, what):
    got = read(path)
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

# M61e: the window receipt is matched rather than fixed (its id is a runtime
# value), then held to the kernel's and the WM's own account of that window.
serial = read(serial_path)
win = read(os.path.join(out, "window.txt"))
m = re.fullmatch(rb"case window win=([0-9]+) w=([0-9]+) h=([0-9]+) present=ok\n", win)
if not m:
    print("WINDOW RECEIPT is not the card's shape %r\n"
          "want 'case window win=<id> w=<W> h=<H> present=ok'"
          % win)
    raise SystemExit(1)
win_id, win_w, win_h = int(m.group(1)), int(m.group(2)), int(m.group(3))

app = re.search(rb"goself: open id=([0-9]+)", serial)
if not app:
    print("the app's own `goself: open id=<N>` line is missing from the serial")
    raise SystemExit(1)
app_id = int(app.group(1))

kern = [x for x in re.finditer(
    rb"^open: id=([0-9]+) owner=[0-9]+ rect=([0-9]+),([0-9]+) ([0-9]+)x([0-9]+) ws=[0-9]+",
    serial, re.M) if int(x.group(1)) == win_id]
if not kern:
    print("the kernel logged no `open:` record for window %d - the receipt names a "
          "window the kernel does not have (app says %d)" % (win_id, app_id))
    raise SystemExit(1)
kern_rect = tuple(int(kern[-1].group(i)) for i in (2, 3, 4, 5))

wm = re.search(rb"tabwm: tab-switch idx=[0-9]+ id=([0-9]+)", serial)
if not wm:
    print("TABWM reported no `tab-switch` line - no independent WM report of the window")
    raise SystemExit(1)
wm_id = int(wm.group(1))

if not (win_id == app_id == wm_id):
    print("the window ids disagree: receipt win=%d, app goself: open id=%d, WM tab-switch id=%d"
          % (win_id, app_id, wm_id))
    raise SystemExit(1)
if kern_rect != win_open_rect:
    print("the kernel's open rect is %r, not the app's tabapp.Config %r"
          % (kern_rect, win_open_rect))
    raise SystemExit(1)
# The receipt must report the KERNEL's current geometry (the WM's full content
# viewport after the tab-aware declaration), NOT the 640x400 the kernel logged
# at open. A case that restated its own request fails right here.
if (win_w, win_h) == (kern_rect[2], kern_rect[3]):
    print("the window receipt repeats the OPEN rect %dx%d instead of the kernel's "
          "current geometry: the case is restating its request, not reading the "
          "window back (sys_win_query)" % (win_w, win_h))
    raise SystemExit(1)
if (win_w, win_h) != (win_viewport_w, win_viewport_h):
    print("the window receipt reports %dx%d, not the tab-aware content viewport "
          "%dx%d the WM proposes (tabwm compute_tab_viewport)"
          % (win_w, win_h, win_viewport_w, win_viewport_h))
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
                   ("truncated.copy", os.path.join(out, "truncated.copy")),
                   ("window.txt", os.path.join(out, "window.txt"))):
    shutil.copy(path, "artifacts/go-selftest-share-%s%s" % (name, suffix))
print("host read-back byte-exact: REPORT.txt %d B (%d cases); file-ABI evidence "
      "roundtrip.copy %d B, truncated.copy %d B; OUT/deleted.txt absent, "
      "OUT/LIST empty, OUT/truncate.txt holds the %d-byte prefix"
      % (len(report), len(want_report.splitlines()) - 1,
         len(roundtrip_body), len(truncate_kept), len(truncate_kept)))
print("window receipt agreed with the kernel and the WM: win=%d (kernel `open:`, "
      "app `goself: open`, WM `tab-switch`); kernel open rect %r; read-back "
      "geometry %dx%d (the tab-aware viewport, not the open rect)"
      % (win_id, kern_rect, win_w, win_h))
PY
