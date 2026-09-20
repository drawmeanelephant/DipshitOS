# go-hello.spec -- issue #1163, GOOS=virelai phase 0a: the gc Go runtime
# runs on VirelaiOS. Runs 01-03 (M70c-K, #1504): svc #0 console + sbrk heap +
# GC; a >9 MiB image STREAMED into its mapped pages; the two refusals by name.
# Run 04 (M70c, #1455): the guest reads that same 9.5 MiB from the share
# end to end at the ABI's 2048-byte read cap — bytes, call count and FNV hash
# asserted against the file on macOS, the rate reported (ADR 0035 measures it).
# Run 05 (M70c-S1L, #1540): the std fixture — a Go program whose file I/O goes
# through `os`/`fmt` (the #1525 port) instead of the guest SDK — RUNS. Its own
# output is held to the file on macOS: the whole 9.5 MiB image read through
# os.File and hashed, os.Mkdir/WriteFile/ReadDir/Stat/Remove exercised in a
# directory the fixture creates (so the entry counts are exact), and the
# removes checked from the host's copy of the share afterwards. The aperture
# that used to refuse this image is fixed in the runtime's break base, and the
# run also pins the two port bugs it caught (ADR 0035 amendment 4).
# Runs 06-08 (M70c-S1T, #1543): the guest's OWN cmd/compile and cmd/link build
# tools/go/hello.go in the guest (object -> ELF), and the ELF the guest linked
# runs and prints the pinned lines. The in-guest memory samples (run 06/07) are
# the ADR 0035 D6 figure: reported, not asserted, because a footprint is a
# property of the machine.
# HOST PREREQUISITE: `.build/go/{GOHELLO,GOBIG,GOREAD,GOSYSCALL}.ELF` must exist
# first via `bash tools/go/build-go.sh tools/go/hello.go tools/go/gobig.go
# tools/go/goread.go tools/go/gosyscall.go` (fork prerequisites in
# tools/go/README.md); runs 06-08 additionally need `bash tools/go/build-gotool.sh`
# (the GOOS=virelai toolchain images) and `bash tools/go/stage-selfhost.sh`
# (the import config + package archives the guest's linker resolves against).
# exec-order: assert-proven — a run cannot go green without the program's own output. See tools/gate/SPEC.md.

vgate_name go-hello "issue #1163 GOOS=virelai phase 0a: gc Go runtime first target on VZ"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE
vgate_repeat 1 BOOTS

# Issue #1163 A2 review follow-up: the run waits on the PROGRAM's own
# final line (below) — the old `echo go-hello-done` raced the VM shutdown
# against the exec'd process's first scheduling (observed live once on
# go-args), a flaky FAIL by construction.
vgate_file script.txt <<'EOF'
exec GOHELLO.ELF
EOF

vgate_file script2.txt <<'EOF'
exec GOBIG.ELF
EOF

vgate_file script3.txt <<'EOF'
exec XL.ELF
exec TRUNC.ELF
EOF

# M70c (#1455) run 04: GOREAD.ELF reads GOBIG.ELF back out of the share, end
# to end, at the guest SDK's own chunk size (vsys.MaxFileIOBytes = the kernel's
# 2048-byte per-call read cap). It hashes every byte as it arrives and prints
# what that cost; the host recomputes the hash and the call arithmetic over the
# file it staged. Nothing here is timing-dependent — the rate is reported, not
# asserted.
vgate_file script4.txt <<'EOF'
exec GOREAD.ELF /host/GOBIG.ELF
EOF

# M70c-S1L (issue #1540) run 05: the same image, read through the STANDARD
# LIBRARY instead of the guest SDK — os.File/os.ReadDir/os.WriteFile/os.Remove
# over the #1525 syscall+os port, printed with fmt into os.Stdout.
vgate_file script5.txt <<'EOF'
exec GOSYSCALL.ELF
EOF

vgate_setup_python <<'PY'
import os, shutil, sys
share = os.path.join(os.environ["RUN_DIR"], "share")
srcs = [".build/go/GOHELLO.ELF", ".build/go/GOBIG.ELF", ".build/go/GOREAD.ELF",
        ".build/go/GOSYSCALL.ELF"]
