package vi

import (
	"testing"
	"unsafe"
)

// The AudioInfo wire layout is the kernel's (kernel/src/virtio_snd.zig,
// 16 bytes). A struct with the wrong size here does not fail loudly on the
// guest — slot 42 copies exactly @sizeOf(AudioInfo) bytes out, so a 24-byte
// Go struct would read 8 bytes of whatever follows, silently. Hence the pin.
func TestAudioInfoWireSize(t *testing.T) {
	if got := unsafe.Sizeof(AudioInfo{}); got != 16 {
		t.Fatalf("AudioInfo size = %d want 16", got)
	}
	offsets := []struct {
		name string
		got  uintptr
		want uintptr
	}{
		{"Ready", unsafe.Offsetof(AudioInfo{}.Ready), 0},
		{"Format", unsafe.Offsetof(AudioInfo{}.Format), 4},
		{"Rate", unsafe.Offsetof(AudioInfo{}.Rate), 5},
		{"Channels", unsafe.Offsetof(AudioInfo{}.Channels), 6},
		{"Padding", unsafe.Offsetof(AudioInfo{}.Padding), 7},
		{"PeriodBytes", unsafe.Offsetof(AudioInfo{}.PeriodBytes), 8},
		{"MaxLen", unsafe.Offsetof(AudioInfo{}.MaxLen), 12},
	}
	for _, o := range offsets {
		if o.got != o.want {
			t.Fatalf("AudioInfo.%s offset = %d want %d", o.name, o.got, o.want)
		}
	}
}

// The negotiated codes are virtio-snd's, not ours: an app that synthesizes
// the wrong format code plays noise. (The device VZ reports advertises
// S16|S32|FLOAT @ 48|96 kHz and negotiates FLOAT/48000/stereo.)
func TestAudioFormatCodes(t *testing.T) {
	if AudioFmtS16 != 5 || AudioFmtS32 != 17 || AudioFmtFloat != 19 || AudioFmtNone != 0xff {
		t.Fatalf("format codes drifted: S16=%d S32=%d FLOAT=%d none=%d",
			AudioFmtS16, AudioFmtS32, AudioFmtFloat, AudioFmtNone)
	}
}

// The chunk geometry must stay inside the kernel's own bound, or the
// chunker cannot make an over-bound buffer legal (the whole reason it exists).
func TestAudioGeometry(t *testing.T) {
	if AudioPeriodBytes != 4096 {
		t.Fatalf("AudioPeriodBytes = %d want 4096 (virtio_snd.beep_period_bytes)", AudioPeriodBytes)
	}
	if AudioMaxLen != 64*1024 {
		t.Fatalf("AudioMaxLen = %d want 65536 (virtio_snd.audio_max_len)", AudioMaxLen)
	}
	if AudioPeriodBytes > AudioMaxLen {
		t.Fatalf("period %d exceeds the per-call bound %d: chunking could never legalize a big buffer",
			AudioPeriodBytes, AudioMaxLen)
	}
}

// ErrNoAudioDevice is the kernel's ENXIO as a typed value — the app branches on
// it to tell "this VM has no sound device" (documented, not a failure) from a
// real error, and it is unexported errno on purpose.
func TestAudioErrNoAudioDevice(t *testing.T) {
	if ErrNoAudioDevice != errno(ErrENXIO) {
		t.Fatalf("ErrNoAudioDevice = %v want errno(ENXIO)", ErrNoAudioDevice)
	}
	if got := ErrNoAudioDevice.Error(); got != "ENXIO" {
		t.Fatalf("ErrNoAudioDevice.Error() = %q want \"ENXIO\"", got)
	}
}

// Host: every syscall is -ENOSYS, and the wrapper must degrade without
// touching the out struct or panicking.
func TestAudioHostFails(t *testing.T) {
	info, err := AudioQuery()
	if err != errno(ErrENOSYS) {
		t.Fatalf("host AudioQuery err = %v want ENOSYS", err)
	}
	if info != (AudioInfo{}) {
		t.Fatalf("host AudioQuery filled the struct on failure: %+v", info)
	}
	n, err := AudioPlay(make([]byte, AudioPeriodBytes))
	if n != 0 || err != errno(ErrENOSYS) {
		t.Fatalf("host AudioPlay = %d, %v want 0, ENOSYS", n, err)
	}
}

// An empty buffer is a no-op, not a syscall: the kernel refuses len == 0 with
// EINVAL, and a caller that hands us nothing should not see an error for it.
func TestAudioPlayEmptyIsNoop(t *testing.T) {
	for _, pcm := range [][]byte{nil, {}} {
		n, err := AudioPlay(pcm)
		if n != 0 || err != nil {
			t.Fatalf("AudioPlay(empty) = %d, %v want 0, nil", n, err)
		}
	}
}

