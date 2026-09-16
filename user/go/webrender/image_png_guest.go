//go:build virelai

package webrender

// PNG is not decoded on the guest yet, and the reason is worth recording
// rather than papering over.
//
// The standard library's image/png pulls in compress/zlib, which pulls in fmt,
// which pulls in os and syscall — and the GOOS=virelai fork has no os/syscall
// (ADR 0026 phase 0a/0b scope: there is no such package for this GOOS). The
// project already pays this tax elsewhere: vi.Itoa64 exists precisely because
// the stdlib formatters "drag in fmt".
//
// The correct fix is the one ADR 0028 S3 already chose for the Zig side: an
// in-tree decoder. user/src/lib/png.zig + lib/flate.zig are that decoder; the Go
// mirror of lib/flate.zig is a card of its own. Until it lands, a PNG <img>
// renders as its labeled placeholder box (visible, never blank) and QOI — which
// is decoded in-tree in image.go — works everywhere.
func decodePNG([]byte) (*Image, error) { return nil, ErrImageUnsupported }
