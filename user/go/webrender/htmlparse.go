package webrender

import "strings"

// NodeKind distinguishes element and text nodes.
type NodeKind uint8

const (
	// KindElement is an element node (Tag is set).
	KindElement NodeKind = iota
	// KindText is a text node (Text is set).
	KindText
)

// Attr is one HTML attribute.
type Attr struct {
	Name  string
	Value string
}

// Node is a document node: either an element or a run of text.
type Node struct {
	Kind     NodeKind
	Tag      string // lowercase element name (KindElement)
	Text     string // decoded text (KindText)
	Attrs    []Attr
	Children []*Node
}

// Attr returns the value of the named attribute ("" when absent).
func (n *Node) Attr(name string) string {
	for i := range n.Attrs {
		if n.Attrs[i].Name == name {
			return n.Attrs[i].Value
		}
	}
	return ""
}

// HasAttr reports whether the attribute is present.
func (n *Node) HasAttr(name string) bool {
	for i := range n.Attrs {
		if n.Attrs[i].Name == name {
			return true
		}
	}
	return false
}

// Document is a parsed page. Root is a synthetic "document" element whose
// children are the top-level nodes.
type Document struct {
	Root      *Node
	Nodes     int  // total nodes kept
	TextBytes int  // decoded text bytes kept
	Truncated bool // a cap was hit: the remainder was dropped visibly
}

// Parser caps. Every cap is a project decision (ADR 0028 D6): a page that
// exceeds one renders a visible truncation notice rather than panicking,
// hanging, or silently cutting content.
const (
	MaxNodes     = 20000
	MaxDepth     = 256
	MaxAttrLen   = 4096
	MaxAttrCount = 64
)

// VoidElement reports whether tag never has a closing form.
func VoidElement(tag string) bool {
	switch tag {
	case "area", "base", "br", "col", "embed", "hr", "img", "input", "link",
		"meta", "param", "source", "track", "wbr":
		return true
	}
	return false
}

// SkipSubtree reports whether the element's content is never rendered.
func SkipSubtree(tag string) bool {
	switch tag {
	case "script", "style", "head", "title", "meta", "link", "template", "noscript":
		return true
	}
	return false
}

// BlockElement reports whether the element starts a new block box.
func BlockElement(tag string) bool {
	switch tag {
	case "html", "body", "div", "p", "h1", "h2", "h3", "h4", "h5", "h6",
		"ul", "ol", "li", "pre", "blockquote", "hr", "table", "thead", "tbody",
		"tr", "td", "th", "dl", "dt", "dd", "img", "section", "article", "header",
		"footer", "main", "nav", "aside", "figure", "figcaption", "form", "center":
		return true
	}
	return false
}

type parser struct {
	src       []byte
	pos       int
	doc       *Document
	stack     []*Node
	textBytes int
}

// ParseHTML parses src into a Document. It never panics and never drops text:
// malformed markup is flattened into the enclosing block in document order.
func ParseHTML(src []byte) *Document {
	doc := &Document{Root: &Node{Kind: KindElement, Tag: "document"}}
	p := &parser{src: src, doc: doc}
	p.stack = []*Node{doc.Root}

	for p.pos < len(p.src) {
		if doc.Nodes >= MaxNodes {
			doc.Truncated = true
			break
		}
		c := p.src[p.pos]
		if c != '<' {
			p.appendText()
			continue
		}
		if !p.consumeMarkup() {
			// A stray '<' that starts no markup: keep it as text.
			p.appendTextByte('<')
			if len(p.src) > 0 {
				p.pos++
			}
		}
	}
	return doc
}

func (p *parser) top() *Node { return p.stack[len(p.stack)-1] }

func (p *parser) push(n *Node) {
	p.top().Children = append(p.top().Children, n)
	p.doc.Nodes++
	p.stack = append(p.stack, n)
}

func (p *parser) appendTextNode(s string) {
	if s == "" {
		return
	}
	n := &Node{Kind: KindText, Text: s}
	p.top().Children = append(p.top().Children, n)
	p.doc.Nodes++
	p.textBytes += len(s)
	p.doc.TextBytes = p.textBytes
}

// appendText consumes text up to the next '<' and appends it decoded.
func (p *parser) appendText() {
	start := p.pos
	for p.pos < len(p.src) && p.src[p.pos] != '<' {
		p.pos++
	}
	if p.pos == start {
		return
	}
	p.appendTextNode(DecodeEntities(string(p.src[start:p.pos])))
}

func (p *parser) appendTextByte(b byte) {
	if p.top().Kind == KindElement {
		// Coalesce with a trailing text sibling so stray '<' does not create
		// a node per byte on adversarial input.
		kids := p.top().Children
		if n := len(kids); n > 0 && kids[n-1].Kind == KindText {
			kids[n-1].Text += string(b)
			return
		}
	}
	p.appendTextNode(string(b))
}

