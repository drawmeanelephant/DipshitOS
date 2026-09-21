// M72a (issue #1579) fixture: a REAL GOOS=virelai Go image whose BSS is
// larger than the entire file, for the loader's mapped-memory bound.
//
// The 8 MiB `blob` is the same deliberate payload gobig.go carries: the
// program WRITES it (a read-only global would land in the 448 KiB rodata
// window of the GOOS=virelai link recipe) and its values are spread from
// byte 0 to the last byte, so the linker has to put every one of those bytes
// in the FILE — which is what makes this image take the STREAMED exec path
// (a file over the 2 MiB staging buffer) rather than the staged one.
//
// `scratch` is the point of the fixture: 40 MiB of zero-initialized,
// pointer-free global, i.e. `.noptrbss`, i.e. `p_memsz - p_filesz` — bytes
// that no file can hold. That is the shape `crypto/internal/fips140/drbg`
// gives every Go binary that reaches it (`var memory
// entropy.ScratchBuffer` is `[1 << 25]byte`), and the shape the old
// `memsz`-charged `load_max` refused as `segment_too_large` before the image
// ever entered EL0.
//
// The banner is the proof that the whole mapping is real: the program writes
// the FIRST and LAST byte of that 40 MiB and reads both back before
// printing, so a short mapping faults (or prints the wrong byte) instead of
// passing, and `go-hello` run 11 holds the guest's `datapages=` to the
// writable segment's declared `p_memsz` on the host.
package main

const blobBytes = 8 << 20
const scratchBytes = 40 << 20

// A sparse literal still emits the symbol's data through its LAST non-zero
// byte, which is what puts all 8 MiB in the file (and in the data segment's
// p_filesz).
var blob = [blobBytes]byte{
	0:             'A',
	1 << 20:       'B',
	4 << 20:       'C',
	blobBytes - 1: 'D',
}

// Zero-valued, never read before it is written, and holds no pointers: the
// linker must place this in `.noptrbss`, where it costs no file bytes at all.
var scratch [scratchBytes]byte

func main() {
	// Force the blob into the writable segment rather than rodata.
	blob[blobBytes-2] = 'E'

	// Touch both ends of the 40 MiB tail: the first byte, and the last byte
	// of the mapped region.
	scratch[0] = 1
	scratch[scratchBytes-1] = 2

	println("loadbss: blob bytes", len(blob), "scratch bytes", len(scratch))
	println("loadbss: banner",
		string(blob[0:1]),
		string(blob[1<<20:1<<20+1]),
		string(blob[4<<20:4<<20+1]),
		string(blob[blobBytes-2:blobBytes-1]),
		string(blob[blobBytes-1:blobBytes]))
	println("loadbss: scratch ends", scratch[0], scratch[scratchBytes-1])
	println("virelai-go loadbss OK")
}
