package vi

import "unsafe"

// M58e (issue #1328): the EL0 audio seam — ADR 0007 slots 42/43, the Go half
// of what user/src/jingle.zig and user/src/chime.zig do in Zig. The kernel
// side has been frozen since M15; this file adds no syscall, it marshals.
//
// AudioInfo is slot 42's out struct: 16 bytes, little-endian, the kernel's
// field order and widths (kernel/src/virtio_snd.zig `AudioInfo`, mirrored by
// tests/virelai.h struct v_audio_info and docs/wasm-import-contract.md §5.3):
//
//	 0  ready        u32  transport + stream armed (0 = no device, not negotiated)
//	 4  format       u8   negotiated FMT_* (AudioFmtNone when there is no device)
//	 5  rate         u8   negotiated RATE_*
//	 6  channels     u8
//	 7  padding      u8
//	 8  period_bytes u32  the TX period the kernel submits (4096 on the device VZ reports)
//	12  max_len      u32  the slot-43 length bound (64 KiB)
//
// 16 bytes, not 24: the M15 card text said "24-byte AudioInfo", ADR 0007's
// slot-42 row and the kernel handler's comment both copied that, but the
// struct has been 16 bytes since it landed (asserted there by @sizeOf and in
// the frozen WAT contract). The stale comments are corrected with this card.
// TestAudioInfoWireSize pins the layout, because a struct that claims 24 bytes
// here would marshal 8 bytes of whatever follows the kernel's copy_out.
//
// A soundless VM (the default VM, no `--sound`) is NOT an error at slot 42:
// the kernel runs its first-call probe, fails to negotiate, and reports
// ready=0 with format/rate = 0xff. Slot 43 is where the honest refusal
// surfaces — ENXIO, the typed ErrNoAudioDevice — and that is what an app
// reports ("documented, not a failure" in the card's words).

// AudioInfo is the 16-byte negotiated playback state (slot 42's out struct).
type AudioInfo struct {
	Ready       uint32 // transport + stream armed
	Format      uint8  // negotiated FMT_*; AudioFmtNone when there is no device
	Rate        uint8  // negotiated RATE_*
	Channels    uint8  //
	Padding     uint8  // wire padding (the kernel writes 0)
	PeriodBytes uint32 // the TX period sys_audio_play submits at once
	MaxLen      uint32 // the sys_audio_play length bound (AudioMaxLen)
}

// virtio-snd PCM format codes the kernel negotiates (FMT_*,
// kernel/src/virtio_snd.zig). The device VZ reports advertises S16|S32|FLOAT
// and negotiates FLOAT; an app must synthesize in whatever came back.
const (
	AudioFmtS16   uint8 = 5
	AudioFmtS32   uint8 = 17
	AudioFmtFloat uint8 = 19
	AudioFmtNone  uint8 = 0xff // the kernel's "nothing negotiated" sentinel
)

// The slot-43 geometry: one device period per syscall, and the kernel's own
// per-call bound. AudioPeriodBytes ≤ AudioMaxLen by construction, so splitting
// at the period can never trip the bound.
const (
	AudioPeriodBytes = 4096      // virtio_snd.beep_period_bytes (AudioInfo.PeriodBytes)
	AudioMaxLen      = 64 * 1024 // virtio_snd.audio_max_len
)

// ErrNoAudioDevice is the kernel's ENXIO: no sound device is attached (the
// default VM without `--sound`), or the device refused a submission. Slot 42
// cannot report it (a soundless device is a successful call with Ready == 0);
// slot 43 is where it arrives. Compare with == or errors.Is.
var ErrNoAudioDevice = errno(ErrENXIO)

// AudioQuery reads the device's negotiated playback state (slot 42).
//
// The FIRST call drives the kernel's probe + SET_PARAMS negotiation, so after
// it returns an app knows exactly what to synthesize (format/frame and rate);
// later calls report the cached state. A soundless VM still succeeds, with
// Ready == 0 and Format == AudioFmtNone — the absence of a device is not an
// error here, it is what the state says. Off the guest, or for a kernel
// refusal (EINVAL for a non-process caller), the error is the kernel's code.
func AudioQuery() (AudioInfo, error) {
	var out AudioInfo
	r := syscall1(SlotAudioInfo, uintptr(unsafe.Pointer(&out)))
	if r < 0 {
		return AudioInfo{}, errno(-r)
	}
	return out, nil
}

// AudioPlay plays pcm — format, rate and channels exactly as AudioQuery
// reported them — through slot 43, and returns the total bytes the kernel
// confirmed played.
//
// The buffer is submitted in AudioPeriodBytes pieces, one device period per
// syscall. Two things fall out of that, both load-bearing: no single call can
// exceed the kernel's AudioMaxLen bound (so a buffer of ANY length is legal —
// a 200 KiB blip is 52 legal 4 KiB calls, and the unchunked call would have
// been refused with ENAMETOOLONG), and the accounting is per period, so a
// failure names how much sound was already confirmed. Chunking allocates
// nothing: the chunks are sub-slices of pcm.
//
// A mid-buffer failure returns the bytes confirmed so far alongside the error,
// so a caller can never over-claim what played. A submission the kernel
// answers with FEWER bytes than it was handed is a device-level refusal
// (ErrNoAudioDevice), not data loss to ignore. An empty buffer is a no-op:
// (0, nil) — the kernel's own EINVAL for a zero length never fires.
func AudioPlay(pcm []byte) (int, error) {
	return audioChunks(len(pcm), func(off, end int) (int, error) {
		return audioPlayPeriod(pcm[off:end])
	})
}

// audioPlayPeriod is one slot-43 call for one period-sized chunk. len(chunk)
// is always ≥ 1: the chunker never calls it for an empty range.
func audioPlayPeriod(chunk []byte) (int, error) {
	r := syscall2(SlotAudioPlay, uintptr(unsafe.Pointer(&chunk[0])), uintptr(len(chunk)))
	if r < 0 {
		return 0, errno(-r)
	}
	if int(r) != len(chunk) {
		return int(r), ErrNoAudioDevice
	}
	return int(r), nil
}

// audioChunks splits n bytes into AudioPeriodBytes-sized [off,end) ranges and
// calls f for each. It is the AudioPlay loop as a pure function — no syscall,
// no allocation — so the host suite can pin the arithmetic the live gate's
// syscall count reflects. Returns the summed byte count and f's first error.
func audioChunks(n int, f func(off, end int) (int, error)) (int, error) {
	total := 0
	for off := 0; off < n; off += AudioPeriodBytes {
		end := off + AudioPeriodBytes
		if end > n {
			end = n
		}
		got, err := f(off, end)
		total += got
		if err != nil {
			return total, err
		}
	}
	return total, nil
}
