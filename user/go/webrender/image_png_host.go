//go:build !virelai

package webrender

import (
	"bytes"
	"errors"
	"image/png"
)

// PNG decoding off the guest. See image_png_guest.go for why this file is
// build-tagged instead of simply imported everywhere.
func decodePNG(data []byte) (*Image, error) {
	img, err := png.Decode(bytes.NewReader(data))
	if err != nil {
		return nil, err
	}
	b := img.Bounds()
	w, h := b.Dx(), b.Dy()
	if w <= 0 || h <= 0 {
		return nil, errors.New("webrender: empty png")
	}
	if w*h > maxImagePixels {
		return nil, errors.New("webrender: png past the pixel cap")
	}
	out := &Image{Width: w, Height: h, Pix: make([]uint32, w*h)}
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			r, g, bl, a := img.At(b.Min.X+x, b.Min.Y+y).RGBA()
			out.Pix[y*w+x] = (a>>8)<<24 | (r>>8)<<16 | (g>>8)<<8 | (bl >> 8)
		}
	}
	return out, nil
}