missing = [p for p in srcs if not os.path.exists(p)]
if missing:
    sys.exit("%s missing — build the fork binaries first: "
             "bash tools/go/build-go.sh tools/go/hello.go tools/go/gobig.go "
             "tools/go/goread.go tools/go/gosyscall.go "
             "(fork prerequisites in tools/go/README.md)" % ", ".join(missing))
for src in srcs:
    dst = os.path.join(share, os.path.basename(src))
    shutil.copy(src, dst)
    print("staged %s into share (%d bytes)" % (os.path.basename(src), os.path.getsize(dst)))
# The M70c-K (#1504) fixture's whole point is its size: fail here rather
# than let run 02 pass on an image the staging buffer could have held.
if os.path.getsize(os.path.join(share, "GOBIG.ELF")) <= 8 << 20:
    sys.exit("GOBIG.ELF is not over 8 MiB — the streamed bound is untested")
# Run 03's two refusal fixtures, made from that same real image so that
# neither is refused for a reason other than the one under test:
#   XL.ELF    — the whole image plus padding past the 32 MiB acceptance
#               bound. Every byte of the image itself is valid and its
#               segments are all present, so ONLY the file's size can
#               refuse it (a file of zeros would prove much less).
#   TRUNC.ELF — the first 4 MiB of a 9.5 MiB image: big enough to take the
#               STREAMED path (>2 MiB, so it is not the staged shape), laid
#               out so its text and rodata are complete and its 8 MiB data
#               segment is cut off, i.e. exactly what an interrupted copy
#               looks like.
go = os.path.join(share, "GOBIG.ELF")
xl = os.path.join(share, "XL.ELF")
with open(go, "rb") as src, open(xl, "wb") as out:
    shutil.copyfileobj(src, out)
    out.truncate(34 << 20)
trunc = os.path.join(share, "TRUNC.ELF")
with open(go, "rb") as src, open(trunc, "wb") as out:
    out.write(src.read(4 << 20))
    out.flush()
if os.path.getsize(xl) <= 32 << 20:
    sys.exit("XL.ELF is not over the 32 MiB acceptance bound — its refusal is untested")
if not 2 << 20 < os.path.getsize(trunc) < os.path.getsize(go):
    sys.exit("TRUNC.ELF must be too big to stage but smaller than the image it copies")
print("staged refusal fixtures: XL.ELF %d B, TRUNC.ELF %d B" % (os.path.getsize(xl), os.path.getsize(trunc)))
PY

vgate_run 01 -- --script '$RUN_DIR/script.txt' --script-expect 'virelai-go OK' --timeout 120

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'exec: loaded GOHELLO.ELF'
vgate_assert 01 serial-contains 'hello from virelai'
vgate_assert 01 serial-contains 'heap: wrote 1048576 bytes'
vgate_assert 01 serial-contains 'gc: cycle completed'
vgate_assert 01 serial-contains 'virelai-go OK'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 serial-absent 'exited status=139'

# M70c-K (issue #1504) run 02: GOBIG.ELF is a real GOOS=virelai Go image of
# 9.5 MiB whose LAST segment carries 8.0 MiB of initialized data, so the old
# loader refused it outright (`image too large`) — a staged load would have had
# to hold the whole file in a 2 MiB array. The banner the program prints is
# read back at runtime from 1, 4 and 8 MiB into that payload: it is 'A B C E D'
# only if every streamed page arrived, and zeros or a fault otherwise.
vgate_run 02 -- --script '$RUN_DIR/script2.txt' --script-expect 'virelai-go big OK' --timeout 180

vgate_assert 02 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 02 serial-contains 'exec: loaded GOBIG.ELF'
vgate_assert 02 serial-contains 'big: blob bytes 8388608'
vgate_assert 02 serial-contains 'big: banner A B C E D'
vgate_assert 02 serial-contains 'big: sum 335'
vgate_assert 02 serial-contains 'virelai-go big OK'
vgate_assert 02 serial-absent ': image too large'
vgate_assert 02 serial-absent '[EXC] parking:'
vgate_assert 02 serial-absent 'exited status=139'

