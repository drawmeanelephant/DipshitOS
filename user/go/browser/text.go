package main

import (
	"strings"

	"virelai/vi"
	"virelai/webrender"
)

// Text plumbing for the browser: load the two faces the Zig userland loads,
// pick a text engine, and republish what was chosen on the serial line so a
// gate can assert the page is not silently back on the 8x8 grid.

// The faces, at the same share paths the Zig userland probes
// (user/src/lib/ui/draw.zig init_fonts: /host/INTER.TTF, /host/FIRACODE.TTF).
// The gate seeds them with tools/lib/gate-run.sh's `vgate_share seed`.
const (
	fontUIPath   = "/host/INTER.TTF"
	fontMonoPath = "/host/FIRACODE.TTF"
)

// maxFontBytes bounds one face read. Inter ships at 411,640 bytes and Fira
// Code at 289,624, so 512 KiB holds both with room for a slightly larger
// licensed build. It is deliberately NOT vi.MaxFileBytes (256 KiB): that cap is
// a policy for the browser's PAGE loads, and reusing it here silently truncated
// Inter in half and dropped the renderer back onto the bitmap. A face past this
// bound fails to parse and the renderer falls back — visible, never blank.
const maxFontBytes = 512 * 1024

// maxImageBytes bounds one <img> read from the share.
const maxImageBytes = 1024 * 1024

// readWholeFile reads up to max bytes of a share file. It is the browser's own
// reader rather than vi.ReadFileAll because that helper clamps every request to
// vi.MaxFileBytes (see maxFontBytes).
func readWholeFile(path string, max int) []byte {
	h, rc := vi.FileOpen(path, vi.ModeRead)
	if rc < 0 || h < 0 {
		return nil
	}
	defer vi.FileClose(uint32(h))
	out := make([]byte, 0, 64*1024)
	buf := make([]byte, 16*1024)
	for len(out) < max {
		n, rr := vi.FileRead(uint32(h), buf)
		if rr < 0 || n <= 0 {
			break
		}
		take := n
		if len(out)+take > max {
			take = max - len(out)
		}
		out = append(out, buf[:take]...)
		if take < n {
			break
		}
	}
	return out
}

// loadTextEngine loads both faces and returns the engine to render with. Any
// failure (a missing face, a short read, a rejected font) simply leaves that
// face out, which is how the renderer reaches its documented fallback.
func loadTextEngine() (webrender.Fonts, string, string) {
	ui := readWholeFile(fontUIPath, maxFontBytes)
	mono := readWholeFile(fontMonoPath, maxFontBytes)
	f := webrender.NewFonts(ui, mono)
	uiState := "truetype"
	if f.UI == nil {
		uiState = "missing"
	}
	monoState := "truetype"
	if f.Mono == nil {
		monoState = "missing"
	}
	return f, uiState, monoState
}

// textProbeString is the Inter-or-grid probe, published on the serial line.
//
// It is deliberately made of FACTS a gate can assert rather than adjectives:
// the engine's name, whether advances are per-glyph, the line heights the layout
// actually uses, and three measured advances. On the 8x8 fallback every advance
// is 8 and the h1 line box is 18px; on Inter at 13px the advances differ per
// glyph and the h1 line box is 33px. Those numbers cannot both be true, so a
// silent regression back to the grid fails the gate instead of merely looking
// slightly off in a screenshot.
func textProbeString(t webrender.TextEngine) string {
	if t == nil {
		t = webrender.Bitmap{}
	}
	body := webrender.Style{Size: 1, Color: webrender.ColorText}
	h1 := webrender.Style{Size: 2, Color: webrender.ColorText}
	mono := webrender.Style{Size: 1, Mono: true}
	return "face=" + t.Name() +
		" proportional=" + boolStr(t.Proportional()) +
		" body-lineh=" + itoa(t.LineHeight(body)) +
		" h1-lineh=" + itoa(t.LineHeight(h1)) +
		" mono-lineh=" + itoa(t.LineHeight(mono)) +
		" adv-i=" + itoa(t.Measure("i", body)) +
		" adv-W=" + itoa(t.Measure("W", body)) +
		" adv-space=" + itoa(t.Measure(" ", body))
}

// resolveImage supplies <img> bytes to the renderer. Layout never reads a file
// itself; this is the app's side of that seam (ADR 0028 D1/D3). Remote sources
// are refused outright — an <img> is not a reason to open a socket, and this
// browser has no image-over-network path.
func (a *app) resolveImage(src string) ([]byte, bool) {
	if src == "" {
		return nil, false
	}
	low := strings.ToLower(src)
	if strings.HasPrefix(low, "http://") || strings.HasPrefix(low, "https://") {
		return nil, false
	}
	path := src
	if !strings.HasPrefix(path, "/") {
		path = relativeTo(a.target, src)
	}
	data := readWholeFile(path, maxImageBytes)
	if len(data) == 0 {
		return nil, false
	}
	return data, true
}
