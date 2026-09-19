package main

// FART.ELF's synthesis (M58f, issue #1327): one descending fart blip, built
// with nothing but elementary arithmetic.
//
// It lives here, not in main.go, so the host `go test` run can pin the exact
// shape the VZ gate then asserts on the guest: the frame/byte count, the
// chunk arithmetic and a digest of the PCM. The synthesis is deterministic on
// purpose — same input, same bytes — which is what makes a pinned digest a
// legitimate assertion instead of a coin flip.
//
// Deliberately dependency-free: no `math` (not ported to GOOS=virelai yet, and
// its sine would move the pinned digest on a toolchain bump), no `fmt`, no
// `strconv`. `unsafe` is used for one thing only — float32 bit patterns.

import (
	"unsafe"

	"virelai/vi"
)

// Blip is the physical parameter set of one fart.
//
// The default is a brap: a 190 -> 58 Hz LINEAR glide (the pitch drop; linear,
// not exponential, because an exponential sweep needs exp/log and the ear does
// not care at this length), a sputter that slows from 33 -> 18 Hz (the
// raspberry), a 12 ms attack, and a 90 ms release (the pfft). The harmonic
// stack at 1/h is what makes it a rasp rather than a sine; the deterministic
// noise is the air.
type Blip struct {
	MS           uint32
	StartHz      float64
	EndHz        float64
	SputterHz    float64
	SputterEndHz float64
	Depth        float64 // flutter depth, 0..1
	Noise        float64 // deterministic air, 0..1
	AttackMS     uint32
	ReleaseMS    uint32
	Amplitude    float64 // peak, 0..1 (headroom for the harmonic sum)
	Harmonics    int     // partials in the stack
}

// DefaultBlip is FART.ELF's single blip.
var DefaultBlip = Blip{
	MS:           550,
	StartHz:      190,
	EndHz:        58,
	SputterHz:    33,
	SputterEndHz: 18,
	Depth:        0.55,
	Noise:        0.10,
	AttackMS:     12,
	ReleaseMS:    90,
	Amplitude:    0.45,
	Harmonics:    6,
}

// NoteBlip is one note of the sequence (M70f2, issue #1476): the same
// synthesis with the fart switched off — no glide, no flutter, no air — so one
// Blip type covers both the rasp and a plain tone.
//
// Reusing synthBlip rather than growing a second oscillator is deliberate: the
// sequence then goes through the code path M58f's pinned digest already covers,
// so a note's digest means the same thing a blip's does ("exactly these
// samples"), and there is no second DSP implementation to audit.
func NoteBlip(hz float64, ms uint32) Blip {
	return Blip{
		MS:        ms,
		StartHz:   hz,
		EndHz:     hz, // no glide: this is a tone, not a raspberry
		Depth:     0,
		Noise:     0,
		AttackMS:  8,
		ReleaseMS: 40,
		Amplitude: 0.35, // headroom under the 1/h harmonic sum
		Harmonics: 3,
	}
}

// synthTone builds one note at the negotiated format: the buffer an app hands
// to sys_audio_play. It returns nil for a geometry the kernel cannot have
// negotiated or a rate with no Hz — the callers report that rather than
// submitting a buffer of zeros, which is what an ignored error would ship.
func synthTone(info vi.AudioInfo, b Blip, hz uint32) []byte {
	fb, ok := frameBytes(info.Format, info.Channels)
	if !ok || hz == 0 {
		return nil
	}
	pcm := make([]byte, int(framesFor(b.MS, hz)*fb))
	if !synthBlip(pcm, b, info.Format, info.Channels, hz) {
		return nil
	}
	return pcm
}

// rateHz maps a negotiated RATE_* code to Hz (0 = a code this app cannot
// synthesize). The numbering is the kernel's (kernel/src/virtio_snd.zig
// snd_rate_hz), the same table user/src/jingle.zig carries.
func rateHz(rate uint8) uint32 {
	switch rate {
	case 1:
		return 8000
	case 3:
		return 16000
	case 4:
		return 22050
	case 5:
		return 32000
	case 6:
		return 44100
	case 7:
		return 48000
	}
	return 0
}

// framesFor is the frame count of ms milliseconds at hz (at least one frame).
func framesFor(ms uint32, hz uint32) uint32 {
	f := uint64(hz) * uint64(ms) / 1000
	if f == 0 {
		return 1
	}
	return uint32(f)
}

// frameBytes is the size of one sample frame: bytes-per-sample * channels.
// ok is false for anything the kernel cannot have negotiated — the device VZ
// reports advertises S16|S32|FLOAT, so a caller that sees another code (or no
// channels) reports it instead of writing silence.
func frameBytes(format, channels uint8) (uint32, bool) {
	if channels == 0 {
		return 0, false
	}
	switch format {
	case vi.AudioFmtFloat, vi.AudioFmtS32:
		return 4 * uint32(channels), true
	case vi.AudioFmtS16:
		return 2 * uint32(channels), true
	}
	return 0, false
}

// chunkCount is how many slot-43 calls a buffer of n bytes takes at the
// vi.AudioPeriodBytes period — the app prints it so the gate can check the
// prediction against the kernel's own syscall counter.
func chunkCount(n int) int {
	if n <= 0 {
		return 0
	}
	return (n + vi.AudioPeriodBytes - 1) / vi.AudioPeriodBytes
}

