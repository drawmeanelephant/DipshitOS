# live-oliver.spec -- a REAL Zig HTML tool (oliver, commit 3f05bacb) on
# VirelaiOS from ONE source, two load paths (#1177, #1188). One app invocation
# per boot: `exec` spawns a task and returns, so a second invocation in the
# same script would race the first -- each boot ends on its own completion
# marker instead (`--script-expect 'procs OLIVER.* exited status=754'`, the
# app's exit status being the byte count it wrote).
#   boots 01-02: OLIVER.BIN, the DSK1 flat image, WITH REAL ARGV (the loader
#     packs the block into the text page's slack). Proved three ways: the
#     argv-named outputs appear byte-exact, the default name (OLIVER.HTML)
#     never appears at all, and the app echoes the argv it received.
#   boot 03: OLIVER.BIN with no argv -> its documented defaults.
#   boot 04: OLIVER.ELF, the raw-ELF shape (exec.zig returns .no_args_room
#     for it, so argc is always 0) -- the shape #1163's loader lift widens.
# HTML is written through the M34 HF share and compared HOST-SIDE byte-exact
# against oliver's own CLI output; neither path stamps a time or version, so no
# normalization is needed and serial is the order-of-events witness.
# Pinned: OLIVER.ELF 253,576 B (1 PT_LOAD R+X @0x0040_0000, 249,196 B memory,
# 47.6% of the 512 KiB cap); OLIVER.BIN 249,220 B (content 249,196, argv block
# at 249,200+256 = 249,456 vs page_limit 249,856 => 400 B slack).
# Deliberately NOT repeatable via a BOOTS knob: the argv boots run before any
# default-name write, and a second iteration would see that name already made.

vgate_name live-oliver "real Zig HTML tool (oliver): DSK1 flat image with real argv + native ELF defaults, host-side HTML compare"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE
vgate_repeat 1

vgate_file script1.txt <<'EOF'
exec OLIVER.BIN MD.TXT OUT2.HTML
echo rx-oliver-argv
EOF

vgate_file script2.txt <<'EOF'
exec OLIVER.BIN /host/MD.TXT /host/OUT4.HTML
echo rx-oliver-argv-abs
EOF

vgate_file script3.txt <<'EOF'
exec OLIVER.BIN
echo rx-oliver-defaults
EOF

vgate_file script4.txt <<'EOF'
exec OLIVER.ELF
echo rx-oliver-rendered
EOF

vgate_setup_python <<'PY'
import hashlib, os, shutil

run_dir = os.environ["RUN_DIR"]
share = os.environ["VG_SHARE"] if os.environ.get("VG_SHARE") else os.path.join(run_dir, "share")
os.makedirs(share, exist_ok=True)

# The pinned images (tests/oliver-spike/): the native ELF and the DSK1 flat
# image converted from it by tools/elf2bin.py, plus the input fixture.
for src, dst in (
    ("tests/oliver-spike/OLIVER.ELF", "OLIVER.ELF"),
    ("tests/oliver-spike/OLIVER.BIN", "OLIVER.BIN"),
    ("tests/oliver-spike/md-fixture.txt", "MD.TXT"),
):
    shutil.copy(src, os.path.join(share, dst))
    with open(src, "rb") as f:
        data = f.read()
    print("staged %-9s %7d B sha256 %s" % (dst, len(data), hashlib.sha256(data).hexdigest()))

# The expected HTML: oliver's own native CLI over the same fixture
# (`oliver render --from markdown < md-fixture.txt`). The app renders through
# the same library entry point, so the compare is byte-exact -- neither path
# emits a timestamp or version stamp (recorded here because it is load-bearing).
shutil.copy("tests/oliver-spike/expect.html", os.path.join(run_dir, "EXPECT.HTML"))
PY

vgate_run 01 -- --script '$RUN_DIR/script1.txt' --script-after "virelai>" --script-expect 'procs OLIVER.BIN exited status=754' --timeout 90
vgate_run 02 -- --script '$RUN_DIR/script2.txt' --script-after "virelai>" --script-expect 'procs OLIVER.BIN exited status=754' --timeout 90
vgate_run 03 -- --script '$RUN_DIR/script3.txt' --script-after "virelai>" --script-expect 'procs OLIVER.BIN exited status=754' --timeout 90
vgate_run 04 -- --script '$RUN_DIR/script4.txt' --script-after "virelai>" --script-expect 'procs OLIVER.ELF exited status=754' --timeout 90

