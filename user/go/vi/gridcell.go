package vi

// M80i (#1725): the terminal GRID's zoom ladder, mirrored for Go apps.
//
// One SETTINGS.TXT key (`font_size`) drives two ladders in the kernel
// (settings.zig apply_font_size): the legacy framebuffer text layer
// (8x8/16x16/24x24) and the terminal grid's cell (kernel/src/font_metrics.zig,
// rasterized per size in kernel/src/font_atlas_data.zig). A WIN_RESIZE
// event carries only the pixel rect (arg0=w, arg1=h — the pinned payload
// shape both kernel emit sites push), so a cell-addressed app derives its
// grid from the rect AND the active rung. This file is the rung mirror.
//
// The table mirrors kernel/src/font_atlas_data.zig's three rasterized
// FiraCode cells (11/13/17 px): small 7x13, medium 8x16, large 10x21.
// At BOOT an absent or unrecognized `font_size` row keeps the boot look:
// the grid's compiled default rung is MEDIUM (8x16) even though the text
// layer's default is small — the one-key/two-ladders wart the card
// documents. At RUNTIME such a row applies NOTHING (kernel
// apply_font_size keeps both ladders), so the derivation keeps the last
// VALID cell too — the store row and the grid never disagree.
// Pinned against the kernel fixture by
// TestTerminalCellForSizePinsKernelAtlas (user/go/tabapp/cellgrid_test.go).

// settingsPath is the store the kernel, the seat and the panel all read.
const settingsPath = "/host/SETTINGS.TXT"

// settingsMax mirrors the kernel's bounded load buffer (settings.zig).
const settingsMax = 2048

// TerminalCell is the grid cell the rung IN FORCE maps to: the last
// `font_size` row of /host/SETTINGS.TXT (kernel set_internal semantics —
// a later row wins), through the applies-nothing mirror in
// TerminalCellForSettings. A missing or unreadable file keeps the rung in
// force exactly like an absent row. Read it per WIN_RESIZE: the kernel
// publishes the new row before it pushes the event (settings.set's
// font_size branch), so this read always answers with the rung the
// kernel's own reflow just used.
func TerminalCell() (w, h uint32) {
	b, _ := ReadFileAll(settingsPath, settingsMax)
	return TerminalCellForSettings(b)
}

// TerminalCellForSettings maps a SETTINGS.TXT body's `font_size` row to
// the grid cell (last row wins — kernel set_internal semantics), and
// mirrors the kernel contract exactly: apply_font_size on an absent or
// unrecognized value applies NOTHING (both ladders keep what they had,
// settings.zig), so the derivation must not move either — it keeps the
// last VALID cell (the boot look, 8x16, before the first valid row).
// Without that, a stored garbage row sent the app back to 8x16 against a
// grid still at 10x21 until the next valid set (M80i #1791 review
// footnote 1). The state is per-process and tracks the rows this app has
// SEEN: the kernel publishes a valid row before every zoom's WIN_RESIZE
// (settings.set's font_size branch), so the only changes this cannot
// track are ones that land before the app's first read.
func TerminalCellForSettings(body []byte) (w, h uint32) {
	if w, h, ok := cellForRung(settingValue(string(body), "font_size")); ok {
		lastValidW, lastValidH = w, h
	}
	return lastValidW, lastValidH
}

// lastValidW/H is the rung in force as this app last derived it (the boot
// look before the first valid row). One writer: TerminalCellForSettings.
var lastValidW, lastValidH uint32 = 8, 16

// cellForRung is the pure vocabulary table: the kernel's apply_font_size
// names and aliases onto font_metrics' three rungs. ok=false is exactly
// the set apply_font_size maps to null (applies nothing).
func cellForRung(val string) (w, h uint32, ok bool) {
	switch val {
	case "small", "0", "8x8":
		return 7, 13, true
	case "medium", "1", "16x16":
		return 8, 16, true
	case "large", "2", "24x24":
		return 10, 21, true
	}
	return 0, 0, false
}

// TerminalCellForSize maps one stored `font_size` value to the grid cell
// — the kernel's apply_font_size vocabulary (the M20 names and their
// numeric/size aliases) onto font_metrics' three rungs, pure and
// stateless. Anything else, including "" for an ABSENT key, reports the
// boot look (8x16). Apps that want the applies-nothing mirror (the rung
// IN FORCE) call TerminalCellForSettings/TerminalCell instead.
func TerminalCellForSize(val string) (w, h uint32) {
	if w, h, ok := cellForRung(val); ok {
		return w, h
	}
	return 8, 16
}

// settingValue is the last `key=` value in a SETTINGS.TXT body ("" when
// absent), trimmed like the kernel's parse_line. Comments and rows
// without '=' are skipped exactly as the kernel skips them.
func settingValue(body, key string) string {
	found := ""
	for body != "" {
		line := body
		if i := indexByte(line, '\n'); i >= 0 {
			line, body = line[:i], line[i+1:]
		} else {
			body = ""
		}
		if len(line) > 0 && line[len(line)-1] == '\r' {
			line = line[:len(line)-1]
		}
		eq := indexByte(line, '=')
		if eq < 0 {
			continue
		}
		k := trimSpace(line[:eq])
		if k != key {
			continue
		}
		found = trimSpace(line[eq+1:])
	}
	return found
}

// indexByte is strings.IndexByte without importing strings.
func indexByte(s string, c byte) int {
	for i := 0; i < len(s); i++ {
		if s[i] == c {
			return i
		}
	}
	return -1
}

// trimSpace strips the ASCII whitespace the kernel's parse_line trims.
func trimSpace(s string) string {
	start := 0
	for start < len(s) && isSpace(s[start]) {
		start++
	}
	end := len(s)
	for end > start && isSpace(s[end-1]) {
		end--
	}
	return s[start:end]
}

func isSpace(c byte) bool {
	return c == ' ' || c == '\t' || c == '\r' || c == '\n'
}
