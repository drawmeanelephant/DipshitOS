package webrender

import (
	"strings"

	"virelai/webrender/font"
)

// ItemKind is the kind of painted primitive.
type ItemKind uint8

const (
	// ItemRect is a solid background/border rectangle.
	ItemRect ItemKind = iota
	// ItemText is a run of text.
	ItemText
	// ItemRule is a 1-pixel horizontal rule.
	ItemRule
	// ItemImage is an image placeholder box.
	ItemImage
)

// Item is one positioned paint primitive in content coordinates (0,0 = top
// left of the document, scrolling is applied at paint time).
type Item struct {
	Kind   ItemKind
	X, Y   int
	W, H   int
	Text   string
	Size   int // font scale
	Mono   bool
	Bold   bool
	Color  uint32
	Bg     uint32
	Target string // link target, when the run is inside an <a href>
}

// Link is a hit-testable link rectangle in content coordinates.
type Link struct {
	X, Y, W, H int
	Target     string
}

// Layout is the positioned result of laying a document out at one width.
type Layout struct {
	Items     []Item
	Links     []Link
	Width     int
	Height    int
	Lines     int
	Blocks    int
	Truncated bool
}

// MaxItems caps the primitive list (a static bound; overflow is visible via
// Layout.Truncated rather than a panic).
const MaxItems = 24000

type inlineRun struct {
	text   string
	st     Style
	target string
}

type builder struct {
	items     []Item
	links     []Link
	m         Measurer
	right     int // absolute right edge of the content box
	lineX     int // absolute left edge of the current inline flow
	y         int
	lines     int
	blocks    int
	truncated bool
	inline    []inlineRun
}

// LayoutDocument lays out a parsed document in a content box of the given
// pixel width. m may be nil to use the real bitmap metric.
func LayoutDocument(doc *Document, width int, m Measurer) *Layout {
	if width < 32 {
		width = 32
	}
	if m == nil {
		m = DefaultMeasurer
	}
	b := &builder{m: m, right: width}
	b.walkChildren(doc.Root, StyleFor("body"), 0)
	b.flushInline()
	return &Layout{
		Items:     b.items,
		Links:     b.links,
		Width:     width,
		Height:    b.y,
		Lines:     b.lines,
		Blocks:    b.blocks,
		Truncated: b.truncated || doc.Truncated,
	}
}

// ScrollMax is the largest useful scroll offset for a viewport height.
func ScrollMax(l *Layout, viewH int) int {
	if l.Height <= viewH {
		return 0
	}
	return l.Height - viewH
}

func (b *builder) cap() bool {
	if len(b.items) >= MaxItems {
		b.truncated = true
		return true
	}
	return false
}

// walkChildren walks a node's children, sending text and inline elements to
// the inline buffer and block elements to block().
func (b *builder) walkChildren(n *Node, st Style, indent int) {
	for _, c := range n.Children {
		if b.truncated {
			return
		}
		if c.Kind == KindText {
			b.pushText(c.Text, st, "")
			continue
		}
		es := StyleFor(c.Tag)
		if es.Skip {
			continue
		}
		if c.Tag == "br" {
			b.hardBreak()
			continue
		}
		if BlockElement(c.Tag) {
			b.block(c, es, indent)
			continue
		}
		b.inlineElement(c, mergeInline(st, es), indent, "")
	}
}

func (b *builder) inlineElement(e *Node, st Style, indent int, inherited string) {
	target := inherited
	if e.Tag == "a" {
		if href := e.Attr("href"); href != "" {
			target = href
		}
	}
	for _, c := range e.Children {
		if c.Kind == KindText {
			b.pushText(c.Text, st, target)
			continue
		}
		es := StyleFor(c.Tag)
		if es.Skip {
			continue
		}
		if c.Tag == "br" {
			b.hardBreak()
			continue
		}
		if BlockElement(c.Tag) {
			b.block(c, es, indent)
			continue
		}
		child := mergeInline(st, es)
		ct := target
		if c.Tag == "a" {
			ct = c.Attr("href")
		}
		b.inlineElement(c, child, indent, ct)
	}
}