// synthBlip writes b into dst, which must be exactly
// framesFor(b.MS, hz) * frameBytes(format, channels) bytes, in the negotiated
// format. Every channel carries the same sample: the blip is mono, and nothing
// about a fart wants a stereo image. It writes nothing and returns false when
// the dst geometry or the format is not one it can encode — an honest refusal
// rather than a buffer of zeros.
func synthBlip(dst []byte, b Blip, format, channels uint8, hz uint32) bool {
	fb, ok := frameBytes(format, channels)
	if !ok || hz == 0 {
		return false
	}
	frames := len(dst) / int(fb)
	if frames == 0 || len(dst) != frames*int(fb) {
		return false
	}

	dur := float64(frames) / float64(hz)
	sweep := b.EndHz - b.StartHz
	sputterSweep := b.SputterEndHz - b.SputterHz
	sampleBytes := int(fb / uint32(channels))
	// Harmonic normalisation: sum(1/h for h in 1..H) keeps the stacked partials
	// inside [-1, 1] so Amplitude is a real peak.
	harmSum := 0.0
	for h := 1; h <= b.Harmonics; h++ {
		harmSum += 1 / float64(h)
	}

	attack := int(float64(b.AttackMS) * float64(hz) / 1000)
	release := int(float64(b.ReleaseMS) * float64(hz) / 1000)
	if attack < 1 {
		attack = 1
	}
	if release < 1 {
		release = 1
	}

	// The air: a fixed-seed LCG. It is part of the sound, but it is also part
	// of the pinned digest, so it must never be seeded from the clock (the
	// guest's clock is the device's, and a random blip cannot be asserted).
	seed := uint32(0x46415254) // "FART"

	for i := 0; i < frames; i++ {
		u := float64(i) / float64(frames)

		// Envelope: attack ramp in, and a release that lands on near-silence
		// so the blip ends without a click.
		env := 1.0
		if i < attack {
			env = float64(i+1) / float64(attack)
		}
		if tail := float64(frames-i) / float64(release); tail < env {
			env = tail
		}

		seed = seed*1664525 + 1013904223
		noise := float64(int32(seed)) / 2147483648.0 // [-1, 1)

		// The raspberry: a pitch glide and an amplitude flutter whose own rate
		// slows down, so it sputters out instead of stopping. Both rates are
		// linear in u, so each phase below is the exact integral of that ramp
		// — integrating per frame instead would accumulate the error of 26 000
		// additions and let the pitch drift off the glide.
		glide := 2 * pi * dur * (b.StartHz*u + sweep*u*u/2)
		flutterPhase := 2 * pi * dur * (b.SputterHz*u + sputterSweep*u*u/2)
		flutter := 1 - b.Depth*(0.5+0.5*sinApprox(flutterPhase))

		harm := 0.0
		for h := 1; h <= b.Harmonics; h++ {
			harm += sinApprox(float64(h)*glide) / float64(h)
		}

		s := b.Amplitude * env * flutter * (harm/harmSum + b.Noise*noise)
		if s > 1 {
			s = 1
		} else if s < -1 {
			s = -1
		}

		off := i * int(fb)
		for c := 0; c < int(channels); c++ {
			at := off + c*sampleBytes
			switch format {
			case vi.AudioFmtFloat:
				putF32(dst[at:], float32(s))
			case vi.AudioFmtS16:
				putI16(dst[at:], int16(s*32767))
			case vi.AudioFmtS32:
				putI32(dst[at:], int32(s*2147483647))
			}
		}
	}
	return true
}

// digest is FNV-1a 32 over the PCM bytes. The gate pins its value: a length
// assertion alone cannot tell a synthesized blip from a buffer of zeros, and
// the digest is only stable because the synthesis above is.
func digest(b []byte) uint32 {
	h := uint32(2166136261)
	for _, c := range b {
		h ^= uint32(c)
		h *= 16777619
	}
	return h
}

// pi and twoPi are the full f64 constants; the app carries them so it needs no
// `math` import (see the file header).
const (
	pi    = 3.14159265358979323846264338327950288
	twoPi = 6.28318530717958647692528676655900577
)

// sinApprox is sin over the reals: reduce the argument to [-pi, pi], then a
// degree-15 odd Taylor series in Horner form (absolute error < 1e-6 on the
// reduced range, i.e. below -120 dB — and, unlike math.Sin, byte-stable across
// Go releases, which is what keeps the pinned digest meaningful).
func sinApprox(x float64) float64 {
	n := int64(x / twoPi)
	x -= float64(n) * twoPi
	if x > pi {
		x -= twoPi
	} else if x < -pi {
		x += twoPi
	}
	z := x * x
	// c0 + z(c1 + z(c2 + ... )), the x^(2k+1) coefficients of sin / x.
	p := -1.0 / 1307674368000.0 // x^15 (15!)
	p = 1.0/6227020800.0 + z*p  // x^13
	p = -1.0/39916800.0 + z*p   // x^11
	p = 1.0/362880.0 + z*p      // x^9
	p = -1.0/5040.0 + z*p       // x^7
	p = 1.0/120.0 + z*p         // x^5
	p = -1.0/6.0 + z*p          // x^3
	p = 1.0 + z*p               // x^1
	return x * p
}

// putF32 writes v's IEEE-754 bits little-endian. Little-endian on purpose even
// though the guest and the host are both LE: the digest is pinned across both,
// so the wire byte order must be the code's, not the machine's.
func putF32(b []byte, v float32) {
	putU32(b, *(*uint32)(unsafe.Pointer(&v)))
}

func putU32(b []byte, v uint32) {
	b[0] = byte(v)
	b[1] = byte(v >> 8)
	b[2] = byte(v >> 16)
	b[3] = byte(v >> 24)
}

func putI16(b []byte, v int16) {
	u := uint16(v)
	b[0] = byte(u)
	b[1] = byte(u >> 8)
}

func putI32(b []byte, v int32) {
	putU32(b, uint32(v))
}