// The chunker is the pure half of AudioPlay, so its arithmetic is pinned here
// — the live go-fart gate's `43 sys_audio_play calls=52` is this loop's output.
func TestAudioChunkArithmetic(t *testing.T) {
	cases := []struct {
		name  string
		n     int
		calls int
	}{
		{"empty", 0, 0},
		{"one byte", 1, 1},
		{"exactly one period", AudioPeriodBytes, 1},
		{"one byte over", AudioPeriodBytes + 1, 2},
		// FART.ELF's blip: 550 ms at 48 kHz stereo FLOAT. It is deliberately
		// larger than AudioMaxLen — one unchunked call would be ENAMETOOLONG.
		{"the fart blip", 26400 * 8, 52},
	}
	for _, c := range cases {
		calls, widest, sum := 0, 0, 0
		got, err := audioChunks(c.n, func(off, end int) (int, error) {
			if end <= off || end > c.n {
				t.Fatalf("%s: bad chunk [%d,%d) of %d", c.name, off, end, c.n)
			}
			calls++
			if end-off > widest {
				widest = end - off
			}
			sum += end - off
			return end - off, nil
		})
		if err != nil {
			t.Fatalf("%s: unexpected error %v", c.name, err)
		}
		if calls != c.calls {
			t.Fatalf("%s: %d calls want %d", c.name, calls, c.calls)
		}
		if widest > AudioPeriodBytes {
			t.Fatalf("%s: widest chunk %d exceeds the period %d", c.name, widest, AudioPeriodBytes)
		}
		if widest > AudioMaxLen {
			t.Fatalf("%s: widest chunk %d exceeds the kernel bound %d", c.name, widest, AudioMaxLen)
		}
		if sum != c.n || got != c.n {
			t.Fatalf("%s: covered %d / returned %d want %d", c.name, sum, got, c.n)
		}
	}
}

// A failure part-way through must report exactly the bytes already confirmed —
// never the whole buffer, never zero. This is what lets an app's marker
// (`played=`) be trusted.
func TestAudioChunkPartialOnError(t *testing.T) {
	const n = AudioPeriodBytes*3 + 17
	failAt := 2
	calls := 0
	got, err := audioChunks(n, func(off, end int) (int, error) {
		if calls == failAt {
			return 0, ErrNoAudioDevice
		}
		calls++
		return end - off, nil
	})
	if err != ErrNoAudioDevice {
		t.Fatalf("err = %v want ENXIO", err)
	}
	if calls != failAt {
		t.Fatalf("calls after failure = %d want %d (must stop at the first error)", calls, failAt)
	}
	if want := AudioPeriodBytes * failAt; got != want {
		t.Fatalf("confirmed = %d want %d (only the drained periods)", got, want)
	}
}

// The four audio rows are ADR 0007 slots 42-45, i.e. the kernel's numbering.
// A binding that called the wrong row looks identical on the host (every raw
// call is -ENOSYS there) and only misbehaves on the guest, so the numbers are
// pinned rather than trusted — the same argument as TestAudioInfoWireSize.
func TestAudioSlotNumbers(t *testing.T) {
	rows := []struct {
		name string
		got  uintptr
		want uintptr
	}{
		{"SlotAudioInfo", SlotAudioInfo, 42},
		{"SlotAudioPlay", SlotAudioPlay, 43},
		{"SlotAudioVolume", SlotAudioVolume, 44},
		{"SlotAudioMute", SlotAudioMute, 45},
	}
	for _, r := range rows {
		if r.got != r.want {
			t.Fatalf("%s = %d want %d", r.name, r.got, r.want)
		}
	}
	if AudioVolumeMax != 100 {
		t.Fatalf("AudioVolumeMax = %d want 100 (slot 44's bound, ADR 0007 row 44)", AudioVolumeMax)
	}
}

// AudioVolume must SEND the caller's value unchanged, even when it is out of
// range. The kernel's EINVAL is the documented answer ("honest refusal, no
// silent clamping"); a clamp here would turn a caller's bug into silent
// success, and this is the only place that property is observable without a
// device — the audio rows route through the hookable gateway, so the fake
// kernel below sees the actual argument.
func TestAudioVolumeNoClamp(t *testing.T) {
	var gotNum, gotArg uintptr
	calls := 0
	prev := SetSyscallHookForTest(func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
		calls++
		gotNum, gotArg = num, a0
		return -ErrEINVAL // what the kernel answers for vol > AudioVolumeMax
	})
	defer SetSyscallHookForTest(prev)

	n, err := AudioVolume(AudioVolumeMax + 1)
	if calls != 1 {
		t.Fatalf("slot 44 called %d times want 1", calls)
	}
	if gotNum != SlotAudioVolume {
		t.Fatalf("called slot %d want %d", gotNum, SlotAudioVolume)
	}
	if gotArg != AudioVolumeMax+1 {
		t.Fatalf("AudioVolume sent %d want %d unchanged: clamping would hide the kernel's EINVAL",
			gotArg, AudioVolumeMax+1)
	}
	if n != 0 || err != errno(ErrEINVAL) {
		t.Fatalf("AudioVolume(over) = %d, %v want 0, EINVAL", n, err)
	}
}

