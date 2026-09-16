package main

import (
	"math"
	"testing"

	"virelai/vi"
)

// The VZ-observed negotiation (FLOAT / 48000 / stereo — the device the
// live-sound gates pin) and the numbers the go-fart gate asserts. If a
// parameter of DefaultBlip changes, these fail here rather than on the VM.
const (
	vzFormat   = vi.AudioFmtFloat
	vzRate     = uint8(7) // RATE_48000
	vzChannels = uint8(2)
	vzHz       = uint32(48000)
)

func vzPCM(t *testing.T) ([]byte, uint32, uint32) {
	t.Helper()
	fb, ok := frameBytes(vzFormat, vzChannels)
	if !ok {
		t.Fatal("FLOAT/stereo must be encodable")
	}
	frames := framesFor(DefaultBlip.MS, vzHz)
	pcm := make([]byte, int(frames*fb))
	if !synthBlip(pcm, DefaultBlip, vzFormat, vzChannels, vzHz) {
		t.Fatal("synthesis refused a valid geometry")
	}
	return pcm, frames, fb
}

// The gate's byte accounting: 550 ms at 48 kHz stereo FLOAT is 26 400 frames,
// 8 bytes each. Both halves matter — the marker prints both, and the blip has
// to stay over the kernel's 64 KiB per-call bound or the chunking proof
// evaporates.
func TestBlipGeometry(t *testing.T) {
	pcm, frames, fb := vzPCM(t)
	if frames != 26400 {
		t.Fatalf("frames = %d want 26400", frames)
	}
	if fb != 8 {
		t.Fatalf("frame bytes = %d want 8", fb)
	}
	if len(pcm) != 211200 {
		t.Fatalf("blip bytes = %d want 211200", len(pcm))
	}
	if len(pcm) <= vi.AudioMaxLen {
		t.Fatalf("blip %d bytes must exceed the %d-byte per-call bound, else one unchunked call would do",
			len(pcm), vi.AudioMaxLen)
	}
	if got := chunkCount(len(pcm)); got != 52 {
		t.Fatalf("chunkCount = %d want 52", got)
	}
}

// The digest the gate pins. It is what distinguishes a synthesized blip from a
// buffer of zeros — a length assertion cannot.
func TestBlipDigest(t *testing.T) {
	pcm, _, _ := vzPCM(t)
	got := digest(pcm)
	const want = uint32(4173224929) // 550 ms FLOAT/48 kHz/stereo
	if got != want {
		t.Fatalf("blip digest = %d want %d — if the synthesis changed on purpose, re-pin both this and the go-fart spec (%s)",
			got, want, "go test ./fart -run TestBlipDigest -v")
	}
}

// Deterministic on purpose: a digest is only a legitimate gate assertion if the
// synthesis cannot vary between runs (it must not touch the clock or the
// CSPRNG) and the noise cannot be seeded from anything else.
func TestBlipDeterministic(t *testing.T) {
	a, _, _ := vzPCM(t)
	b, _, _ := vzPCM(t)
	if digest(a) != digest(b) {
		t.Fatal("two synthesised blips differ: the synthesis is not deterministic")
	}
	zeros := make([]byte, len(a))
	if digest(a) == digest(zeros) {
		t.Fatal("the blip is all zeros")
	}
}

// The sound has to be audible and unclipped: a real envelope (silent ends, a
// loud middle) and no sample pinned at full scale.
func TestBlipEnvelope(t *testing.T) {
	pcm, frames, _ := vzPCM(t)
	n := int(frames)
	peak, quietEnds, pinned := 0.0, true, 0
	for i := 0; i < n; i++ {
		off := i * 8
		v := float32FromBits(uint32(pcm[off]) | uint32(pcm[off+1])<<8 | uint32(pcm[off+2])<<16 | uint32(pcm[off+3])<<24)
		a := math.Abs(float64(v))
		if a > peak {
			peak = a
		}
		if a >= 0.999 {
			pinned++
		}
		if i < 100 || i >= n-100 {
			if a > 0.25 {
				quietEnds = false
			}
		}
	}
	if peak < 0.1 {
		t.Fatalf("peak %.4f is inaudibly quiet", peak)
	}
	if !quietEnds {
		t.Fatal("the blip starts or ends loud: the envelope is wrong (it would click)")
	}
	if pinned > 0 {
		t.Fatalf("%d samples are clipped at full scale", pinned)
	}
}

