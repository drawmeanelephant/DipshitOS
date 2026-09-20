# live-selfhost-go.spec -- M70c-S2 (issue #1544) class-B gate: the in-guest
# build loop. GOSELFHOST.ELF (tools/go/selfhost.go) compiles the pinned fixture
# with the guest's own cmd/compile and links it with the guest's own cmd/link,
# sequencing the two steps by spawn-and-wait (ADR 0007 slot 28 + the wait
# slots) instead of by two boots' worth of monitor `exec` — the shape the #1544
# spike chose and recorded (ADR 0035 amendment 6). Nothing fetches a toolchain:
# GOTOOLCHAIN=local is literal for a guest with no `go` command, and every byte
# the loop reads is staged in the share.
#
# TWO boots, and the second one is not a convenience. The loop's third
# sequential child — the product — dies on this GOOS today: observed in run 01
# as `fault: HELLO2.ELF far=0x47c29000 ec=0x24 esr=0x9200004f`, status 139.
# That is the same wall go-sh.spec already documents ("A THIRD sequential exec
# from one EL0 parent currently dies in the Go runtime's own schedinit ...
# follow-up owed to the runtime/kernel owners", issue #1449) with a different
# symptom, so this spec does not claim the product can be a third child: the
# BUILD is the guest's own two-child loop, and the RUN is one monitor `exec` of
# what the loop produced (the same execution go-hello run 08 performs).
#
# HOST PREREQUISITE (fails the gate honestly when missing):
#   bash tools/go/build-go.sh tools/go/selfhost.go   -> .build/go/GOSELFHOST.ELF
#   bash tools/go/build-gotool.sh                    -> .build/go/GOCMD*.ELF
#   bash tools/go/stage-selfhost.sh                  -> .build/go/selfhost/
# exec-order: assert-proven -- run 01 ends on a marker only the driver prints,
# and its asserts read the driver's own steps; run 02 ends on the executed
# program's own pinned line. A loop that never ran cannot go green. See
# tools/gate/SPEC.md.

vgate_name live-selfhost-go "issue #1544 M70c-S2: the guest's own toolchain builds the pinned hello in one loop, and the product runs"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE
vgate_repeat 1 BOOTS

vgate_file script.txt <<'EOF'
exec GOSELFHOST.ELF
EOF

vgate_file script2.txt <<'EOF'
exec HELLO2.ELF
EOF

vgate_setup_python <<'PY'
import os, shutil, sys
share = os.path.join(os.environ["RUN_DIR"], "share")
fixtures = [".build/go/GOSELFHOST.ELF", ".build/go/GOCMDCOMPILE.ELF", ".build/go/GOCMDLINK.ELF"]
for src in fixtures:
    if not os.path.exists(src):
        sys.exit("%s missing — build it first (see this spec's header): "
                 "bash tools/go/build-go.sh tools/go/selfhost.go, "
                 "bash tools/go/build-gotool.sh" % src)
    shutil.copy(src, os.path.join(share, os.path.basename(src)))
    print("staged %s (%d bytes)" % (os.path.basename(src), os.path.getsize(src)))
# What the guest's linker reads: the import config naming export data for the
# pinned hello's closure, those archives, and the pinned source.
stage = ".build/go/selfhost"
if not os.path.isdir(stage):
    sys.exit("missing %s — run: bash tools/go/stage-selfhost.sh" % stage)
n = total = 0
for name in sorted(os.listdir(stage)):
    if name.startswith("."):
        continue
    src = os.path.join(stage, name)
    shutil.copy(src, os.path.join(share, name))
    n += 1
    total += os.path.getsize(src)
print("staged %d selfhost inputs (%.2f MiB): import config + archives + HELLO.GO"
      % (n, total / 1048576.0))
# The loop's products must not be leftovers: this spec and go-hello run 08 both
# write HELLO.o / HELLO2.ELF into a share, and a stale one would let a broken
# loop go green. Run 02 executes what run 01 writes, so a stale product would
# also fake the second boot.
for stale in ("HELLO.o", "HELLO2.ELF"):
    p = os.path.join(share, stale)
    if os.path.exists(p):
        os.remove(p)
        print("removed stale %s from a previous run" % stale)
PY

# Run 01: the build loop. One program, two children, sequenced by the guest's
# own waits. A linker that reads ~15 MiB of archives off the share at the
# 2048-byte EL0 read cap is the slow step, hence the wide timeout.
vgate_run 01 -- --script '$RUN_DIR/script.txt' --script-expect 'selfhost: build loop OK' --timeout 900

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'exec: loaded GOSELFHOST.ELF'
vgate_assert 01 serial-contains 'selfhost: compile GOCMDCOMPILE.ELF status=0'
vgate_assert 01 serial-contains 'selfhost: link GOCMDLINK.ELF status=0'
vgate_assert 01 serial-contains 'selfhost: build loop OK'
vgate_assert 01 serial-absent 'selfhost: FAIL'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 serial-absent 'cannot allocate memory'
vgate_assert 01 serial-absent 'exited status=139'

