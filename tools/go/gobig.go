// M70c-K (issue #1504) fixture: a REAL GOOS=virelai Go image bigger than
// the kernel's 2 MiB whole-file staging buffer, for the streamed exec path.
//
// The 8 MiB array is deliberately WRITTEN by the program — a read-only
// global would land in the 448 KiB rodata window of the GOOS=virelai link
// recipe — and its values are spread from byte 0 to the last byte, so the
// linker has to carry every one of those bytes in the FILE. Nothing here is
// padding: the payload the guest streams is real initialized image data.
//
// The printed banner is the proof, read back at runtime from 1, 4 and 8 MiB
// into that payload: a half-filled segment reads zero at those offsets, and
// an unmapped page faults instead of printing.
package main

const blobBytes = 8 << 20

// A sparse literal still emits the symbol's data through its LAST non-zero
// byte, which is what puts all 8 MiB in the file (and in the data
// segment's p_filesz).
var blob = [blobBytes]byte{
	0:             'A',
	1 << 20:       'B',
	4 << 20:       'C',
	blobBytes - 1: 'D',
}

func main() {
	// Force the symbol into the writable segment rather than rodata.
	blob[blobBytes-2] = 'E'

	println("big: blob bytes", len(blob))
	println("big: banner",
		string(blob[0:1]),
		string(blob[1<<20:1<<20+1]),
		string(blob[4<<20:4<<20+1]),
		string(blob[blobBytes-2:blobBytes-1]),
		string(blob[blobBytes-1:blobBytes]))

	// Fold the whole payload: the sum is position-independent on purpose
	// (the banner carries the position), and it makes the guest touch every
	// streamed page.
	var sum uint64
	for _, b := range blob {
		sum += uint64(b)
	}
	println("big: sum", sum)
	println("virelai-go big OK")
}