// Both channels carry the same sample, and the frame stride is the format's.
func TestBlipChannelInterleave(t *testing.T) {
	pcm, frames, _ := vzPCM(t)
	for _, i := range []int{0, 1, int(frames) / 2, int(frames) - 1} {
		l := pcm[i*8 : i*8+4]
		r := pcm[i*8+4 : i*8+8]
		for k := 0; k < 4; k++ {
			if l[k] != r[k] {
				t.Fatalf("frame %d: channels differ at byte %d (%d vs %d)", i, k, l[k], r[k])
			}
		}
	}
}

// Every negotiated format the kernel can produce must encode, at the right
// stride and with the right total length; anything else refuses.
func TestFrameBytes(t *testing.T) {
	cases := []struct {
		format   uint8
		channels uint8
		want     uint32
		ok       bool
	}{
		{vi.AudioFmtFloat, 1, 4, true},
		{vi.AudioFmtFloat, 2, 8, true},
		{vi.AudioFmtS32, 2, 8, true},
		{vi.AudioFmtS16, 1, 2, true},
		{vi.AudioFmtS16, 2, 4, true},
		{vi.AudioFmtNone, 2, 0, false},
		{9, 2, 0, false},
		{vi.AudioFmtFloat, 0, 0, false},
	}
	for _, c := range cases {
		got, ok := frameBytes(c.format, c.channels)
		if got != c.want || ok != c.ok {
			t.Fatalf("frameBytes(%d, %d) = %d, %v want %d, %v", c.format, c.channels, got, ok, c.want, c.ok)
		}
	}
}

// The kernel's RATE_* numbering, 0 for anything it cannot have negotiated.
func TestRateHz(t *testing.T) {
	want := map[uint8]uint32{1: 8000, 3: 16000, 4: 22050, 5: 32000, 6: 44100, 7: 48000, 0: 0, 2: 0, 0xff: 0}
	for code, hz := range want {
		if got := rateHz(code); got != hz {
			t.Fatalf("rateHz(%d) = %d want %d", code, got, hz)
		}
	}
}

// A refusal must refuse: a dst that is not frames*frameBytes, or a format the
// kernel cannot have negotiated, writes nothing.
func TestSynthRefuses(t *testing.T) {
	for _, c := range []struct {
		name     string
		n        int
		format   uint8
		channels uint8
	}{
		{"empty", 0, vi.AudioFmtFloat, 2},
		{"short of a frame", 7, vi.AudioFmtFloat, 2},
		{"not a whole frame", 9, vi.AudioFmtFloat, 2},
		{"no format", 8, vi.AudioFmtNone, 2},
		{"no channels", 8, vi.AudioFmtFloat, 0},
	} {
		before := make([]byte, c.n)
		dst := make([]byte, c.n)
		if synthBlip(dst, DefaultBlip, c.format, c.channels, vzHz) {
			t.Fatalf("%s: accepted a geometry it cannot encode", c.name)
		}
		for i := range dst {
			if dst[i] != before[i] {
				t.Fatalf("%s: wrote to a refused buffer", c.name)
			}
		}
	}
	if synthBlip(make([]byte, 8), DefaultBlip, vi.AudioFmtFloat, 2, 0) {
		t.Fatal("accepted rate 0 with no Hz to synthesize at")
	}
}

// The whole point of the chunk arithmetic: nothing above the period, everything
// covered, and the boundary cases exact.
func TestChunkCount(t *testing.T) {
	cases := []struct{ n, want int }{
		{0, 0}, {-1, 0}, {1, 1}, {vi.AudioPeriodBytes, 1},
		{vi.AudioPeriodBytes + 1, 2}, {vi.AudioMaxLen, 16}, {vi.AudioMaxLen + 1, 17},
		{211200, 52},
	}
	for _, c := range cases {
		if got := chunkCount(c.n); got != c.want {
			t.Fatalf("chunkCount(%d) = %d want %d", c.n, got, c.want)
		}
	}
}