# M70c-K (issue #1504) run 03: the bound MOVED, it did not disappear. Both
# refusals are asserted by their own message, and the run ends on the
# second one — so a loader that silently accepted either fixture, or that
# stopped after the first refusal instead of returning to the prompt, cannot
# go green. The truncated case here is the parse-time detection (a payload
# range past the volume's STAT size); the mid-read detection (a file that
# shrinks between that parse and the streamed read) needs a host-side seam
# and is pinned by `kernel/tests/monitor_test.zig` instead.
vgate_run 03 -- --script '$RUN_DIR/script3.txt' --script-expect 'TRUNC.ELF: truncated image' --timeout 180

vgate_assert 03 serial-contains 'XL.ELF: image too large (acceptance bound'
vgate_assert 03 serial-contains 'TRUNC.ELF: truncated image'
vgate_assert 03 serial-absent 'XL.ELF: truncated image'
vgate_assert 03 serial-absent 'TRUNC.ELF: image too large'
vgate_assert 03 serial-absent 'exec: loaded XL.ELF'
vgate_assert 03 serial-absent 'exec: loaded TRUNC.ELF'
vgate_assert 03 serial-absent 'staging buffer'
vgate_assert 03 serial-absent '[EXC] parking:'
vgate_assert 03 python <<'PY'
import os, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
xl = ser.find("XL.ELF: image too large")
tr = ser.find("TRUNC.ELF: truncated image")
if xl == -1 or tr == -1:
    sys.exit("FAIL: a refusal is missing (xl=%d tr=%d)" % (xl, tr))
if xl > tr:
    sys.exit("FAIL: TRUNC.ELF was refused BEFORE XL.ELF — the script's second line was dropped")
# The monitor must still be reading input after each refusal (it is the
# second line that proves the first did not kill it) — and no loader may
# have reached the success marker for either file.
if "exec: loaded XL.ELF" in ser or "exec: loaded TRUNC.ELF" in ser:
    sys.exit("FAIL: a refused image reported a successful load")
print("both refusals in order: XL at %d, TRUNC at %d" % (xl, tr))
PY
vgate_assert 02 python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
m = re.search(r"exec: loaded GOBIG\.ELF .*datapages=(\d+)", ser)
if not m:
    sys.exit("FAIL: no `exec: loaded GOBIG.ELF ... datapages=` line")
pages = int(m.group(1))
if pages < 2048:
    sys.exit("FAIL: datapages=%d; an 8 MiB data segment needs >= 2048 pages" % pages)
print("streamed 8 MiB data segment mapped: datapages=%d" % pages)
PY

# M70c (#1455) run 04: the transfer half of the card's "measure the honest
# transfer and mmap story" — the guest reads a multi-MB file out of the host
# share with nothing staged in between.
#
# The assert is the guest's own byte stream, held to the file on macOS: the
# exact byte count, the call count the kernel's 2048-byte per-call read cap
# implies (ceil(bytes/2048) — reachable only if a call really moves 2048 B),
# and the FNV-1a hash of the bytes READ. A short read, a dropped chunk, a
# read from the wrong offset or a page of zeros all produce a different hash,
# and none of them can be printed into place. The rate is extracted and
# reported (it lands in this run's log, which is what ADR 0035 quotes); it is
# deliberately NOT asserted, because a throughput is a property of the machine.
vgate_run 04 -- --script '$RUN_DIR/script4.txt' --script-expect 'goread: GOREAD OK' --timeout 300

vgate_assert 04 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 04 serial-contains 'exec: loaded GOREAD.ELF'
vgate_assert 04 serial-contains 'goread: GOREAD OK'
vgate_assert 04 serial-absent 'goread: FAIL'
vgate_assert 04 serial-absent '[EXC] parking:'
vgate_assert 04 serial-absent 'exited status=139'
vgate_assert 04 python <<'PY'
import os, re, sys
share = os.environ.get("VG_SHARE") or os.path.join(os.environ["RUN_DIR"], "share")
src = os.path.join(share, "GOBIG.ELF")
if not os.path.exists(src):
    sys.exit("FAIL: the fixture run 04 reads is missing: " + src)
