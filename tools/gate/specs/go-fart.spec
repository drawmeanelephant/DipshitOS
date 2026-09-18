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
# M70f2 (#1476) gave the same binary three more phases, and this spec gates
# them: slots 44/45 (volume/mute) through the Go seam, the MUTED-DRAIN
# IDENTITY, and a JINGLE-shaped note sequence. All three run AFTER the blip, so
# nothing M58f asserted about the blip changed -- including its digest. What
# changed is the run's TOTAL sys_audio_play count (52 -> 196), which is why it
# is now a sum of four phases rather than one number: the python block below
# checks each phase's arithmetic separately, then the total against the
# kernel's single counter.
#
# The two properties worth naming, because they are the reason the phases
# exist:
#   - `fart: vol over=101 err=EINVAL` is ADR 0007 row 44's rule ("honest
#     refusal, no silent clamping") observed from EL0. A kernel that started
#     clamping answers err=nil and the app prints CLAMPED instead, which is
#     asserted absent.
#   - `fart: unmuted played=` and `fart: muted played=` are the SAME buffer
#     submitted twice, once each way, so a mute that shortened the return could
#     not hide. What that does NOT prove is that the device received zeros --
#     nothing in this project observes the waveform that reaches the device
#     (host-side capture is out of scope), so silence is asserted as kernel
#     state in live-sound-control.spec, never as audio.
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
# M70f2 (#1476), phase 2: volume and mute. `err=EINVAL` is the kernel's
# refusal of an out-of-range gain (no clamping), and the tone's bytes are
# submitted twice -- unmuted, then muted -- with the same confirmed count.
vgate_assert 01 serial-contains 'fart: vol over=101 err=EINVAL'
vgate_assert 01 serial-contains 'fart: vol set=40 echo=40'
vgate_assert 01 serial-contains 'fart: tone frames=12000 bytes=96000 chunks=24 hash=2667358661'
vgate_assert 01 serial-contains 'fart: unmuted played=96000'
vgate_assert 01 serial-contains 'fart: mute on'
vgate_assert 01 serial-contains 'fart: muted played=96000'
vgate_assert 01 serial-contains 'fart: mute off'
# The app's own violation marker, asserted absent: it prints CLAMPED when the
# kernel accepts an out-of-range volume, so a green run says the refusal
# happened and was EINVAL, not that the check was skipped.
vgate_assert 01 serial-absent 'CLAMPED'

# M70f2 (#1476), phase 3: the JINGLE-shaped sequence. Two of the four notes are
# pinned with their digests (the ends of the arpeggio); the python block checks
# all four and their totals, so a middle note cannot drift unnoticed.
vgate_assert 01 serial-contains 'fart: note 1 f=262 dur=250 chunks=24 played=96000 hash=2033131025'
vgate_assert 01 serial-contains 'fart: note 2 f=330 dur=250 chunks=24 played=96000'
vgate_assert 01 serial-contains 'fart: note 3 f=392 dur=250 chunks=24 played=96000'
vgate_assert 01 serial-contains 'fart: note 4 f=523 dur=250 chunks=24 played=96000 hash=3291073141'
vgate_assert 01 serial-contains 'fart: seq notes=4 frames=48000 bytes=384000 played=384000 chunks=96'

# Re-pinned by M70f2: 52 (blip) + 24 (unmuted) + 24 (muted) + 96 (sequence).
vgate_assert 01 serial-contains '43 sys_audio_play calls=196'
vgate_assert 01 serial-contains '44 sys_audio_volume calls=2'
vgate_assert 01 serial-contains '45 sys_audio_mute calls=2'
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
# A soundless VM must not touch the controls either: the app's whole vol/mute
# phase is behind the ready=1 check, and this is where that is observed rather
# than assumed.
vgate_assert 02 serial-contains '44 sys_audio_volume calls=0'
vgate_assert 02 serial-contains '45 sys_audio_mute calls=0'
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

# --- M70f2 (#1476): the volume/mute phase -------------------------------
volset = re.search(r"fart: vol set=(\d+) echo=(\d+)", ser)
volover = re.search(r"fart: vol over=(\d+) err=(\w+)", ser)
tone = re.search(r"fart: tone frames=(\d+) bytes=(\d+) chunks=(\d+) hash=(\d+)", ser)
unmuted = re.search(r"fart: unmuted played=(\d+)", ser)
muted = re.search(r"fart: muted played=(\d+)", ser)
for name, hit in (("vol set", volset), ("vol over", volover), ("tone", tone),
                  ("unmuted", unmuted), ("muted", muted)):
    if not hit:
        sys.exit(f"ERROR: no {name} marker in serial")
if "CLAMPED" in ser:
    sys.exit("ERROR: the app reported a CLAMPED out-of-range volume; the kernel must refuse with EINVAL")

# ADR 0007 row 44's bound is 100, so 101 is out of range and the answer must be
# an honest EINVAL -- a clamp would have answered a value instead.
if int(volover.group(1)) != 101:
    sys.exit(f"ERROR: the over-range probe was {volover.group(1)}, want 101")
if volover.group(2) != "EINVAL":
    sys.exit(f"ERROR: an over-range volume answered {volover.group(2)}, want EINVAL")