func (b *builder) block(e *Node, st Style, indent int) {
	b.flushInline()
	if b.cap() {
		return
	}
	b.blocks++
	b.y += st.MarginTop
	left := indent + st.Indent
	if b.right-left < 16 {
		left = b.right - 16
		if left < 0 {
			left = 0
		}
	}
	inner := b.right - left

	switch e.Tag {
	case "hr":
		b.items = append(b.items, Item{Kind: ItemRule, X: left, Y: b.y + 3, W: inner, H: 1, Color: ColorRule})
		b.y += 4
	case "pre":
		b.emitPre(e, left, inner)
	case "blockquote":
		barIdx := len(b.items)
		b.items = append(b.items, Item{Kind: ItemRect, X: left, Y: b.y, W: 3, H: 1, Bg: ColorAccent})
		contentLeft := left + 6
		b.lineX = contentLeft
		b.walkChildren(e, st, contentLeft)
		b.flushInline()
		b.lineX = 0
		if h := b.y - b.items[barIdx].Y; h > 1 {
			b.items[barIdx].H = h
		}
	case "li":
		b.pushText("* ", Style{Size: st.Size, Color: ColorMuted}, "")
		b.lineX = left
		b.walkChildren(e, st, left)
		b.flushInline()
		b.lineX = 0
	case "img":
		b.emitImage(e, left, inner)
	case "table":
		b.emitTable(e, left, inner)
	default:
		b.lineX = left
		b.walkChildren(e, st, left)
		b.flushInline()
		b.lineX = 0
	}
	b.y += st.MarginBottom
}

func mergeInline(parent, child Style) Style {
	out := child
	out.Mono = child.Mono || parent.Mono
	out.Bold = child.Bold || parent.Bold
	if out.Color == 0 {
		out.Color = parent.Color
	}
	if out.Size == 0 {
		out.Size = parent.Size
	}
	return out
}

// pushText collapses HTML whitespace (runs of space/tab/newline become one
// space) unless the run is preformatted, then queues it for line building.
func (b *builder) pushText(text string, st Style, target string) {
	if text == "" {
		return
	}
	if !st.Mono {
		text = collapseWS(text)
	}
	if text == "" {
		return
	}
	b.inline = append(b.inline, inlineRun{text: text, st: st, target: target})
}

// hardBreak forces the pending inline content onto the next line.
func (b *builder) hardBreak() {
	if len(b.inline) == 0 {
		return
	}
	b.inline = append(b.inline, inlineRun{text: "\n", st: Style{Size: 1, Color: ColorText}})
}

func collapseWS(s string) string {
	if s == "" {
		return ""
	}
	lead := isWSByte(s[0])
	trail := isWSByte(s[len(s)-1])
	var b strings.Builder
	b.Grow(len(s))
	pend := false
	for i := 0; i < len(s); i++ {
		if isWSByte(s[i]) {
			pend = true
			continue
		}
		if pend && b.Len() > 0 {
			b.WriteByte(' ')
		}
		pend = false
		b.WriteByte(s[i])
	}
	core := b.String()
	if core == "" {
		if lead || trail {
			return " "
		}
		return ""
	}
	if lead {
		core = " " + core
	}
	if trail {
		core += " "
	}
	return core
}

func isWSByte(c byte) bool {
	return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f'
}

