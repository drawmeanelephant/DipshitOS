package vi

// M57a (issue #1313): the WM-SEAT half of the slot-65 seam.
//
// wmclient.go is the tab-CLIENT half: an app asks the registered WM over the
// mailbox and never touches slot 65. A window manager is the SERVER: it is the
// process the kernel accepts as the render-server seat (slot 65 cmd 1
// REGISTER) and the one that drives the composite cadence with
// REQUEST_PRESENT (cmd 3), once per kind-18 COMPOSITE_TICK the kernel delivers
// to the seat. This file is that server-side surface — deliberately tiny, the
// mirror of wmclient.go, and host-safe: every call degrades to -ENOSYS off the
// guest, exactly like the rest of the SDK.

const (
	// SlotWmctl is the render-server control slot (ADR 0015 seam A, frozen
	// by WMS1 in the ADR 0007 amendment).
	SlotWmctl uintptr = 65
	// WmctlRegisterCmd is slot-65 subcommand 1: accept the CALLER as the
	// active compositor (one seat; a second registration is refused EACCES).
	WmctlRegisterCmd uint64 = 1
	// WmctlRequestPresentCmd is slot-65 subcommand 3: transfer+flush the
	// scanout now and advance the kernel's present sequence/count.
	WmctlRequestPresentCmd uint64 = 3

	// M33MapShared is the frozen seam-B flag (ADR 0016, bit 16 of the mmap
	// flags word): a shared-anonymous mapping. The scanout bind is one.
	M33MapShared uint64 = 0x10000
	// M33ScanoutTag is the mmap `addr` tag that asks the kernel for the
	// REGISTERED WM's WRITABLE view of the virtio-gpu framebuffer (the
	// compose-N target). Seat-only, full-frame only.
	M33ScanoutTag uintptr = 0x4000000000000000

	// The framebuffer geometry the scanout bind is full-frame against
	// (kernel/src/virtio_gpu.zig: fb_width x fb_height x fb_bpp).
	ScanoutWidth   = 1280
	ScanoutHeight  = 720
	ScanoutBPP     = 4
	ScanoutFbBytes = ScanoutWidth * ScanoutHeight * ScanoutBPP // 3,686,400
)

// EvCompositeTick is event kind 18 (ADR 0009 numbering, reserved by WMS1): the
// pacing tick delivered ONLY to the registered WM's process event queue, once
// per scheduler tick.
const EvCompositeTick uint16 = 18

// WmctlRegister asks the kernel to accept the calling process as the active
// render-server seat (slot 65 cmd 1). Returns 0 on success; -EACCES when a
// seat is already taken (the one-seat discipline); -ENXIO when the compositor
// is not armed.
func WmctlRegister() int64 { return syscall1(SlotWmctl, uintptr(WmctlRegisterCmd)) }

// WmctlRequestPresent transfers+flushes the scanout now (slot 65 cmd 3).
// Returns 0 on success; -ENOSYS when no seat is registered; -EACCES from any
// process other than the seat.
func WmctlRequestPresent() int64 { return syscall1(SlotWmctl, uintptr(WmctlRequestPresentCmd)) }

// MmapScanout maps the virtio-gpu framebuffer WRITABLE into the registered
// WM's root — the compose-N target. Seat-only and full-frame only: the kernel
// refuses a non-seat with EACCES, a non-full-frame length with EINVAL, and an
// unarmed framebuffer with ENXIO. Off the guest this degrades to -ENOSYS.
func MmapScanout() ([]byte, error) {
	return MmapHint(M33ScanoutTag, ScanoutFbBytes,
		ProtRead|ProtWrite, MapAnonymous|M33MapShared)
}

// ErrnoOf maps a negative syscall result to the kernel's own error magnitude
// (for callers that branch on it), or 0 when the result is not an error.
func ErrnoOf(r int64) int64 {
	if r < 0 {
		return -r
	}
	return 0
}
