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

	vi.ConsoleLine(markerDone)
	vi.Exit(0)
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
