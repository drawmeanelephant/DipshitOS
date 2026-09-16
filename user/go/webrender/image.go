package webrender

import (
	"bytes"
	"errors"
)

// In-guest image decoding (ADR 0028 S3): <img> becomes real pixels, in two
// formats the project owns. PNG uses the standard library's pure-Go decoder
// (no cgo, no x/image); QOI is decoded here, because a 60-line decoder beats a
// dependency for a format whose whole point is being 60 lines.

// Image is a decoded raster in the same 32-bpp word layout the surfaces use:
// one 0xAARRGGBB word per pixel, row-major.
type Image struct {
	Width  int
	Height int
	Pix    []uint32
}

// At returns the pixel at (x, y), or 0 outside the image.
func (im *Image) At(x, y int) uint32 {
	if im == nil || x < 0 || y < 0 || x >= im.Width || y >= im.Height {
		return 0
	}
	return im.Pix[y*im.Width+x]
}

// ImageResolver supplies the bytes behind an <img src>. Layout never touches
// the filesystem or the network itself (ADR 0028 D1/D3): the app hands in a
// resolver, and a nil resolver means every image renders as its alt-text box.
type ImageResolver func(src string) ([]byte, bool)

// Image caps. A page cannot make the renderer allocate an unbounded raster.
const (
	maxImagePixels = 512 * 512
	maxImageBytes  = 4 << 20
)

// ErrImageUnsupported is returned for a format this decoder does not handle.
var ErrImageUnsupported = errors.New("webrender: unsupported image format")

// DecodeImage decodes a PNG or QOI image. Any other format, a truncated file,
// or an image past the caps returns an error — the caller then falls back to
// the placeholder box rather than rendering nothing.
func DecodeImage(data []byte) (*Image, error) {
	if len(data) > maxImageBytes {
		return nil, errors.New("webrender: image past the byte cap")
	}
	switch {
	case len(data) >= 8 && bytes.Equal(data[:8], pngMagic):
		return decodePNG(data)
	case len(data) >= 4 && string(data[:4]) == "qoif":
		return decodeQOI(data)
	}
	return nil, ErrImageUnsupported
}

var pngMagic = []byte{0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n'}

// QOI: "Quite OK Image". Header is 14 bytes (magic, width, height, channels,
// colorspace), then a byte stream that ends with a 7-zero + 0x01 marker.
func decodeQOI(data []byte) (*Image, error) {
	if len(data) < 14 {
		return nil, errors.New("webrender: qoi header truncated")
	}
	w := int(be32b(data[4:8]))
	h := int(be32b(data[8:12]))
	if w <= 0 || h <= 0 || w*h > maxImagePixels {
		return nil, errors.New("webrender: qoi geometry rejected")
	}
	out := &Image{Width: w, Height: h, Pix: make([]uint32, w*h)}

	var index [64]uint32
	var px uint32 = 0xff000000
	p := 14
	n := w * h
	i := 0
	for i < n {
		if p >= len(data) {
			return nil, errors.New("webrender: qoi stream truncated")
		}
		b1 := data[p]
		p++
		switch {
		case b1 == 0xfe: // QOI_OP_RGB
			if p+3 > len(data) {
				return nil, errors.New("webrender: qoi rgb truncated")
			}
			px = 0xff000000 | uint32(data[p])<<16 | uint32(data[p+1])<<8 | uint32(data[p+2])
			p += 3
		case b1 == 0xff: // QOI_OP_RGBA
			if p+4 > len(data) {
				return nil, errors.New("webrender: qoi rgba truncated")
			}
			px = uint32(data[p])<<24 | uint32(data[p+1])<<16 | uint32(data[p+2])<<8 | uint32(data[p+3])
			p += 4
		case b1>>6 == 0: // QOI_OP_INDEX
			px = index[b1&63]
		case b1>>6 == 1: // QOI_OP_DIFF
			dr := int((b1>>4)&3) - 2
			dg := int((b1>>2)&3) - 2
			db := int(b1&3) - 2
			px = qoiDelta(px, dr, dg, db)
		case b1>>6 == 2: // QOI_OP_LUMA
			if p >= len(data) {
				return nil, errors.New("webrender: qoi luma truncated")
			}
			b2 := data[p]
			p++
			vg := int(b1&0x3f) - 32
			px = qoiDelta(px, int(b2>>4)-8+vg, vg, int(b2&0x0f)-8+vg)
		default: // QOI_OP_RUN
			run := int(b1&0x3f) + 1
			// A run may span the end of the buffer only if the file is
			// malformed; clamp rather than write past the image.
			if i+run > n {
				run = n - i
			}
			for k := 0; k < run; k++ {
				out.Pix[i] = px
				i++
			}
			index[qoiHash(px)] = px
			continue
		}
		out.Pix[i] = px
		index[qoiHash(px)] = px
		i++
	}
	return out, nil
}

func qoiHash(px uint32) uint32 {
	return (px>>16&0xff)*3 + (px>>8&0xff)*5 + (px&0xff)*7
}

func qoiDelta(px uint32, dr, dg, db int) uint32 {
	r := int(px>>16&0xff) + dr
	g := int(px>>8&0xff) + dg
	b := int(px&0xff) + db
	return px&0xff000000 | uint32(clamp8(r))<<16 | uint32(clamp8(g))<<8 | uint32(clamp8(b))
}

func clamp8(v int) int {
	if v < 0 {
		return 0
	}
	if v > 255 {
		return 255
	}
	return v
}

func be32b(b []byte) uint32 {
	return uint32(b[0])<<24 | uint32(b[1])<<16 | uint32(b[2])<<8 | uint32(b[3])
}