// The in-range path sends the number it was given and returns the KERNEL's
// answer. Those are two different properties, and the second is the one worth
// proving: the app's marker prints this value, so a binding that restated its
// own argument would make every `echo=` in the gate a tautology.
func TestAudioVolumeEcho(t *testing.T) {
	var gotArg uintptr

	// The ordinary case: the kernel echoes what it accepted.
	prev := SetSyscallHookForTest(func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
		gotArg = a0
		return 40
	})
	n, err := AudioVolume(40)
	SetSyscallHookForTest(prev)
	if err != nil {
		t.Fatalf("AudioVolume(40) err = %v want nil", err)
	}
	if gotArg != 40 {
		t.Fatalf("slot 44 arg = %d want 40", gotArg)
	}
	if n != 40 {
		t.Fatalf("AudioVolume(40) = %d want the kernel's echo 40", n)
	}

	// And the one that separates the two: a kernel answer that is NOT the
	// argument. (7 is absurd as a volume and is not supposed to be plausible --
	// the property under test is that the value came back from the syscall at
	// all. A binding returning its own argument passes the case above and fails
	// here, which is exactly the mutation a marker-based gate cannot see.)
	prev = SetSyscallHookForTest(func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
		gotArg = a0
		return 7
	})
	n, err = AudioVolume(60)
	SetSyscallHookForTest(prev)
	if err != nil {
		t.Fatalf("AudioVolume(60) err = %v want nil", err)
	}
	if gotArg != 60 {
		t.Fatalf("slot 44 arg = %d want 60 (passed through unchanged)", gotArg)
	}
	if n != 7 {
		t.Fatalf("AudioVolume(60) = %d want the kernel's 7: the return value is not being taken from the syscall", n)
	}

	// The bound itself is in range: AudioVolumeMax is a legal volume, not an
	// error, and pinning that keeps an off-by-one out of the app's arithmetic.
	prev = SetSyscallHookForTest(func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
		return int64(a0)
	})
	defer SetSyscallHookForTest(prev)
	if got, err := AudioVolume(AudioVolumeMax); err != nil || got != AudioVolumeMax {
		t.Fatalf("AudioVolume(AudioVolumeMax) = %d, %v want %d, nil", got, err, AudioVolumeMax)
	}
}

// A negative volume is out of range by construction. It is passed through as
// its two's-complement value — which the kernel refuses as out-of-range —
// rather than being rejected, clamped or silently converted here: one refusal
// path, in the kernel, is easier to reason about than two.
func TestAudioVolumeNegativePassedThrough(t *testing.T) {
	var gotArg uintptr
	prev := SetSyscallHookForTest(func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
		gotArg = a0
		return -ErrEINVAL
	})
	defer SetSyscallHookForTest(prev)

	if _, err := AudioVolume(-1); err != errno(ErrEINVAL) {
		t.Fatalf("AudioVolume(-1) err = %v want EINVAL", err)
	}
	if gotArg != ^uintptr(0) {
		t.Fatalf("AudioVolume(-1) sent %#x want the two's-complement value %#x", gotArg, ^uintptr(0))
	}
}

// AudioMute marshals exactly 1/0 — never another int — and surfaces the
// kernel's refusal. Nothing else about a bool needs proving; the point is that
// the wire carries the kernel's two states and no third.
func TestAudioMuteMapping(t *testing.T) {
	cases := []struct {
		name string
		arg  bool
		want uintptr
	}{
		{"muted", true, 1},
		{"unmuted", false, 0},
	}
	for _, c := range cases {
		// A subtest per case so the hook is restored by defer even when an
		// assertion fails: an inline restore leaks the fake kernel into every
		// later case in the file, which turns one failure into a confusing
		// cascade.
		t.Run(c.name, func(t *testing.T) {
			var gotNum, gotArg uintptr
			calls := 0
			prev := SetSyscallHookForTest(func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
				calls++
				gotNum, gotArg = num, a0
				return 0 // slot 45 returns 0 on success
			})
			defer SetSyscallHookForTest(prev)

			if err := AudioMute(c.arg); err != nil {
				t.Fatalf("AudioMute err = %v want nil", err)
			}
			if calls != 1 || gotNum != SlotAudioMute {
				t.Fatalf("called slot %d %d times want %d once", gotNum, calls, SlotAudioMute)
			}
			if gotArg != c.want {
				t.Fatalf("slot 45 arg = %d want %d", gotArg, c.want)
			}
		})
	}

	prev := SetSyscallHookForTest(func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
		return -ErrEINVAL
	})
	defer SetSyscallHookForTest(prev)
	if err := AudioMute(true); err != errno(ErrEINVAL) {
		t.Fatalf("refused AudioMute err = %v want EINVAL", err)
	}
}

// Host: the two new rows degrade exactly like the rest of the seam (no hook,
// so the raw gateway answers -ENOSYS) — an app that runs the host suite must
// not see a panic or a fabricated success.
func TestAudioVolumeMuteHostFails(t *testing.T) {
	if n, err := AudioVolume(50); n != 0 || err != errno(ErrENOSYS) {
		t.Fatalf("host AudioVolume = %d, %v want 0, ENOSYS", n, err)
	}
	if err := AudioMute(true); err != errno(ErrENOSYS) {
		t.Fatalf("host AudioMute = %v want ENOSYS", err)
	}
}