n = os.path.getsize(src)
calls = (n + 2047) // 2048  # one kernel read call moves at most 2048 bytes
h = 0xcbf29ce484222325
with open(src, "rb") as fh:
    while True:
        b = fh.read(1 << 20)
        if not b:
            break
        for byte in b:
            h = ((h ^ byte) * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF
ser = open(os.environ["VG_SER"], errors="replace").read()
want = "goread: file /host/GOBIG.ELF bytes %d calls %d max 2048" % (n, calls)
if want not in ser:
    sys.exit("FAIL: the guest's exact read line is absent.\n  want: %r\n"
             "  (a shorter call count means the kernel moved more than 2048 B per "
             "read, or the file the guest read is not the file on macOS)" % want)
if ("goread: fnv 0x%016x" % h) not in ser:
    sys.exit("FAIL: the guest hashed different bytes than the file on macOS "
             "(want 0x%016x)" % h)
m = re.search(r"goread: rate us (\d+) kib_s (\d+) ns_call (\d+)", ser)
if not m:
    sys.exit("FAIL: no `goread: rate` line — the measurement did not report")
us, kib, ns = (int(x) for x in m.groups())
if us <= 0 or kib <= 0 or ns <= 0:
    sys.exit("FAIL: the rate line is zero: " + m.group(0))
print("read %d B from the share in %d calls at the 2048-byte cap: %d us -> %d KiB/s (%d ns/call)"
      % (n, calls, us, kib, ns))
print("fnv 0x%016x matches the file on macOS" % h)
PY

# M70c-S1L (issue #1540) run 05: an `os`-importing image runs at all.
#
# The run is the assertion that the aperture story moved: before this card the
# same binary loaded and then died in `runtime.mallocinit` with "cannot allocate
# memory", because its break base landed inside the data aperture the kernel
# protects through the argv+envp block. Nothing about the guest's arithmetic is
# asserted here — the card's claim is that a std program executes, and the
# fixture's own output is what proves it. Where a number has to come from
# somewhere other than the guest, it comes from the file on macOS: the 9.5 MiB
# image is read through os.File and folded into FNV-1a by the host too, the
# second raw read is checked against the staged file's own byte at that offset,
# the directory it walks is one it created (so the exact entry counts are
# assertable), and the remove is checked from the host side of the share.
vgate_run 05 -- --script '$RUN_DIR/script5.txt' --script-expect 'gosyscall: GOSYSCALL OK' --timeout 300

vgate_assert 05 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 05 serial-contains 'exec: loaded GOSYSCALL.ELF'
vgate_assert 05 serial-contains 'gosyscall: os mkdir ok'
vgate_assert 05 serial-contains 'gosyscall: read 2048'
vgate_assert 05 serial-contains 'gosyscall: absent no such file or directory'
vgate_assert 05 serial-contains 'gosyscall: os remove ok 2'
vgate_assert 05 serial-contains 'gosyscall: GOSYSCALL OK'
vgate_assert 05 serial-absent 'gosyscall: MISMATCH'
vgate_assert 05 serial-absent 'gosyscall: FAIL'
vgate_assert 05 serial-absent 'cannot allocate memory'
vgate_assert 05 serial-absent '[EXC] parking:'
vgate_assert 05 serial-absent 'exited status=139'
vgate_assert 05 python <<'PY'
import os, sys
share = os.environ.get("VG_SHARE") or os.path.join(os.environ["RUN_DIR"], "share")
src = os.path.join(share, "GOBIG.ELF")  # what the fixture read through os.File
if not os.path.exists(src):
    sys.exit("FAIL: the fixture's input is missing: " + src)
n = os.path.getsize(src)
# The fixture folds the bytes with 32-bit FNV-1a as it reads them through
# os.File; the host folds the file on macOS the same way and the two have to
# agree. Every byte of the file passes through os.File -> internal/poll ->
# the port's syscall.Read: a dropped or short chunk, a re-read or a wrong
# offset all change the hash, and the byte count alone would not.
h = 2166136261
with open(src, "rb") as fh:
    blob = fh.read()
for byte in blob:
    h = ((h ^ byte) * 16777619) & 0xFFFFFFFF
ser = open(os.environ["VG_SER"], errors="replace").read()
if "gosyscall: os bytes %d hash 0x%08x" % (n, h) not in ser:
    sys.exit("FAIL: the fixture's os.File hash does not match the file on macOS "
             "(want bytes %d hash 0x%08x)" % (n, h))
# The raw layer's second read must continue at offset 2048, i.e. report that
# byte — a layer that re-read page one would report the ELF magic's second byte.
want_second = "gosyscall: second read 1 byte %d" % blob[2048]
if want_second not in ser:
    sys.exit("FAIL: the second raw read did not continue the file (want %r)" % want_second)
# Stat's parent-row route cannot reach an entry past the kernel's 16 rows, so a
# file in /host is sized by the reading fallback: the number has to be the real
# file size, and "isdir" must be false for a file.
for line in ("gosyscall: stat size %d isdir false" % n,
             "gosyscall: fstat size %d" % n,
             "gosyscall: os stat size %d isdir false" % n):
    if line not in ser:
        sys.exit("FAIL: missing %r (the file is %d B on macOS)" % (line, n))
# The owned directory: two files created by the fixture, each row 40 bytes.
for line in ("gosyscall: raw dirent bytes 80",
             "gosyscall: os dir entries 2 files 2 dirs 0",
             "gosyscall: os stat PAYLOAD.TXT size 32 isdir false",
             "gosyscall: os write PAYLOAD.TXT bytes 32",
             "gosyscall: os readback PAYLOAD.TXT ok bytes 32",
             "gosyscall: os dir entries 0 files 0 dirs 0"):
    if line not in ser:
        sys.exit("FAIL: missing %r" % line)
# The two host-side facts the guest cannot fake from inside: the removes
# really reached the share (the files are gone from the host's copy), and the
# directory the guest created is empty there too.
d = os.path.join(share, "GOSYSCALL.D")
if not os.path.isdir(d):
    sys.exit("FAIL: the fixture's os.Mkdir did not reach the share: " + d)
left = sorted(os.listdir(d))
if left:
    sys.exit("FAIL: the guest's os.Remove did not reach the share: %r remains" % left)
print("os layer: %d B hashed 0x%08x; os.Mkdir/WriteFile/ReadDir/Stat/Remove reached the share"
      % (n, h))
PY

# --- M70c-S1T (issue #1543): the guest builds, with its own toolchain --------
#
# The chain is three boots because the monitor's `exec` returns immediately
# (tools/gate/SPEC.md): the share carries the intermediate between runs, and
# each run ends on the guest's own exit-status line, which the scheduler prints
# (`procs <name> exited status=<n>`). The intermediate is a real artifact of
# the guest: run 07 links the object run 06 compiled, and run 08 executes the
# ELF run 07 produced.
#
# The argv is what the kernel's 8x32-byte block allows (kernel/src/exec.zig
# max_exec_args/arg_slot_bytes), which is why the flags are terse and the
# import config is one flat file in the share; tools/go/stage-selfhost.sh
# checks those lines against the budget before a boot is spent on them.
vgate_file script6.txt <<'EOF'
exec GOCMDCOMPILE.ELF -o /host/HELLO.o -importcfg /host/GOIMPORT.CFG /host/HELLO.GO
EOF

vgate_file script7.txt <<'EOF'
sysinfo
EOF

vgate_file script8.txt <<'EOF'
sysinfo
syscalls
echo selfhost-compile-done
EOF

vgate_file script9.txt <<'EOF'
exec GOCMDLINK.ELF -importcfg /host/GOIMPORT.CFG -tmpdir /host -o /host/HELLO2.ELF /host/HELLO.o
EOF

vgate_file script10.txt <<'EOF'
sysinfo
EOF

vgate_file script11.txt <<'EOF'
sysinfo
syscalls
echo selfhost-link-done
EOF

vgate_file script12.txt <<'EOF'
exec HELLO2.ELF
EOF

# Runs 06-08's staging: the toolchain images, and the import config + package
# archives the guest's linker resolves symbols against. Both are host
# prerequisites with their own scripts, so this fails closed with the script
# to run rather than booting a guest that cannot find its inputs.
vgate_setup_python <<'PY'
import os, shutil, sys
share = os.path.join(os.environ["RUN_DIR"], "share")
tools = [".build/go/GOCMDCOMPILE.ELF", ".build/go/GOCMDLINK.ELF"]
stage = ".build/go/selfhost"
if not os.path.isdir(stage):
    sys.exit("%s missing - run: bash tools/go/stage-selfhost.sh" % stage)
for src in tools:
    if not os.path.exists(src):
        sys.exit("%s missing - run: bash tools/go/build-gotool.sh" % src)
    shutil.copy(src, os.path.join(share, os.path.basename(src)))
    print("staged %s (%d bytes)" % (os.path.basename(src), os.path.getsize(src)))
n = total = 0
for name in sorted(os.listdir(stage)):
    if name.startswith("."):
        continue
    src = os.path.join(stage, name)
    shutil.copy(src, os.path.join(share, name))
    n += 1
    total += os.path.getsize(src)
print("staged %d selfhost files (%.2f MiB): import config + archives + HELLO.GO"
      % (n, total / 1048576.0))
# The chain assumes the share survives between runs and that run 07 links what
# run 06 wrote; both are checked by the asserts below, not assumed here.
for stale in ("HELLO.o", "HELLO2.ELF"):
    p = os.path.join(share, stale)
    if os.path.exists(p):
        os.remove(p)
        print("removed stale %s from a previous gate run" % stale)
PY

# Run 06: the guest's cmd/compile compiles the pinned hello. It prints nothing
# on success, so the evidence is the object it wrote (read back on macOS) and
# its own exit status. The object is an ar archive whose header line names the
# target it was compiled for: `go object virelai arm64 go1.27.1 ...` is not a
# line a copied binary or a no-op compile can produce.
vgate_run 06 -- --script '$RUN_DIR/script6.txt' --script2 '$RUN_DIR/script7.txt' --script2-after 'exec: loaded GOCMDCOMPILE.ELF' --script3 '$RUN_DIR/script8.txt' --script3-after 'procs GOCMDCOMPILE.ELF exited status=0' --script-expect 'selfhost-compile-done' --timeout 300

vgate_assert 06 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 06 serial-contains 'exec: loaded GOCMDCOMPILE.ELF'
vgate_assert 06 serial-contains 'procs GOCMDCOMPILE.ELF exited status=0'
vgate_assert 06 serial-absent '[EXC] parking:'
vgate_assert 06 serial-absent 'cannot allocate memory'
vgate_assert 06 serial-absent 'panic:'
vgate_assert 06 python <<'PY'
import os, re, sys
share = os.environ.get("VG_SHARE") or os.path.join(os.environ["RUN_DIR"], "share")
obj = os.path.join(share, "HELLO.o")
if not os.path.exists(obj):
    sys.exit("FAIL: the in-guest compile produced no object at " + obj)
raw = open(obj, "rb").read()
if len(raw) < 1024:
    sys.exit("FAIL: HELLO.o is only %d bytes" % len(raw))
if not raw.startswith(b"!<arch>"):
    sys.exit("FAIL: HELLO.o is not an ar archive; first bytes %r" % raw[:16])
for want in (b"go object virelai arm64 ", b"__.PKGDEF", b"_go_.o", b"main.main"):
    if want not in raw:
        sys.exit("FAIL: HELLO.o has no %r" % want)
hdr = re.search(rb"go object [^\n]{0,64}", raw)
print("in-guest compile: HELLO.o %d bytes (ar archive); header %r"
      % (len(raw), hdr.group(0).decode()))
ser = open(os.environ["VG_SER"], errors="replace").read()
samples = re.findall(r"allocator:\s+armed=(\d) total=(0x[0-9a-f]+) free=(0x[0-9a-f]+) "
                     r"excluded=(0x[0-9a-f]+) regions=(0x[0-9a-f]+)", ser)
for i, (armed, total, free, excl, regions) in enumerate(samples):
    t, f = int(total, 16), int(free, 16)
    if f > t:
        sys.exit("FAIL: allocator sample %d has free > total" % i)
    print("guest frames at sample %d: used=%d of %d (%d KiB of %d KiB) on a %d-page guest"
          % (i, t - f, t, (t - f) * 4, t * 4, 65215))
m = re.search(r"\s63 sys_mmap calls=(\d+)", ser)
print("in-guest compile sys_mmap calls: %s" % (m.group(1) if m else "not reported"))
PY

# Run 07: the guest's cmd/link links that object into an ELF, resolving
# symbols out of the package archives staged in the share. The host then holds
# the result to the SAME loader rules the kernel enforces before run 08 is
# allowed to execute it — segment count, sum of memsz, gap ceiling, W^X order,
# entry-inside-segment-0 and the argv+envp page slack.
vgate_run 07 -- --script '$RUN_DIR/script9.txt' --script2 '$RUN_DIR/script10.txt' --script2-after 'exec: loaded GOCMDLINK.ELF' --script3 '$RUN_DIR/script11.txt' --script3-after 'procs GOCMDLINK.ELF exited status=0' --script-expect 'selfhost-link-done' --timeout 900

vgate_assert 07 serial-contains 'exec: loaded GOCMDLINK.ELF'
vgate_assert 07 serial-contains 'procs GOCMDLINK.ELF exited status=0'
vgate_assert 07 serial-absent '[EXC] parking:'
vgate_assert 07 serial-absent 'cannot allocate memory'
vgate_assert 07 serial-absent 'panic:'
vgate_assert 07 python <<'PY'
import os, re, struct, sys
share = os.environ.get("VG_SHARE") or os.path.join(os.environ["RUN_DIR"], "share")
elf = os.path.join(share, "HELLO2.ELF")
if not os.path.exists(elf):
    sys.exit("FAIL: the in-guest link produced nothing at " + elf)
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
print("in-guest link: HELLO2.ELF %d bytes, %d segments, memsz %d (%#x), slack %#x"
      % (len(d), len(segs), total, total, slack))
ser = open(os.environ["VG_SER"], errors="replace").read()
for i, (armed, t, f, excl, regions) in enumerate(re.findall(
        r"allocator:\s+armed=(\d) total=(0x[0-9a-f]+) free=(0x[0-9a-f]+) "
        r"excluded=(0x[0-9a-f]+) regions=(0x[0-9a-f]+)", ser)):
    t, f = int(t, 16), int(f, 16)
    print("guest frames at sample %d: used=%d of %d (%d KiB of %d KiB)"
          % (i, t - f, t, (t - f) * 4, t * 4))
if fails:
    for f in fails:
        print("FAIL: " + f)
    sys.exit(1)
print("HELLO2.ELF satisfies every loader rule the kernel enforces")
PY

# Run 08: the binary the GUEST produced runs on the kernel. This is the
# end-to-end claim of the card: compile in-guest, link in-guest, execute the
# result. The pinned lines are the fixture's own vocabulary (phase 0a's
# runtime surface: console, sbrk heap growth, a GC cycle).
#
# No `procs HELLO2.ELF exited status=0` assert here: the run stops ON the
# program's last pinned line, which is printed before the process is reaped,
# so the exit line races the stop rather than reporting on the program. The
# absent-exception asserts are what rule out a crash.
vgate_run 08 -- --script '$RUN_DIR/script12.txt' --script-expect 'virelai-go OK' --timeout 300

vgate_assert 08 serial-contains 'exec: loaded HELLO2.ELF'
vgate_assert 08 serial-contains 'hello from virelai'
vgate_assert 08 serial-contains 'GOOS=virelai GOARCH=arm64 gc runtime alive'
vgate_assert 08 serial-contains 'heap: wrote 1048576 bytes'
vgate_assert 08 serial-contains 'gc: cycle completed'
vgate_assert 08 serial-contains 'virelai-go OK'
vgate_assert 08 serial-absent '[EXC] parking:'
vgate_assert 08 serial-absent 'exited status=139'
vgate_assert 08 serial-absent 'cannot allocate memory'
