package webrender

import (
	"bytes"
	"testing"
)

// qoiEncode builds a QOI in memory: header, one QOI_OP_RGB per pixel, then the
// 7-zero + 0x01 end marker. It is deliberately the simplest legal encoding, so
// the decoder meets a file it cannot have special-cased.
//
// This exists because the decoder shipped without it and the class-B gate found
// the hole instead: qoiHash dropped the format's `% 64`, so the first swatch
// colour indexed 1043 into a 64-entry table and panicked the guest
// (artifacts/live-web-ttf-serial-03.log: "index out of range [1043] with
// length 64"). The old tests only fed the decoder junk, which cannot catch a
// hash overrun.
func qoiEncode(w, h int, quads [][3]byte) []byte {
	var b bytes.Buffer
	b.WriteString("qoif")
	for _, v := range []int{w, h} {
		b.Write([]byte{byte(v >> 24), byte(v >> 16), byte(v >> 8), byte(v)})
	}
	b.WriteByte(4) // channels
	b.WriteByte(0) // colorspace
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			c := quads[(y*2/h)*2+(x*2/w)]
			b.Write([]byte{0xfe, c[0], c[1], c[2]})
		}
	}
	b.Write([]byte{0, 0, 0, 0, 0, 0, 0, 1})
	return b.Bytes()
}

// TestDecodeQOIRoundTrip decodes a real QOI and checks exact pixels, so the
// header, the opcode loop, the index table and the end marker are all
// exercised on real data.
func TestDecodeQOIRoundTrip(t *testing.T) {
	quads := [][3]byte{
		{0x11, 0x7f, 0x33}, {0xd0, 0x33, 0x99},
		{0x22, 0x66, 0xdd}, {0xee, 0xcc, 0x00},
	}
	const w, h = 16, 16
	img, err := DecodeImage(qoiEncode(w, h, quads))
	if err != nil {
		t.Fatalf("DecodeImage(qoi): %v", err)
	}
	if img.Width != w || img.Height != h {
		t.Fatalf("decoded %dx%d, want %dx%d", img.Width, img.Height, w, h)
	}
	spots := []struct{ x, y, q int }{{3, 3, 0}, {11, 3, 1}, {3, 11, 2}, {11, 11, 3}}
	for _, s := range spots {
		want := uint32(0xff000000) | uint32(quads[s.q][0])<<16 |
			uint32(quads[s.q][1])<<8 | uint32(quads[s.q][2])
		if got := img.At(s.x, s.y); got != want {
			t.Errorf("pixel (%d,%d) = %#08x, want %#08x", s.x, s.y, got, want)
		}
	}
	t.Logf("qoi round-trip ok: %dx%d, four exact quadrant colours", img.Width, img.Height)
}

// TestQOIHashStaysInTheIndexTable pins the mask directly: any hash the decoder
// can produce must address one of the format's 64 index slots. Without the
// mask this test fails on the very first colour.
func TestQOIHashStaysInTheIndexTable(t *testing.T) {
	for _, px := range []uint32{
		0xff117f33, 0xffd03399, 0xff2266dd, 0xffeecc00,
		0xffffffff, 0xff000000, 0xff7f7f7f, 0xff010203,
	} {
		if h := qoiHash(px); h >= 64 {
			t.Errorf("qoiHash(%#08x) = %d, outside the 64-entry index table", px, h)
		}
	}
}

// TestQOIOpcodesAgainstAHandBuiltStream covers all four opcode families plus
// the index cache, so a decoder that only ever saw QOI_OP_RGB cannot pass.
func TestQOIOpcodesAgainstAHandBuiltStream(t *testing.T) {
	var b bytes.Buffer
	b.WriteString("qoif")
	b.Write([]byte{0, 0, 0, 4, 0, 0, 0, 1}) // width 4, height 1
	b.WriteByte(4)                          // channels
	b.WriteByte(0)                          // colorspace
	// QOI_OP_RGB: red (255,0,0)
	b.Write([]byte{0xfe, 0xff, 0x00, 0x00})
	// QOI_OP_DIFF from red: dr=-1 dg=+1 db=0 => (254,1,0)
	b.WriteByte(byte(0x40 | (1 << 4) | (3 << 2) | 2))
	// QOI_OP_LUMA: vg=0, dr_dg=+1, db_dg=-1 => (255,1,0)
	b.WriteByte(byte(0x80 | 32))
	b.WriteByte(byte((1+8)<<4 | (-1 + 8)))
	// QOI_OP_INDEX: back to the cached red
	b.WriteByte(byte(qoiHash(0xffff0000)))
	b.Write([]byte{0, 0, 0, 0, 0, 0, 0, 1})

	img, err := DecodeImage(b.Bytes())
	if err != nil {
		t.Fatalf("DecodeImage: %v", err)
	}
	if img.Width != 4 || img.Height != 1 {
		t.Fatalf("decoded %dx%d, want 4x1", img.Width, img.Height)
	}
	t.Logf("opcode stream decoded: %#08x %#08x %#08x %#08x",
		img.At(0, 0), img.At(1, 0), img.At(2, 0), img.At(3, 0))
	for i, want := range []uint32{0xffff0000, 0xfffe0100, 0xffff0100, 0xffff0000} {
		if got := img.At(i, 0); got != want {
			t.Errorf("pixel %d = %#08x, want %#08x", i, got, want)
		}
	}
	if img.At(3, 0) != img.At(0, 0) {
		t.Errorf("QOI_OP_INDEX did not return the cached colour: %#08x vs %#08x",
			img.At(3, 0), img.At(0, 0))
	}
}

// TestDecodeQOIRespectsThePixelCap: a hostile header is refused, not allocated.
func TestDecodeQOIRespectsThePixelCap(t *testing.T) {
	var b bytes.Buffer
	b.WriteString("qoif")
	b.Write([]byte{0, 0, 0x40, 0, 0, 0, 0x40, 0}) // 16384 x 16384
	b.WriteByte(4)
	b.WriteByte(0)
	if img, err := DecodeImage(b.Bytes()); err == nil {
		t.Errorf("a 16384x16384 qoi decoded to %dx%d", img.Width, img.Height)
	}
}
