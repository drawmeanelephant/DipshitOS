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