// consumeMarkup parses one '<...>' construct. Returns false when the byte
// after '<' cannot start markup (the caller then keeps it as text).
func (p *parser) consumeMarkup() bool {
	if p.pos+1 >= len(p.src) {
		return false
	}
	next := p.src[p.pos+1]
	switch {
	case next == '!':
		if p.pos+3 < len(p.src) && p.src[p.pos+2] == '-' && p.src[p.pos+3] == '-' {
			end := indexFrom(p.src, p.pos+4, "-->")
			if end < 0 {
				p.pos = len(p.src)
			} else {
				p.pos = end + 3
			}
			return true
		}
		// <!DOCTYPE ...> and friends: skip to '>'.
		end := indexByteFrom(p.src, p.pos+2, '>')
		if end < 0 {
			p.pos = len(p.src)
		} else {
			p.pos = end + 1
		}
		return true
	case next == '?':
		end := indexByteFrom(p.src, p.pos+2, '>')
		if end < 0 {
			p.pos = len(p.src)
		} else {
			p.pos = end + 1
		}
		return true
	case next == '/':
		return p.closeTag()
	case isNameStart(next):
		return p.openTag()
	}
	return false
}

func (p *parser) closeTag() bool {
	i := p.pos + 2
	nameStart := i
	for i < len(p.src) && isNameChar(p.src[i]) {
		i++
	}
	name := strings.ToLower(string(p.src[nameStart:i]))
	if name == "" {
		return false
	}
	end := indexByteFrom(p.src, i, '>')
	if end < 0 {
		p.pos = len(p.src)
		return true
	}
	p.pos = end + 1
	// Pop to the nearest matching open element; unknown closes are ignored.
	for j := len(p.stack) - 1; j > 0; j-- {
		if p.stack[j].Tag == name {
			p.stack = p.stack[:j]
			return true
		}
	}
	return true
}

func (p *parser) openTag() bool {
	i := p.pos + 1
	nameStart := i
	for i < len(p.src) && isNameChar(p.src[i]) {
		i++
	}
	tag := strings.ToLower(string(p.src[nameStart:i]))
	if tag == "" {
		return false
	}
	node := &Node{Kind: KindElement, Tag: tag}

	// Attributes.
	attrCount := 0
	for i < len(p.src) {
		for i < len(p.src) && isSpace(p.src[i]) {
			i++
		}
		if i >= len(p.src) {
			break
		}
		if p.src[i] == '>' {
			i++
			break
		}
		if p.src[i] == '/' {
			i++
			if i < len(p.src) && p.src[i] == '>' {
				i++
			}
			break
		}
		ns := i
		for i < len(p.src) && isNameChar(p.src[i]) {
			i++
		}
		if i == ns {
			i++ // skip a junk byte so we always make progress
			continue
		}
		name := strings.ToLower(string(p.src[ns:i]))
		for i < len(p.src) && isSpace(p.src[i]) {
			i++
		}
		val := ""
		if i < len(p.src) && p.src[i] == '=' {
			i++
			for i < len(p.src) && isSpace(p.src[i]) {
				i++
			}
			if i < len(p.src) && (p.src[i] == '"' || p.src[i] == '\'') {
				q := p.src[i]
				i++
				vs := i
				for i < len(p.src) && p.src[i] != q {
					i++
				}
				val = DecodeEntities(string(p.src[vs:i]))
				if i < len(p.src) {
					i++
				}
			} else {
				vs := i
				for i < len(p.src) && !isSpace(p.src[i]) && p.src[i] != '>' {
					i++
				}
				val = DecodeEntities(string(p.src[vs:i]))
			}
		}
		if attrCount < MaxAttrCount && len(name) <= 64 {
			if len(val) > MaxAttrLen {
				val = val[:MaxAttrLen]
			}
			node.Attrs = append(node.Attrs, Attr{Name: name, Value: val})
			attrCount++
		} else {
			p.doc.Truncated = true
		}
	}
	p.pos = i

	// Implicit closes (the HTML "auto-close" rules that matter here). A new
	// sibling of a cell/item/entry closes the previous one, and a block-level
	// start tag closes an open <p>. Only the top of stack is inspected, so
	// real nesting (tr > th) is never destroyed.
	if len(p.stack) > 1 {
		top := p.stack[len(p.stack)-1].Tag
		closeTop := false
		switch tag {
		case "li":
			closeTop = top == "li"
		case "td", "th":
			closeTop = top == "td" || top == "th"
		case "tr":
			closeTop = top == "tr"
		case "dt", "dd":
			closeTop = top == "dt" || top == "dd"
		case "html", "body":
			closeTop = top == tag
		default:
			if BlockElement(tag) && top == "p" {
				closeTop = true
			}
		}
		if closeTop {
			p.stack = p.stack[:len(p.stack)-1]
		}
	}

	if VoidElement(tag) {
		p.top().Children = append(p.top().Children, node)
		p.doc.Nodes++
		return true
	}
	if len(p.stack) >= MaxDepth {
		// Depth cap: the element's content still lands in the enclosing
		// block in document order (text is never dropped), and the
		// truncation is visible on the Document.
		p.top().Children = append(p.top().Children, node)
		p.doc.Nodes++
		p.doc.Truncated = true
		return true
	}
	p.push(node)
	return true
}

