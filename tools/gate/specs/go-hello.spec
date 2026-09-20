# go-hello.spec -- issue #1163, GOOS=virelai phase 0a: the gc Go runtime
# runs on VirelaiOS. Runs 01-03 (M70c-K, #1504): svc #0 console + sbrk heap +
# GC; a >9 MiB image STREAMED into its mapped pages; the two refusals by name.
# Run 04 (M70c, #1455): the guest reads that same 9.5 MiB from the share
# end to end at the ABI's 2048-byte read cap — bytes, call count and FNV hash
# asserted against the file on macOS, the rate reported (ADR 0035 measures it).
#
# HOST PREREQUISITE (fails honestly when missing): not hermetic —
# `.build/go/{GOHELLO,GOBIG,GOREAD}.ELF` must exist first, via `bash
# tools/go/build-go.sh tools/go/hello.go tools/go/gobig.go tools/go/goread.go`
# (fork prerequisites in tools/go/README.md); the setup hook says the same.
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

vgate_setup_python <<'PY'
import os, shutil, sys
share = os.path.join(os.environ["RUN_DIR"], "share")
srcs = [".build/go/GOHELLO.ELF", ".build/go/GOBIG.ELF", ".build/go/GOREAD.ELF"]
missing = [p for p in srcs if not os.path.exists(p)]
if missing:
    sys.exit("%s missing — build the fork binaries first: "
             "bash tools/go/build-go.sh tools/go/hello.go tools/go/gobig.go "
             "tools/go/goread.go "
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