// sinApprox is the app's own sine, so its accuracy is the app's problem. One
// term of headroom on the reduced range keeps it far below audibility.
func TestSinApproxAccuracy(t *testing.T) {
	worst := 0.0
	for i := -2000; i <= 2000; i++ {
		x := float64(i) / 100.0 * math.Pi
		d := math.Abs(sinApprox(x) - math.Sin(x))
		if d > worst {
			worst = d
		}
	}
	if worst > 1e-6 {
		t.Fatalf("sinApprox worst error %.3e exceeds 1e-6", worst)
	}
	// A phase far past one period (the blip reaches ~650 rad) must still land.
	if d := math.Abs(sinApprox(656.1) - math.Sin(656.1)); d > 1e-6 {
		t.Fatalf("sinApprox(656.1) off by %.3e", d)
	}
	if got := sinApprox(0); got != 0 {
		t.Fatalf("sinApprox(0) = %v", got)
	}
}

// The S16/S32 paths have to produce real samples too — the app must work
// whatever the device negotiated, not only on the device VZ happens to report.
func TestSynthOtherFormats(t *testing.T) {
	for _, c := range []struct {
		format   uint8
		channels uint8
		fb       uint32
	}{
		{vi.AudioFmtS16, 1, 2},
		{vi.AudioFmtS16, 2, 4},
		{vi.AudioFmtS32, 2, 8},
		{vi.AudioFmtFloat, 1, 4},
	} {
		frames := framesFor(DefaultBlip.MS, vzHz)
		pcm := make([]byte, int(frames*c.fb))
		if !synthBlip(pcm, DefaultBlip, c.format, c.channels, vzHz) {
			t.Fatalf("fmt %d ch %d: refused", c.format, c.channels)
		}
		if digest(pcm) == digest(make([]byte, len(pcm))) {
			t.Fatalf("fmt %d ch %d: all zeros", c.format, c.channels)
		}
	}
}

func float32FromBits(bits uint32) float32 {
	return math.Float32frombits(bits)
}

// mono decodes the encoded blip back to f64 samples (channel 0 of each frame),
// so the tests below can measure the SOUND rather than the byte count. A blip
// of the right length that is a constant tone would pass every length test and
// still not be a fart.
func mono(pcm []byte, frames int) []float64 {
	x := make([]float64, frames)
	for i := 0; i < frames; i++ {
		off := i * 8
		bits := uint32(pcm[off]) | uint32(pcm[off+1])<<8 | uint32(pcm[off+2])<<16 | uint32(pcm[off+3])<<24
		x[i] = float64(float32FromBits(bits))
	}
	return x
}

// pitchHz estimates the fundamental of x[from:from+win] by normalised
// autocorrelation over lags [minLag, maxLag], taking the FIRST lag that is
// within 15% of the best — the smallest period, so a harmonic cannot pull the
// estimate down an octave.
//
// Two details are load-bearing, both found by running it: the denominator is the
// WHOLE window's energy, held fixed across lags (dividing by each lag's own
// overlap inflates long lags and reports a third of the real pitch), and minLag
// starts past the autocorrelation's first zero crossing (a smooth signal is
// ~0.99 correlated with itself a few samples later, which would read as an
// absurdly high pitch). 150 samples is past the half period of the glide's
// highest note (190 Hz: 252 samples per period).
func pitchHz(x []float64, from, win, minLag, maxLag int, hz uint32) float64 {
	den := 0.0
	for i := from; i < from+win; i++ {
		den += x[i] * x[i]
	}
	if den == 0 {
		return 0
	}
	r := make([]float64, maxLag+2)
	best, bestLag := 0.0, 0
	for lag := minLag; lag <= maxLag && from+lag < from+win; lag++ {
		num := 0.0
		for i := from; i+lag < from+win; i++ {
			num += x[i] * x[i+lag]
		}
		r[lag] = num / den
		if r[lag] > best {
			best, bestLag = r[lag], lag
		}
	}
	if bestLag == 0 {
		return 0
	}
	for lag := minLag + 1; lag < bestLag; lag++ {
		if r[lag] > r[lag-1] && r[lag] >= r[lag+1] && r[lag] >= 0.85*best {
			return float64(hz) / float64(lag)
		}
	}
	return float64(hz) / float64(bestLag)
}