if int(volset.group(1)) != int(volset.group(2)):
    sys.exit(f"ERROR: slot 44 echoed {volset.group(2)} for set={volset.group(1)}")

tframes, tbytes, tchunks, thash = (int(g) for g in tone.groups())
if tbytes != tframes * 8:
    sys.exit(f"ERROR: tone bytes={tbytes} is not frames={tframes} * 8")
if tframes != 12000:
    sys.exit(f"ERROR: tone frames={tframes}, want 250 ms at 48 kHz")
if tchunks != (tbytes + 4095) // 4096:
    sys.exit(f"ERROR: tone chunks={tchunks} is not the ceil of {tbytes}/4096")
if not 0 < thash < 2**32:
    sys.exit(f"ERROR: bad tone digest {thash}")

# The muted-drain identity: ONE buffer submitted twice, unmuted then muted,
# must confirm the same bytes both times -- and all of them. A mute that
# shortened the return would be indistinguishable from a device refusal
# (ErrNoAudioDevice), which is exactly why this is an identity and not a "did
# something happen".
if int(unmuted.group(1)) != tbytes:
    sys.exit(f"ERROR: unmuted confirmed {unmuted.group(1)} of {tbytes} bytes")
if int(muted.group(1)) != int(unmuted.group(1)):
    sys.exit(f"ERROR: MUTED-DRAIN IDENTITY BROKEN: muted={muted.group(1)} unmuted={unmuted.group(1)}")
if not ser.find("fart: mute on") < ser.find("fart: muted played=") < ser.find("fart: mute off"):
    sys.exit("ERROR: the muted play is not between 'mute on' and 'mute off'")

# --- M70f2 (#1476): the note sequence -----------------------------------
notes = re.findall(r"fart: note (\d+) f=(\d+) dur=(\d+) chunks=(\d+) played=(\d+) hash=(\d+)", ser)
seq = re.search(r"fart: seq notes=(\d+) frames=(\d+) bytes=(\d+) played=(\d+) chunks=(\d+)", ser)
if not seq:
    sys.exit("ERROR: no sequence summary in serial")
if len(notes) != int(seq.group(1)):
    sys.exit(f"ERROR: {len(notes)} note markers for a summary of {seq.group(1)}")
note_bytes = note_chunks = note_frames = 0
note_hashes = set()
for num, hz, dur, nchunks, nplayed, nhash in notes:
    dur, hz, nchunks, nplayed = int(dur), int(hz), int(nchunks), int(nplayed)
    want_bytes = dur * 48 * 8  # dur ms at 48 kHz, stereo, FLOAT
    if nplayed != want_bytes:
        sys.exit(f"ERROR: note {num} confirmed {nplayed} of {want_bytes} bytes")
    if nchunks != (want_bytes + 4095) // 4096:
        sys.exit(f"ERROR: note {num} chunks={nchunks} is not the ceil of {want_bytes}/4096")
    if hz <= 0:
        sys.exit(f"ERROR: note {num} has f={hz}")
    note_hashes.add(int(nhash))
    note_bytes += nplayed
    note_chunks += nchunks
    note_frames += dur * 48

if len(note_hashes) != len(notes):
    sys.exit(f"ERROR: {len(notes)} notes but {len(note_hashes)} distinct digests: a note is a repeat")
if int(seq.group(2)) != note_frames:
    sys.exit(f"ERROR: sequence summary frames={seq.group(2)} vs per-note {note_frames}")
if int(seq.group(3)) != note_bytes or int(seq.group(4)) != note_bytes:
    sys.exit(f"ERROR: sequence summary bytes={seq.group(3)}/{seq.group(4)} vs per-note {note_bytes}")
if int(seq.group(5)) != note_chunks:
    sys.exit(f"ERROR: sequence summary chunks={seq.group(5)} vs per-note {note_chunks}")

# The load-bearing one: the kernel's single counter must equal the app's
# prediction summed over ALL FOUR phases. (Per-note submission is 96 calls for
# the sequence; one concatenated buffer would have been 94, so a wrapper that
# quietly changed its chunk size cannot agree by accident.)
predicted = chunks + tchunks + tchunks + note_chunks
calls = re.search(r"43 sys_audio_play calls=(\d+)", ser)
if not calls:
    sys.exit("ERROR: no sys_audio_play counter in serial")
if int(calls.group(1)) != predicted:
    sys.exit(f"ERROR: kernel counted {calls.group(1)} play calls, app predicted {predicted} "
             f"(blip+unmuted+muted+sequence)")

# And the control rows are counted too, so a binding that stopped reaching the
# kernel (and just returned success) is caught here instead of trusted.
vol_calls = re.search(r"44 sys_audio_volume calls=(\d+)", ser)
mute_calls = re.search(r"45 sys_audio_mute calls=(\d+)", ser)
if not vol_calls or int(vol_calls.group(1)) != 2:
    sys.exit("ERROR: slot 44 calls=%s, want 2 (refused + accepted)"
             % (vol_calls.group(1) if vol_calls else "none"))
if not mute_calls or int(mute_calls.group(1)) != 2:
    sys.exit("ERROR: slot 45 calls=%s, want 2 (on + off)"
             % (mute_calls.group(1) if mute_calls else "none"))
PY