# --- boot 01: argv reaches the app (relative names) -------------------------
vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-echo 'exec OLIVER.BIN MD.TXT OUT2.HTML'
# The DSK1 load line (content_len in hex, zero-padded) and the app's own report
# of the argv it received -- impossible unless the block really was delivered.
vgate_assert 01 serial-contains 'exec: loaded OLIVER.BIN size=0x000000000003cd6c'
vgate_assert 01 serial-contains 'oliver: argc=2 in=MD.TXT out=OUT2.HTML'
# Exit status == bytes written, so the reap line is the whole round trip.
vgate_assert 01 serial-contains 'procs OLIVER.BIN exited status=754'
vgate_assert 01 serial-contains 'oliver: wrote 754 bytes'
vgate_assert 01 serial-contains 'rx-oliver-argv'

# Host-side: the pinned digest, the DSK1 argv-fit arithmetic reproduced from
# exec.zig, the argv-named output byte-exact, and the DEFAULT name absent.
vgate_assert 01 python <<'PY'
import hashlib, os, shutil, struct, sys

run_dir = os.environ["RUN_DIR"]
share = os.environ["VG_SHARE"] if os.environ.get("VG_SHARE") else os.path.join(run_dir, "share")
pin_bin = "83b6549c853f5cf1e32ceb10ea966190bc3c2fac8ebe5915806d8ee0f4084743"
want = open(os.path.join(run_dir, "EXPECT.HTML"), "rb").read()

data = open(os.path.join(share, "OLIVER.BIN"), "rb").read()
got = hashlib.sha256(data).hexdigest()
print("staged OLIVER.BIN %d B sha256 %s" % (len(data), got))
if got != pin_bin:
    sys.exit("FAIL: staged OLIVER.BIN is not the pinned image (%s)" % pin_bin)

# Reproduce kernel/src/exec.zig's DSK1 rule: the argv block goes at
# align8(content_len) inside the program's own text page and must fit before
# the page boundary, else exec returns .no_args_room and the app never runs.
magic, _flags, entry_off, image_size = struct.unpack_from("<IIQQ", data, 0)
if magic != 0x314B5344:
    sys.exit("FAIL: staged image is not a DSK1 flat image (%#x)" % magic)