// The sound: the pitch has to FALL. Measuring it on the encoded samples is the
// only way to assert "descending" without a speaker — the parameter says 190
// -> 58 Hz, and this checks the samples agree with the parameter.
func TestBlipPitchDescends(t *testing.T) {
	pcm, frames, _ := vzPCM(t)
	x := mono(pcm, int(frames))

	// 40 ms windows stepping across the glide's body. The scan stops at 400 ms
	// of 550: the last 90 ms is the release, where there is too little energy
	// left for any pitch estimate to mean anything.
	win := int(vzHz) * 40 / 1000
	var pitches []float64
	for from := win; from+win < 400*int(vzHz)/1000; from += win {
		pitches = append(pitches, pitchHz(x, from, win, 150, 1000, vzHz))
	}
	if len(pitches) < 4 {
		t.Fatalf("only %d windows measured", len(pitches))
	}
	t.Logf("pitch over the blip: %.0f -> %.0f Hz (%v)", pitches[0], pitches[len(pitches)-1], pitches)
	for i := 1; i < len(pitches); i++ {
		if pitches[i] > pitches[i-1]*1.05 {
			t.Fatalf("pitch rises at window %d: %.1f -> %.1f Hz (%v)", i, pitches[i-1], pitches[i], pitches)
		}
	}
	first, last := pitches[0], pitches[len(pitches)-1]
	if first < 160 || first > 200 {
		t.Fatalf("starts at %.1f Hz, want the 190 Hz end of the glide", first)
	}
	if last > 125 {
		t.Fatalf("still %.1f Hz at 400 ms, want a drop well toward the 58 Hz end", last)
	}
	if first < 1.4*last {
		t.Fatalf("pitch falls only %.0f -> %.0f Hz: that is not a descent", first, last)
	}
}

// ...and it has to SPUTTER: the flutter is amplitude modulation of a few tens
// of Hz, and the point of it is that a steady tone sounds like a foghorn while
// a modulated one sounds like a raspberry.
func TestBlipFlutter(t *testing.T) {
	pcm, frames, _ := vzPCM(t)
	x := mono(pcm, int(frames))

	// Envelope in 1 ms steps over the first 250 ms: RMS over 12 ms is wide
	// enough to average the harmonic stack away and narrow enough to resolve a
	// 30 ms flutter cycle. (Both halves matter — a 6 ms window leaves ~380 Hz
	// ripple that a peak counter happily reads as "flutter".)
	const spanMS = 250
	bin := int(vzHz) / 1000
	w := 12 * bin
	var env []float64
	for start := 0; start+w < spanMS*bin; start += bin {
		sum := 0.0
		for i := start; i < start+w; i++ {
			sum += x[i] * x[i]
		}
		env = append(env, math.Sqrt(sum/float64(w)))
	}
	lo, hi := math.Inf(1), 0.0
	for _, e := range env {
		if e < lo {
			lo = e
		}
		if e > hi {
			hi = e
		}
	}
	if hi == 0 {
		t.Fatal("silent envelope")
	}
	depth := (hi - lo) / hi

	// Peaks, with a 20 ms refractory so ripple cannot count twice (the flutter
	// period is 30 ms at the start of the blip and 55 ms at the end).
	peaks, last := 0, -100
	for i := 1; i < len(env)-1; i++ {
		if env[i] > env[i-1] && env[i] >= env[i+1] && i-last >= 20 {
			peaks++
			last = i
		}
	}
	t.Logf("flutter: %d envelope peaks in %d ms, depth %.2f", peaks, spanMS, depth)
	// 33 Hz slowing to ~26 Hz over 250 ms is 7-8 cycles; 5..12 leaves room for
	// where the peaks land without accepting a foghorn (1-2) or noise (>12).
	if peaks < 5 || peaks > 12 {
		t.Fatalf("%d flutter peaks in %d ms, want 5..12 (a ~30 Hz raspberry)", peaks, spanMS)
	}
	if depth < 0.4 {
		t.Fatalf("flutter depth %.2f: the blip is barely modulated (a foghorn, not a rasp)", depth)
	}
}

// The air layer is a layer: turning Noise off must change the samples, and the
// default has to stay a subtle floor rather than a noise record.
func TestBlipAir(t *testing.T) {
	loud, _, _ := vzPCM(t)
	b := DefaultBlip
	b.Noise = 0
	quiet := make([]byte, len(loud))
	if !synthBlip(quiet, b, vzFormat, vzChannels, vzHz) {
		t.Fatal("synthesis refused")
	}
	if digest(loud) == digest(quiet) {
		t.Fatal("Noise does not reach the samples: the air layer is dead code")
	}
	if DefaultBlip.Noise <= 0 || DefaultBlip.Noise > 0.25 {
		t.Fatalf("default noise floor %.3f is not a subtle air layer", DefaultBlip.Noise)
	}
}
