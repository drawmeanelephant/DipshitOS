// Command fart is FART.ELF, the M58f (issue #1327) Go sound app: the JINGLE
// equivalent for the Go-is-EL0 arc (#1292).
//
// It is the EL0 audio seam from the Go side, end to end: ask slot 42 what the
// device negotiated (via the `vi` bindings, issue #1328), synthesize ONE
// descending blip in exactly that format/rate/channel count, hand the whole
// buffer to slot 43, and exit. No window, no WM seat — console + audio only,
// so it is independent of TABWM/GOTABWM entirely.
//
// Two things make it more than a port of user/src/jingle.zig:
//
//   - The blip is LONGER THAN THE KERNEL'S PER-CALL BOUND. Int16/FLOAT stereo
//     at 48 kHz makes 550 ms 211 200 bytes, over three times the 64 KiB
//     audio_max_len, so no single sys_audio_play could carry it. vi's chunking
//     is what makes it legal, and the run's syscall count is the proof: the
//     app prints the chunk arithmetic it expects and the kernel counts the
//     calls it actually made. Those two numbers have to agree.
//   - The blip carries a digest. A byte count cannot tell a synthesized rasp
//     from a buffer of zeros; the pinned FNV-1a value can.
//
// Every marker below is printed only AFTER its syscall returned, so the
// go-fart VZ gate can only pass if the program actually ran.
package main

import (
	"virelai/vi"
)

const (
	// markerDone ends either path — the soundless one included — so the gate's
	// stage script needs one anchor, not two.
	markerDone = "fart: done"
)

func main() {
	info, err := vi.AudioQuery()
	if err != nil {
		// The seam itself refused (a non-process caller, or a host build):
		// an unexpected kernel error, not a muted VM.
		vi.ConsoleLine("fart: info error " + err.Error())
		vi.Exit(1)
	}
	vi.ConsoleLine("fart: info fmt=" + vi.Itoa64(int64(info.Format)) +
		" rate=" + vi.Itoa64(int64(info.Rate)) +
		" ch=" + vi.Itoa64(int64(info.Channels)) +
		" period=" + vi.Itoa64(int64(info.PeriodBytes)) +
		" max=" + vi.Itoa64(int64(info.MaxLen)) +
		" ready=" + vi.Itoa64(int64(info.Ready)))

	if info.Ready == 0 {
		noDevice()
	}

	hz := rateHz(info.Rate)
	if hz == 0 {
		vi.ConsoleLine("fart: unknown rate " + vi.Itoa64(int64(info.Rate)))
		vi.Exit(2)
	}
	fb, ok := frameBytes(info.Format, info.Channels)
	if !ok {
		vi.ConsoleLine("fart: cannot encode fmt=" + vi.Itoa64(int64(info.Format)) +
			" ch=" + vi.Itoa64(int64(info.Channels)))
		vi.Exit(2)
	}

	frames := framesFor(DefaultBlip.MS, hz)
	pcm := make([]byte, int(frames*fb))
	if !synthBlip(pcm, DefaultBlip, info.Format, info.Channels, hz) {
		vi.ConsoleLine("fart: synthesis refused dst=" + vi.Itoa64(int64(len(pcm))) + " bytes")
		vi.Exit(2)
	}

	played, err := vi.AudioPlay(pcm)
	vi.ConsoleLine("fart: blip frames=" + vi.Itoa64(int64(frames)) +
		" bytes=" + vi.Itoa64(int64(len(pcm))) +
		" played=" + vi.Itoa64(int64(played)) +
		" chunks=" + vi.Itoa64(int64(chunkCount(len(pcm)))) +
		" hash=" + vi.Itoa64(int64(digest(pcm))))
	if err != nil {
		// A device that answered slot 42 ready but refused the play: report it
		// and fail. (The no-device path never gets here — it exits above.)
		vi.ConsoleLine("fart: play error " + err.Error() +
			" after " + vi.Itoa64(int64(played)) + " bytes")
		vi.Exit(3)
	}
	if played != len(pcm) {
		vi.ConsoleLine("fart: short play " + vi.Itoa64(int64(played)) +
			" of " + vi.Itoa64(int64(len(pcm))))
		vi.Exit(3)
	}

	// M70f2 (#1476): the two phases this app gained for the Go audio arc.
	// They run AFTER the blip, so every marker, byte count and digest M58f's
	// gate asserts about the blip is untouched; only the run's global
	// `syscalls` totals grow, and the spec re-pins them as the sum of the
	// phases below (52 + 24 + 24 + 96 = 196 slot-43 calls).
	if code := volumePhase(info, hz); code != 0 {
		vi.Exit(code)
	}
	if code := sequencePhase(info, hz); code != 0 {
		vi.Exit(code)
	}

	vi.ConsoleLine(markerDone)
	vi.Exit(0)
}