# The loop's products, checked from macOS: the object really is a virelai
# object (its ar header names the target it was compiled for) and the ELF
# really is loadable — every rule the kernel enforces, plus the argv+envp slack
# the second boot's exec depends on. The step times are extracted and reported
# (a build time is a property of the machine, so it is not asserted, the same
# way go-hello run 04 reports its transfer rate).
vgate_assert 01 python <<'PY'
import os, re, struct, sys
share = os.environ.get("VG_SHARE") or os.path.join(os.environ["RUN_DIR"], "share")

obj = os.path.join(share, "HELLO.o")
if not os.path.exists(obj):
    sys.exit("FAIL: the loop produced no object at " + obj)
raw = open(obj, "rb").read()
if not raw.startswith(b"!<arch>") or b"go object virelai arm64 " not in raw:
    sys.exit("FAIL: HELLO.o is not a virelai Go object (first bytes %r)" % raw[:16])
for want in (b"__.PKGDEF", b"_go_.o", b"main.main"):
    if want not in raw:
        sys.exit("FAIL: HELLO.o has no %r" % want)

elf = os.path.join(share, "HELLO2.ELF")
if not os.path.exists(elf):
    sys.exit("FAIL: the loop produced no ELF at " + elf)
d = open(elf, "rb").read()
if d[:4] != b"\x7fELF" or d[4] != 2 or d[5] != 1:
    sys.exit("FAIL: HELLO2.ELF is not a 64-bit little-endian ELF")
if struct.unpack_from("<H", d, 0x12)[0] != 183:
    sys.exit("FAIL: HELLO2.ELF is not AArch64")
MAX, GAP, NEED_SLACK = 33554432, 0x1000_0000, 0x908
entry = struct.unpack_from("<Q", d, 0x18)[0]
phoff = struct.unpack_from("<Q", d, 0x20)[0]
phes = struct.unpack_from("<H", d, 0x36)[0]
pnum = struct.unpack_from("<H", d, 0x38)[0]
segs = []
for i in range(pnum):
    t, fl, off, va, pa, fsz, msz, al = struct.unpack_from("<IIQQQQQQ", d, phoff + i * phes)
    if t == 1:
        segs.append((fl, va, fsz, msz))
segs.sort(key=lambda s: s[1])
fails = []
if not segs:
    fails.append("no PT_LOAD segments")
if len(segs) > 3:
    fails.append("%d PT_LOAD > max_segments 3" % len(segs))
total = sum(s[3] for s in segs)
if total > MAX:
    fails.append("sum memsz %d > load_max" % total)
for fl, va, fsz, msz in segs:
    if va + msz > GAP:
        fails.append("segment at %#x crosses gap_base_max" % va)
    if va & 4095:
        fails.append("segment at %#x unaligned" % va)
if segs and segs[0][0] & 2:
    fails.append("segment 0 writable")
if segs and not (segs[-1][0] & 2):
    fails.append("last segment not writable")
if segs and not (segs[0][1] <= entry < segs[0][1] + segs[0][2]):
    fails.append("entry %#x not in segment 0 initialized bytes" % entry)
slack = (-segs[-1][3]) % 4096 if segs else 0
if slack < NEED_SLACK:
    fails.append("writable page slack %d < %#x (argv+envp block)" % (slack, NEED_SLACK))
if len(d) > MAX:
    fails.append("file %d > exec_image_max" % len(d))
print("loop products: HELLO.o %d bytes (virelai object), HELLO2.ELF %d bytes, "
      "%d segments, memsz %d (%#x), slack %#x"
      % (len(raw), len(d), len(segs), total, total, slack))
ser = open(os.environ["VG_SER"], errors="replace").read()
for label in ("compile", "link"):
    m = re.search(r"selfhost: %s \S+ status=(\d+) ms=(\d+)" % label, ser)
    if not m:
        sys.exit("FAIL: no `selfhost: %s ... ms=` line" % label)
    print("step %s: status=%s elapsed=%s ms" % (label, m.group(1), m.group(2)))
if fails:
    for f in fails:
        print("FAIL: " + f)
    sys.exit(1)
print("the loop's ELF satisfies every loader rule the kernel enforces")
PY

# Run 02: the product the guest built, executed by the kernel — the RUN half of
# the build loop, one monitor exec (see this spec's header for why it is not a
# third child in run 01). Its pinned lines are the fixture's own vocabulary
# (phase 0a's runtime surface: console, sbrk heap growth, a GC cycle).
#
# No `procs HELLO2.ELF exited status=0` assert: the run stops ON the program's
# last pinned line, which is printed before the process is reaped, so the exit
# line races the stop rather than reporting on the program. The
# absent-exception asserts are what rule out a crash.
vgate_run 02 -- --script '$RUN_DIR/script2.txt' --script-expect 'virelai-go OK' --timeout 300

vgate_assert 02 serial-contains 'exec: loaded HELLO2.ELF'
vgate_assert 02 serial-contains 'hello from virelai'
vgate_assert 02 serial-contains 'GOOS=virelai GOARCH=arm64 gc runtime alive'
vgate_assert 02 serial-contains 'heap: wrote 1048576 bytes'
vgate_assert 02 serial-contains 'gc: cycle completed'
vgate_assert 02 serial-contains 'virelai-go OK'
vgate_assert 02 serial-absent '[EXC] parking:'
vgate_assert 02 serial-absent 'exited status=139'
vgate_assert 02 serial-absent 'cannot allocate memory'