// flushInline wraps the queued inline runs into lines and emits text items
// (plus link rectangles and link underlines).
func (b *builder) flushInline() {
	if len(b.inline) == 0 {
		return
	}
	runs := b.inline
	b.inline = make([]inlineRun, 0, 8)

	type seg struct {
		text   string
		st     Style
		target string
		w      int
		space  bool
		nl     bool
	}
	var segs []seg
	for _, r := range runs {
		if r.text == "\n" {
			segs = append(segs, seg{nl: true})
			continue
		}
		i := 0
		for i < len(r.text) {
			if r.text[i] == ' ' {
				n := 0
				for i < len(r.text) && r.text[i] == ' ' {
					i++
					n++
				}
				segs = append(segs, seg{space: true, w: n * font.Advance(r.st.Size), st: r.st})
				continue
			}
			j := i
			for j < len(r.text) && r.text[j] != ' ' {
				j++
			}
			word := r.text[i:j]
			segs = append(segs, seg{text: word, st: r.st, target: r.target, w: b.m(word, r.st.Size)})
			i = j
		}
	}

	x := b.lineX
	y := b.y
	avail := b.right - b.lineX
	if avail < 16 {
		avail = 16
	}
	wid := b.lineX + avail
	lineH := font.LineHeight(1)
	started := false
	counted := false

	for _, sg := range segs {
		if b.truncated {
			break
		}
		if sg.nl {
			if started {
				y += lineH
				started = false
				counted = false
			}
			continue
		}
		if sg.space {
			if started {
				x += sg.w
			}
			continue
		}
		if started && x+sg.w > wid {
			y += lineH
			x = b.lineX
			started = false
			counted = false
			lineH = font.LineHeight(1)
		}
		lh := font.LineHeight(sg.st.Size)
		if lh > lineH {
			lineH = lh
		}
		if !counted {
			b.lines++
			counted = true
		}
		color := sg.st.Color
		if color == 0 {
			color = ColorText
		}
		if b.cap() {
			break
		}
		b.items = append(b.items, Item{
			Kind: ItemText, X: x, Y: y, W: sg.w, H: lh,
			Text: sg.text, Size: sg.st.Size, Mono: sg.st.Mono, Bold: sg.st.Bold,
			Color: color, Target: sg.target,
		})
		if sg.target != "" && len(b.links) < MaxItems {
			b.links = append(b.links, Link{X: x, Y: y, W: sg.w, H: lh, Target: sg.target})
			// Underline: the decoration that makes a link readable without
			// color (the Zig renderer's rule, kept for the same reason).
			b.items = append(b.items, Item{Kind: ItemRule, X: x, Y: y + 7, W: sg.w, H: 1, Color: ColorAccent})
		}
		x += sg.w
		started = true
	}
	if started {
		y += lineH
	}
	b.y = y
	if b.y < 0 {
		b.y = 0
	}
}

func (b *builder) emitPre(e *Node, left, inner int) {
	raw := rawText(e)
	raw = strings.ReplaceAll(raw, "\r\n", "\n")
	lines := strings.Split(raw, "\n")
	// Drop a single trailing empty line produced by a closing tag on its
	// own line; keep everything else verbatim so nothing is lost.
	if n := len(lines); n > 1 && strings.TrimSpace(lines[n-1]) == "" {
		lines = lines[:n-1]
	}
	const stride = 10
	cols := inner / font.Advance(1)
	if cols < 1 {
		cols = 1
	}
	box := Item{Kind: ItemRect, X: left, Y: b.y, W: inner, H: len(lines)*stride + 6, Bg: ColorSurface}
	b.items = append(b.items, box)
	ty := b.y + 3
	for _, ln := range lines {
		ln = UpperASCII(ln)
		if len(ln) > cols {
			ln = ln[:cols-1] + "\u2026"
			ln = UpperASCII(ln)
			if len(ln) > cols {
				ln = ln[:cols]
			}
		}
		if ln != "" {
			b.items = append(b.items, Item{Kind: ItemText, X: left + 4, Y: ty, W: len(ln) * font.Advance(1), H: stride, Text: ln, Size: 1, Mono: true, Color: ColorText})
		}
		ty += stride
		b.lines++
	}
	b.y = box.Y + box.H
}

func (b *builder) emitImage(e *Node, left, inner int) {
	w := inner
	if w > 96 {
		w = 96
	}
	h := 40
	label := e.Attr("alt")
	if label == "" {
		label = e.Attr("src")
	}
	if label == "" {
		label = "img"
	}
	b.items = append(b.items, Item{Kind: ItemImage, X: left, Y: b.y, W: w, H: h, Text: label, Color: ColorMuted})
	b.y += h
}