// The M70f2 phases' parameters. They are named constants so the host suite can
// pin the arithmetic the guest then asserts on the VM.
const (
	phaseMS          = 250 // every M70f2 buffer is 250 ms
	volumePhaseGain  = 40  // the in-range gain the muted-drain A/B runs at
	mutedToneHz      = 440 // the A/B tone (A4)
	sequenceStartNum = 1   // the per-note markers are 1-based
)

// sequenceNotes is the JINGLE-shaped half of M70f2 (#1476): a short rising
// arpeggio, each note synthesized and submitted on its own so the app can
// report PER-NOTE accounting — the thing user/src/jingle.zig's gate asserts
// note by note ("jingle: note N f= dur= chunks= played="). C4 E4 G4 C5.
var sequenceNotes = []struct {
	Hz float64
	MS uint32
}{
	{262, phaseMS},
	{330, phaseMS},
	{392, phaseMS},
	{523, phaseMS},
}

// volumePhase is the vol/mute half of M70f2 (#1476) — the shape
// user/src/chime.zig has — and it exists to assert the MUTED-DRAIN IDENTITY.
//
// The identity is asserted as an A/B on identical bytes rather than as a
// one-sided "it returned something": one 250 ms tone is submitted UNMUTED,
// then the SAME buffer is submitted MUTED, and the confirmed byte counts must
// be equal to each other and to the buffer. Two things follow, both
// load-bearing. Muting must not shorten a return — a short return is how this
// seam reports a device refusal (ErrNoAudioDevice), so a mute that shortened
// it would be indistinguishable from a broken device — and the stream
// lifecycle is untouched, which is what "the samples still drain" means.
//
// What this does NOT prove, and must not be read as proving: that the samples
// the device received were zeros. Mute is applied at the kernel's TX submit
// choke point, and nothing in this project observes the waveform that reaches
// the device (host-side capture is a non-goal of the card), so "silent" is
// asserted here as an accounting identity, and as kernel state via the
// monitor's `sound` verb — never as audio. The digest is what keeps the
// submitted bytes honest: both halves submit real signal, so the equality
// cannot be two buffers of zeros agreeing with each other.
//
// Returns 0 on success, else the exit code the caller should die with.
func volumePhase(info vi.AudioInfo, hz uint32) int {
	// Out of range first, and on purpose: ADR 0007 row 44 is "honest refusal,
	// no silent clamping", and this is the only place that rule is observed
	// from EL0. If the kernel ever started clamping, err is nil here and the
	// app says so rather than quietly agreeing with it.
	if n, err := vi.AudioVolume(vi.AudioVolumeMax + 1); err == nil {
		vi.ConsoleLine("fart: vol over=" + vi.Itoa64(int64(vi.AudioVolumeMax+1)) +
			" CLAMPED to " + vi.Itoa64(int64(n)) + " (the kernel must refuse, not clamp)")
		return 4
	} else {
		vi.ConsoleLine("fart: vol over=" + vi.Itoa64(int64(vi.AudioVolumeMax+1)) +
			" err=" + err.Error())
	}

	echo, err := vi.AudioVolume(volumePhaseGain)
	if err != nil {
		vi.ConsoleLine("fart: vol set=" + vi.Itoa64(volumePhaseGain) + " error " + err.Error())
		return 4
	}
	vi.ConsoleLine("fart: vol set=" + vi.Itoa64(volumePhaseGain) + " echo=" + vi.Itoa64(int64(echo)))

	tone := synthTone(info, NoteBlip(mutedToneHz, phaseMS), hz)
	if tone == nil {
		vi.ConsoleLine("fart: tone refused fmt=" + vi.Itoa64(int64(info.Format)) +
			" ch=" + vi.Itoa64(int64(info.Channels)))
		return 2
	}
	vi.ConsoleLine("fart: tone frames=" + vi.Itoa64(int64(framesFor(phaseMS, hz))) +
		" bytes=" + vi.Itoa64(int64(len(tone))) +
		" chunks=" + vi.Itoa64(int64(chunkCount(len(tone)))) +
		" hash=" + vi.Itoa64(int64(digest(tone))))

	unmuted, err := vi.AudioPlay(tone)
	if err != nil {
		vi.ConsoleLine("fart: unmuted play error " + err.Error() +
			" after " + vi.Itoa64(int64(unmuted)) + " bytes")
		return 5
	}
	vi.ConsoleLine("fart: unmuted played=" + vi.Itoa64(int64(unmuted)))
	if unmuted != len(tone) {
		vi.ConsoleLine("fart: unmuted short " + vi.Itoa64(int64(unmuted)) +
			" of " + vi.Itoa64(int64(len(tone))))
		return 5
	}

	if err := vi.AudioMute(true); err != nil {
		vi.ConsoleLine("fart: mute on error " + err.Error())
		return 4
	}
	vi.ConsoleLine("fart: mute on")

	muted, err := vi.AudioPlay(tone)
	if err != nil {
		vi.ConsoleLine("fart: muted play error " + err.Error() +
			" after " + vi.Itoa64(int64(muted)) + " bytes")
		return 5
	}
	vi.ConsoleLine("fart: muted played=" + vi.Itoa64(int64(muted)))
	if muted != unmuted {
		vi.ConsoleLine("fart: muted-drain identity broken: muted=" + vi.Itoa64(int64(muted)) +
			" of " + vi.Itoa64(int64(len(tone))) + " bytes, unmuted=" + vi.Itoa64(int64(unmuted)))
		return 5
	}

	if err := vi.AudioMute(false); err != nil {
		vi.ConsoleLine("fart: mute off error " + err.Error())
		return 4
	}
	vi.ConsoleLine("fart: mute off")
	return 0
}

