# go-fart.spec -- M58f (issue #1327) class-B gate: FART.ELF, the Go sound app.
# The runner boots with --sound and execs FART.ELF. The Go program asks slot 42
# for the negotiated state (the vi audio bindings, #1328), synthesizes one
# descending 550 ms blip in exactly that format, and hands the WHOLE buffer to
# vi.AudioPlay -- 211200 bytes at FLOAT/48 kHz/stereo, over three times the
# kernel's 64 KiB audio_max_len, so it is vi's 4096-byte chunking that makes it
# legal at all. The app prints the chunk arithmetic it expects; the gate checks
# it against the kernel's own sys_audio_play count, so the run proves the
# wrapper and not just the app.
#
# Run 02 is the same binary with NO --sound (the default VM), where slot 42
# succeeds with ready=0 and slot 43 refuses with ENXIO. The app reports that
# honestly and exits 0 -- a documented outcome, not a failure -- so the
# soundless contract is observed here rather than asserted in prose.
#
# HOST PREREQUISITE (fails the gate honestly when missing):
#   bash tools/go/build-fart.sh   ->  .build/go/FART.ELF
#
# exec-order: assert-proven -- each run ends on its own script marker, but the
# asserts read the program's vocabulary (`fart: info`, `fart: blip`, `fart:
# done`), and the stage gate that forwards `syscalls` waits on `fart: done`, so
# a program that never ran cannot pass. Residual risk is a late tail (flake),
# never a false pass (tools/gate/SPEC.md).

vgate_name go-fart "issue #1327 M58f: a Go app plays a synthesized blip through slot 43 on VZ (and refuses honestly without a device)"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE
vgate_repeat 1 BOOTS

# Stage 1 is the exec; stage 2 reports the kernel's own syscall counters, which
# is where the chunk arithmetic is cross-checked.
vgate_file script.txt <<'EOF'
exec FART.ELF
EOF

vgate_file script2.txt <<'EOF'
syscalls
echo go-fart-live-ok
EOF

vgate_file script3.txt <<'EOF'
syscalls
echo go-fart-soundless-ok
EOF

vgate_setup_python <<'PY'
import os, shutil, sys
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
src = os.path.join(".build", "go", "FART.ELF")
if not os.path.exists(src):
    sys.exit("FART.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-fart.sh")
shutil.copy(src, os.path.join(share, "FART.ELF"))
print("staged FART.ELF into share (%d bytes)" % os.path.getsize(os.path.join(share, "FART.ELF")))
PY

# 01: the armed device.
vgate_run 01 -- \
    --sound \
    --script '$RUN_DIR/script.txt' \
    --script-after 'tasks user-el0 exited status=7' \
    --script2 '$RUN_DIR/script2.txt' \
    --script2-after 'fart: done' \
    --script2-delay 3 \
    --script-expect 'go-fart-live-ok' --timeout 150

# 02: the default (soundless) VM -- same binary, honest ENXIO.
vgate_run 02 -- \
    --script '$RUN_DIR/script.txt' \
    --script-after 'tasks user-el0 exited status=7' \
    --script2 '$RUN_DIR/script3.txt' \
    --script2-after 'fart: done' \
    --script2-delay 3 \
    --script-expect 'go-fart-soundless-ok' --timeout 150

vgate_assert 01 output-contains 'SOUND: virtio-snd attached'
vgate_assert 01 serial-contains 'exec: loaded FART.ELF'
vgate_assert 01 serial-contains 'fart: info fmt=19 rate=7 ch=2 period=4096 max=65536 ready=1'
vgate_assert 01 serial-contains 'fart: blip frames=26400 bytes=211200 played=211200 chunks=52 hash=4173224929'
vgate_assert 01 serial-contains 'fart: done'
vgate_assert 01 serial-contains '42 sys_audio_info calls=1'
vgate_assert 01 serial-contains '43 sys_audio_play calls=52'
vgate_assert 01 serial-contains 'go-fart-live-ok'
# The app's own exit status. `procs` is the process-level line; the
# `tasks FART.ELF exited status=137` lines above it are the Go runtime's
# remaining Ms being killed by the exit teardown, which is normal and is NOT
# what this asserts.
vgate_assert 01 serial-contains 'procs FART.ELF exited status=0'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 serial-absent 'exited status=139'

# Run 02 is the negative half: one info call, one refused play call, exit 0.
vgate_assert 02 serial-contains 'exec: loaded FART.ELF'
vgate_assert 02 serial-contains 'fart: info fmt=255 rate=255 ch=0 period=4096 max=65536 ready=0'
vgate_assert 02 serial-contains 'fart: no audio device (ENXIO); soundless VM, nothing to fart'
vgate_assert 02 serial-contains 'fart: done'
vgate_assert 02 serial-contains '42 sys_audio_info calls=1'
vgate_assert 02 serial-contains '43 sys_audio_play calls=1'
vgate_assert 02 serial-contains 'go-fart-soundless-ok'
# A refused play is not a failure: the app reports ENXIO and exits 0.
vgate_assert 02 serial-contains 'procs FART.ELF exited status=0'
vgate_assert 02 serial-absent '[EXC] parking:'
vgate_assert 02 serial-absent 'exited status=139'

# The arithmetic the markers claim, checked against each other and against the
# kernel's own syscall counter. Every one of these can fail on a real defect:
# a short play, an unchunked submission (the kernel would have refused it with
# ENAMETOOLONG), a zero-filled buffer (a digest is not a length), a wrapper
# that quietly changed its chunk size.
vgate_assert 01 python <<'PY'
import os, re, sys

ser = open(os.environ["VG_SER"], "rb").read().decode("latin1", errors="replace")

m = re.search(r"fart: blip frames=(\d+) bytes=(\d+) played=(\d+) chunks=(\d+) hash=(\d+)", ser)
if not m:
    sys.exit("ERROR: no blip marker in serial")
frames, nbytes, played, chunks, digest = (int(g) for g in m.groups())

# FLOAT(19) is 4 bytes per sample, stereo: 8 bytes per frame.
if nbytes != frames * 8:
    sys.exit(f"ERROR: bytes={nbytes} is not frames={frames} * 8")
if frames != 26400:
    sys.exit(f"ERROR: frames={frames}, want 550 ms at 48 kHz")
if played != nbytes:
    sys.exit(f"ERROR: the kernel confirmed {played} of {nbytes} bytes")
if not 0 < digest < 2**32:
    sys.exit(f"ERROR: bad digest {digest}")

# Over the per-call bound: one unchunked sys_audio_play could not have carried
# this buffer (ENAMETOOLONG), so the chunking is load-bearing.
if nbytes <= 65536:
    sys.exit(f"ERROR: {nbytes} bytes does not exceed the 64 KiB bound")
if chunks != (nbytes + 4095) // 4096:
    sys.exit(f"ERROR: chunks={chunks} is not the ceil of {nbytes}/4096")

calls = re.search(r"43 sys_audio_play calls=(\d+)", ser)
if not calls:
    sys.exit("ERROR: no sys_audio_play counter in serial")
if int(calls.group(1)) != chunks:
    sys.exit(f"ERROR: kernel counted {calls.group(1)} play calls, app predicted {chunks}")
PY