func (b *builder) emitTable(e *Node, left, inner int) {
	rows := collectRows(e)
	if len(rows) == 0 {
		// A malformed table still renders its text (ADR 0028 D5).
		b.lineX = left
		b.walkChildren(e, Style{Size: 1, Color: ColorText}, left)
		b.flushInline()
		b.lineX = 0
		return
	}
	cols := 1
	for _, r := range rows {
		if len(r.cells) > cols {
			cols = len(r.cells)
		}
	}
	if cols > 8 {
		cols = 8
	}
	gutter := 2
	colw := (inner - gutter*(cols-1)) / cols
	if colw < 8 {
		colw = 8
	}
	startY := b.y
	for _, r := range rows {
		rowTop := b.y
		maxLines := 1
		savedRight := b.right
		for c := 0; c < len(r.cells); c++ {
			cell := r.cells[c]
			st := StyleFor(cell.tag)
			st.Bold = st.Bold || r.header
			cx := left + c*(colw+gutter)
			cy := rowTop + 2
			b.lineX = cx
			cellRight := cx + colw
			if cellRight > b.right {
				cellRight = b.right
			}
			b.right, savedRight = cellRight, b.right
			b.pushText(cell.text, st, "")
			before := b.y
			b.flushInline()
			n := 0
			for _, it := range b.items {
				if it.Kind == ItemText && it.Y >= cy-2 {
					n++
				}
			}
			_ = n
			if lines := (b.y - cy) / font.LineHeight(1); lines > maxLines {
				maxLines = lines
			}
			if b.y < before {
				b.y = before
			}
			b.right = savedRight
		}
		h := maxLines*font.LineHeight(1) + 5
		b.y = rowTop + h
		if r.header {
			b.items = append(b.items, Item{Kind: ItemRule, X: left, Y: b.y - 1, W: cols*colw + gutter*(cols-1), H: 1, Color: ColorRule})
		}
	}
	if b.y == startY {
		b.y += font.LineHeight(1)
	}
	b.lineX = 0
}

type tableRow struct {
	cells  []tableCell
	header bool
}

type tableCell struct {
	tag  string
	text string
}

func collectRows(e *Node) []tableRow {
	var rows []tableRow
	var walk func(n *Node)
	walk = func(n *Node) {
		for _, c := range n.Children {
			if c.Kind != KindElement {
				continue
			}
			switch c.Tag {
			case "tr":
				var r tableRow
				hdr := true
				for _, cell := range c.Children {
					if cell.Kind != KindElement {
						continue
					}
					if cell.Tag == "td" || cell.Tag == "th" {
						if cell.Tag == "td" {
							hdr = false
						}
						r.cells = append(r.cells, tableCell{tag: cell.Tag, text: collapseWS(rawText(cell))})
					}
				}
				r.header = hdr && len(r.cells) > 0
				if len(rows) < 64 && len(r.cells) > 0 {
					rows = append(rows, r)
				}
			case "thead", "tbody", "tfoot", "table":
				walk(c)
			}
		}
	}
	walk(e)
	return rows
}

// rawText flattens an element's text content (all descendants, in order).
func rawText(n *Node) string {
	var b strings.Builder
	var walk func(*Node)
	walk = func(x *Node) {
		if x.Kind == KindText {
			b.WriteString(x.Text)
			return
		}
		if x.Tag == "br" {
			b.WriteByte('\n')
			return
		}
		if SkipSubtree(x.Tag) {
			return
		}
		for _, c := range x.Children {
			walk(c)
		}
	}
	walk(n)
	return b.String()
}

// TextContent returns the document's flattened readable text (used by the
// browser's "degrade to readable text" path and by tests).
func TextContent(n *Node) string { return collapseWS(rawText(n)) }