func isSpace(c byte) bool { return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f' }

func isNameStart(c byte) bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}

func isNameChar(c byte) bool {
	return isNameStart(c) || (c >= '0' && c <= '9') || c == '-' || c == '_' || c == ':'
}

func indexByteFrom(b []byte, from int, want byte) int {
	for i := from; i < len(b); i++ {
		if b[i] == want {
			return i
		}
	}
	return -1
}

func indexFrom(b []byte, from int, want string) int {
	if from < 0 || from > len(b) {
		return -1
	}
	rel := strings.Index(string(b[from:]), want)
	if rel < 0 {
		return -1
	}
	return from + rel
}

// DecodeEntities decodes the common HTML entities and numeric references.
// Unknown entities are kept verbatim so nothing is silently lost.
func DecodeEntities(s string) string {
	if !strings.ContainsRune(s, '&') {
		return s
	}
	var b strings.Builder
	b.Grow(len(s))
	for i := 0; i < len(s); i++ {
		if s[i] != '&' {
			b.WriteByte(s[i])
			continue
		}
		semi := -1
		for j := i + 1; j < len(s) && j < i+12; j++ {
			if s[j] == ';' {
				semi = j
				break
			}
			if s[j] == '&' || s[j] == '<' || s[j] == ' ' {
				break
			}
		}
		// Named entities may appear without their semicolon; try the
		// longest matching name at this position before giving up.
		if semi < 0 {
			best := ""
			for _, e := range namedEntities {
				bare := strings.TrimSuffix(e.name, ";")
				if strings.HasPrefix(s[i:], bare) && len(bare) > len(best) {
					best = bare
				}
			}
			if best == "" {
				b.WriteByte('&')
				continue
			}
			key := best
			if strings.HasPrefix(best, "#") {
				if r, ok := decodeNumericRef(best[1:]); ok {
					b.WriteRune(r)
					i += len(best) - 1
					continue
				}
			}
			b.WriteString(entityTable[key])
			i += len(best) - 1
			continue
		}
		name := s[i+1 : semi]
		if strings.HasPrefix(name, "#") {
			if r, ok := decodeNumericRef(name[1:]); ok {
				b.WriteRune(r)
				i = semi
				continue
			}
			b.WriteByte('&')
			continue
		}
		v, ok := entityTable[strings.ToLower(name)]
		if !ok {
			b.WriteByte('&')
			continue
		}
		b.WriteString(v)
		i = semi
	}
	return b.String()
}

func decodeNumericRef(body string) (rune, bool) {
	base := 10
	if strings.HasPrefix(body, "x") || strings.HasPrefix(body, "X") {
		base = 16
		body = body[1:]
	}
	if body == "" {
		return 0, false
	}
	var v int64
	for i := 0; i < len(body); i++ {
		var d int64
		c := body[i]
		switch {
		case c >= '0' && c <= '9':
			d = int64(c - '0')
		case base == 16 && c >= 'a' && c <= 'f':
			d = int64(c-'a') + 10
		case base == 16 && c >= 'A' && c <= 'F':
			d = int64(c-'A') + 10
		default:
			return 0, false
		}
		v = v*int64(base) + d
		if v > 0x10FFFF {
			return 0xFFFD, true
		}
	}
	if v == 0 {
		return 0xFFFD, true
	}
	return rune(v), true
}

type entity struct {
	name  string
	value string
}

var entityTable = map[string]string{
	"amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
	"nbsp": "\u00a0", "copy": "\u00a9", "reg": "\u00ae", "hellip": "\u2026",
	"mdash": "\u2014", "ndash": "\u2013", "lsquo": "\u2018", "rsquo": "\u2019",
	"ldquo": "\u201c", "rdquo": "\u201d", "times": "\u00d7", "middot": "\u00b7",
	"bull": "\u2022", "deg": "\u00b0", "eacute": "\u00e9", "uuml": "\u00fc",
}

var namedEntities = []entity{
	{"&#39;", "'"}, {"&#34;", "\""},
	{"&amp;", "&"}, {"&lt;", "<"}, {"&gt;", ">"}, {"&quot;", "\""}, {"&apos;", "'"},
	{"&nbsp;", "\u00a0"}, {"&copy;", "\u00a9"}, {"&hellip;", "\u2026"},
	{"&mdash;", "\u2014"}, {"&ndash;", "\u2013"}, {"&middot;", "\u00b7"},
}
