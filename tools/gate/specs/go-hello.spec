# go-hello.spec -- issue #1163, GOOS=virelai phase 0a: the gc Go runtime
# runs on VirelaiOS — and (M70c-K, issue #1504) a Go image too big for the
# 2 MiB staging buffer is STREAMED into its mapped pages instead of refused.
#
# Run 01: svc #0 console, sbrk heap over demand-backed sys_mmap, a GC
# cycle, CNTPCT_EL0 time. Run 02: the >9 MiB GOBIG.ELF, whose banner is
# read back at runtime from 1/4/8 MiB into the streamed payload. Run 03:
# the two refusals by name — a file past the acceptance bound and a file
# that ends before its own header promises. All on real VZ hardware.
#
# HOST PREREQUISITE (fails honestly when missing): not hermetic —
# `.build/go/{GOHELLO,GOBIG}.ELF` must exist first, via `bash
# tools/go/build-go.sh tools/go/hello.go tools/go/gobig.go` (fork
# prerequisites in tools/go/README.md); the setup hook says the same.
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

vgate_setup_python <<'PY'
import os, shutil, sys
share = os.path.join(os.environ["RUN_DIR"], "share")
srcs = [".build/go/GOHELLO.ELF", ".build/go/GOBIG.ELF"]
missing = [p for p in srcs if not os.path.exists(p)]
if missing:
    sys.exit("%s missing — build the fork binaries first: "
             "bash tools/go/build-go.sh tools/go/hello.go tools/go/gobig.go "
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