// sequencePhase is the JINGLE-shaped half of M70f2 (#1476): play a note
// sequence, one slot-43 call per period, and report the accounting per note
// and in total.
//
// The total `chunks=` is the sum of the per-note chunk counts, NOT
// chunkCount(total bytes): each note is submitted as its own buffer, so 4 x
// 24 = 96 calls where one concatenated 384 000-byte buffer would have been 94.
// The app prints the former because that is what the kernel's syscall counter
// will show, and a prediction that disagrees with the counter is worse than no
// prediction at all.
//
// Returns 0 on success, else the exit code the caller should die with.
func sequencePhase(info vi.AudioInfo, hz uint32) int {
	totalBytes, totalChunks, totalFrames := 0, 0, 0
	for i, note := range sequenceNotes {
		pcm := synthTone(info, NoteBlip(note.Hz, note.MS), hz)
		if pcm == nil {
			vi.ConsoleLine("fart: note " + vi.Itoa64(int64(i+sequenceStartNum)) + " refused")
			return 2
		}
		played, err := vi.AudioPlay(pcm)
		if err != nil {
			vi.ConsoleLine("fart: note " + vi.Itoa64(int64(i+sequenceStartNum)) +
				" play error " + err.Error() + " after " + vi.Itoa64(int64(played)) + " bytes")
			return 6
		}
		chunks := chunkCount(len(pcm))
		vi.ConsoleLine("fart: note " + vi.Itoa64(int64(i+sequenceStartNum)) +
			" f=" + vi.Itoa64(int64(note.Hz)) +
			" dur=" + vi.Itoa64(int64(note.MS)) +
			" chunks=" + vi.Itoa64(int64(chunks)) +
			" played=" + vi.Itoa64(int64(played)) +
			" hash=" + vi.Itoa64(int64(digest(pcm))))
		if played != len(pcm) {
			vi.ConsoleLine("fart: note " + vi.Itoa64(int64(i+sequenceStartNum)) +
				" short " + vi.Itoa64(int64(played)) + " of " + vi.Itoa64(int64(len(pcm))))
			return 6
		}
		totalBytes += played
		totalChunks += chunks
		totalFrames += int(framesFor(note.MS, hz))
	}

	vi.ConsoleLine("fart: seq notes=" + vi.Itoa64(int64(len(sequenceNotes))) +
		" frames=" + vi.Itoa64(int64(totalFrames)) +
		" bytes=" + vi.Itoa64(int64(totalBytes)) +
		" played=" + vi.Itoa64(int64(totalBytes)) +
		" chunks=" + vi.Itoa64(int64(totalChunks)))
	return 0
}

// noDevice is the soundless-VM path: the default VM has no `--sound` device,
// so slot 42 succeeded with ready=0 and the honest refusal comes from slot 43
// as ENXIO. That is a documented outcome, not a failure — the app reports
// exactly what the kernel said and exits 0. It probes slot 43 rather than
// assuming the refusal, so the marker is the kernel's answer, not ours.
func noDevice() {
	n, err := vi.AudioPlay(make([]byte, vi.AudioPeriodBytes))
	switch {
	case err == vi.ErrNoAudioDevice:
		vi.ConsoleLine("fart: no audio device (ENXIO); soundless VM, nothing to fart")
		vi.ConsoleLine(markerDone)
		vi.Exit(0)
	case err != nil:
		vi.ConsoleLine("fart: no audio device, play error " + err.Error())
		vi.Exit(1)
	}
	// ready=0 and the play SUCCEEDED anyway: say so instead of pretending.
	vi.ConsoleLine("fart: ready=0 but played " + vi.Itoa64(int64(n)) + " bytes")
	vi.Exit(3)
}