content = image_size - 24
block_off = (content + 7) & ~7
page = 4096
page_limit = ((content + page - 1) // page) * page
block = 8 * 32
slack = page_limit - (block_off + block)
print("DSK1: content=%d argv block_off=%d page_limit=%d slack=%d B" % (content, block_off, page_limit, slack))
if entry_off < 24 or entry_off >= image_size:
    sys.exit("FAIL: entry offset %#x outside the image" % entry_off)
if slack < 0:
    sys.exit("FAIL: the argv block does not fit the text page (slack %d)" % slack)

path = os.path.join(share, "OUT2.HTML")
if not os.path.exists(path):
    sys.exit("FAIL: OUT2.HTML missing -- the output argument did not reach the app")
got_bytes = open(path, "rb").read()
print("share/OUT2.HTML %d B sha256 %s" % (len(got_bytes), hashlib.sha256(got_bytes).hexdigest()))
if got_bytes != want:
    for i in range(min(len(got_bytes), len(want))):
        if got_bytes[i] != want[i]:
            sys.exit("FAIL: OUT2.HTML differs from the reference at byte %d" % i)
    sys.exit("FAIL: OUT2.HTML length differs (guest %d, host %d)" % (len(got_bytes), len(want)))

if os.path.exists(os.path.join(share, "OLIVER.HTML")):
    sys.exit("FAIL: OLIVER.HTML exists -- the app used its default output name, so argv was ignored")
print("argv ok: named output byte-exact, default name never written, block fits with %d B to spare" % slack)
shutil.copy(path, os.path.join(run_dir, "oliver-html-argv.html"))
PY

vgate_assert 01 snapshot 'oliver-html-argv.html' <<'PY'
import hashlib, sys
data = open(sys.argv[1], "rb").read()
print("evidence: guest-written HTML via argv %d B sha256 %s" % (len(data), hashlib.sha256(data).hexdigest()))
PY

# --- boot 02: argv as full guest paths --------------------------------------
vgate_assert 02 serial-echo 'exec OLIVER.BIN /host/MD.TXT /host/OUT4.HTML'
vgate_assert 02 serial-contains 'oliver: argc=2 in=/host/MD.TXT out=/host/OUT4.HTML'
vgate_assert 02 serial-contains 'procs OLIVER.BIN exited status=754'
vgate_assert 02 serial-contains 'rx-oliver-argv-abs'
vgate_assert 02 python <<'PY'
import hashlib, os, shutil, sys

run_dir = os.environ["RUN_DIR"]
share = os.environ["VG_SHARE"] if os.environ.get("VG_SHARE") else os.path.join(run_dir, "share")
want = open(os.path.join(run_dir, "EXPECT.HTML"), "rb").read()
path = os.path.join(share, "OUT4.HTML")
if not os.path.exists(path):
    sys.exit("FAIL: OUT4.HTML missing -- an absolute-path argument did not reach the app")
got = open(path, "rb").read()
print("share/OUT4.HTML %d B sha256 %s" % (len(got), hashlib.sha256(got).hexdigest()))
if got != want:
    sys.exit("FAIL: OUT4.HTML differs from the reference tool's output")
if os.path.exists(os.path.join(share, "OLIVER.HTML")):
    sys.exit("FAIL: OLIVER.HTML exists after two argv runs -- something fell back to the default name")
print("absolute-path argv ok: second independent run, same bytes, default name still absent")
shutil.copy(path, os.path.join(run_dir, "oliver-html-argv-abs.html"))
PY

vgate_assert 02 snapshot 'oliver-html-argv-abs.html' <<'PY'
import hashlib, sys
data = open(sys.argv[1], "rb").read()
print("evidence: guest-written HTML via absolute-path argv %d B sha256 %s" % (len(data), hashlib.sha256(data).hexdigest()))
PY

# --- boot 03: the DSK1 image with no arguments takes the defaults -----------
vgate_assert 03 serial-echo 'exec OLIVER.BIN'
vgate_assert 03 serial-contains 'oliver: argc=0 in=MD.TXT out=OLIVER.HTML'
vgate_assert 03 serial-contains 'procs OLIVER.BIN exited status=754'
vgate_assert 03 serial-contains 'rx-oliver-defaults'
vgate_assert 03 python <<'PY'
import hashlib, os, shutil, sys

run_dir = os.environ["RUN_DIR"]
share = os.environ["VG_SHARE"] if os.environ.get("VG_SHARE") else os.path.join(run_dir, "share")
want = open(os.path.join(run_dir, "EXPECT.HTML"), "rb").read()
path = os.path.join(share, "OLIVER.HTML")
if not os.path.exists(path):
    sys.exit("FAIL: the no-argument DSK1 run wrote no OLIVER.HTML (its documented default)")
got = open(path, "rb").read()
print("share/OLIVER.HTML (no-arg DSK1) %d B sha256 %s" % (len(got), hashlib.sha256(got).hexdigest()))
if got != want:
    sys.exit("FAIL: the default-output HTML differs from the reference tool's output")
shutil.copy(path, os.path.join(run_dir, "oliver-html-guest.html"))
print("defaults ok: no argv -> the documented default names, same 754 bytes")
PY

vgate_assert 03 snapshot 'oliver-html-guest.html' <<'PY'
import hashlib, sys
data = open(sys.argv[1], "rb").read()
print("evidence: guest-written HTML via the DSK1 default %d B sha256 %s" % (len(data), hashlib.sha256(data).hexdigest()))
PY

# --- boot 04: the same tool as a raw ELF (no argv on that load path) --------
vgate_assert 04 serial-echo 'exec OLIVER.ELF'
vgate_assert 04 serial-contains 'exec: loaded OLIVER.ELF size=0x000000000003cd6c'
vgate_assert 04 serial-contains 'oliver: argc=0 in=MD.TXT out=OLIVER.HTML'
vgate_assert 04 serial-contains 'procs OLIVER.ELF exited status=754'
vgate_assert 04 serial-contains 'rx-oliver-rendered'
vgate_assert 04 python <<'PY'
import hashlib, os, sys

run_dir = os.environ["RUN_DIR"]
share = os.environ["VG_SHARE"] if os.environ.get("VG_SHARE") else os.path.join(run_dir, "share")
want = open(os.path.join(run_dir, "EXPECT.HTML"), "rb").read()
got = open(os.path.join(share, "OLIVER.HTML"), "rb").read()
print("share/OLIVER.HTML (raw ELF) %d B sha256 %s" % (len(got), hashlib.sha256(got).hexdigest()))
print("host  expect.html         %d B sha256 %s" % (len(want), hashlib.sha256(want).hexdigest()))
if got != want:
    sys.exit("FAIL: the raw-ELF run's HTML differs from the reference tool's output")
# Cross-load-path determinism: boot 01's file came from the DSK1 argv path.
argv_out = os.path.join(run_dir, "oliver-html-argv.html")
if os.path.exists(argv_out) and open(argv_out, "rb").read() != got:
    sys.exit("FAIL: the DSK1 argv output and the raw-ELF output differ")
print("byte-exact: both load paths emit the reference tool's own output")
PY

# FAIL needles for every boot: the loader's own refusal/abort shapes
# (monitor.zig err_prefix + the honest-ELF refusals), never `exec: loaded ...`.
vgate_assert 01 serial-absent 'error: '
vgate_assert 01 serial-absent 'not found on the host share'
vgate_assert 01 serial-absent 'image larger than the'
vgate_assert 01 serial-absent 'leaves no room for the argv block'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 02 serial-absent 'error: '
vgate_assert 02 serial-absent '[EXC] parking:'
vgate_assert 03 serial-absent 'error: '
vgate_assert 03 serial-absent '[EXC] parking:'
vgate_assert 04 serial-absent 'error: '
vgate_assert 04 serial-absent '[EXC] parking:'
