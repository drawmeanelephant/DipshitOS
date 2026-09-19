package webrender

// Theme colors — the VirelaiOS desktop tokens the rest of the userland uses
// (user/src/lib/ui/theme.zig, dark scheme). The browser chrome and the page
// default share them so the window reads as one surface.
const (
	ColorPageBg    uint32 = 0x182026
	ColorSurface   uint32 = 0x222d35
	ColorText      uint32 = 0xe6edf3
	ColorMuted     uint32 = 0x8b98a5
	ColorAccent    uint32 = 0x3b82f6
	ColorRule      uint32 = 0x2e3a44
	ColorChromeBg  uint32 = 0x11171c
	ColorChromeInk uint32 = 0xe6edf3
	ColorError     uint32 = 0xef4444
	ColorOK        uint32 = 0x3fb950
)

// Style is the resolved presentation of one element. There is exactly one
// source of style in this renderer: the compiled-in table below. A page
// cannot change its own presentation (ADR 0028 D2) — there is no CSS parser
// and no cascade, by design and permanently.
type Style struct {
	Size         int    // font scale: 1 => 8px, 2 => 16px
	Mono         bool   // fixed-width face
	Bold         bool   // synthetic bold (double strike, as in the Zig renderer)
	Align        int    // 0 left, 1 center
	MarginTop    int    // px before the block
	MarginBottom int    // px after the block
	Indent       int    // px of left indent applied to the block
	Color        uint32 // 0 => default text color
	Bg           uint32 // 0 => no background
	Decoration   uint8  // decRule draws an underline, decBar a left accent bar
	Skip         bool   // never rendered (head/script/style/...)
}

// Decoration kinds.
const (
	decNone uint8 = iota
	decRule
	decBar
)

// DefaultStyle is the body text style.
var DefaultStyle = Style{Size: 1, Color: ColorText, MarginBottom: 4}

// LinkStyle is the <a> style.
var LinkStyle = Style{Size: 1, Color: ColorAccent, Decoration: decRule, MarginBottom: 4}

// StyleFor returns the UA style for a tag. Unknown tags render as inline
// content in the enclosing block — they never vanish.
func StyleFor(tag string) Style {
	switch tag {
	case "html", "body", "document":
		return Style{Size: 1, Color: ColorText}
	case "h1":
		return Style{Size: 2, Bold: true, Color: ColorText, MarginTop: 10, MarginBottom: 8}
	case "h2":
		return Style{Size: 2, Bold: true, Color: ColorText, MarginTop: 8, MarginBottom: 6}
	case "h3":
		return Style{Size: 1, Bold: true, Color: ColorText, MarginTop: 8, MarginBottom: 5}
	case "h4", "h5", "h6":
		return Style{Size: 1, Bold: true, Color: ColorMuted, MarginTop: 6, MarginBottom: 4}
	case "p":
		return Style{Size: 1, Color: ColorText, MarginBottom: 8}
	case "div", "section", "article", "header", "footer", "main", "nav", "aside", "figure":
		return Style{Size: 1, Color: ColorText, MarginBottom: 4}
	case "figcaption":
		return Style{Size: 1, Color: ColorMuted, MarginBottom: 6}
	case "ul", "ol":
		return Style{Size: 1, Color: ColorText, Indent: 8, MarginTop: 2, MarginBottom: 8}
	case "li":
		return Style{Size: 1, Color: ColorText, Indent: 12, MarginBottom: 3}
	case "dl":
		return Style{Size: 1, Color: ColorText, MarginBottom: 8}
	case "dt":
		return Style{Size: 1, Bold: true, Color: ColorText, MarginBottom: 2}
	case "dd":
		return Style{Size: 1, Color: ColorMuted, Indent: 12, MarginBottom: 4}
	case "pre":
		return Style{Size: 1, Mono: true, Color: ColorText, Bg: ColorSurface, MarginTop: 4, MarginBottom: 8, Indent: 6}
	case "code", "kbd", "samp", "tt":
		return Style{Size: 1, Mono: true, Color: ColorText, Bg: ColorSurface}
	case "blockquote":
		return Style{Size: 1, Color: ColorMuted, Indent: 14, Decoration: decBar, MarginTop: 4, MarginBottom: 8}
	case "hr":
		return Style{Size: 1, Color: ColorRule, MarginTop: 8, MarginBottom: 8}
	case "a":
		return LinkStyle
	case "strong", "b":
		return Style{Size: 1, Bold: true, Color: ColorText}
	case "em", "i":
		return Style{Size: 1, Color: ColorAccent}
	case "small":
		return Style{Size: 1, Color: ColorMuted}
	case "table":
		return Style{Size: 1, Color: ColorText, MarginTop: 4, MarginBottom: 8}
	case "thead", "tbody", "tr":
		return Style{Size: 1, Color: ColorText}
	case "th":
		return Style{Size: 1, Bold: true, Color: ColorText}
	case "td":
		return Style{Size: 1, Color: ColorText}
	case "img":
		return Style{Size: 1, Color: ColorMuted, MarginTop: 4, MarginBottom: 8}
	case "form":
		return Style{Size: 1, Color: ColorText, MarginTop: 4, MarginBottom: 8}
	case "fieldset":
		return Style{Size: 1, Color: ColorText, MarginTop: 6, MarginBottom: 8, Indent: 4}
	case "legend":
		return Style{Size: 1, Bold: true, Color: ColorText, MarginBottom: 4}
	case "label":
		return Style{Size: 1, Color: ColorText}
	case "input", "textarea", "select", "button":
		return Style{Size: 1, Color: ColorText, Bg: ColorSurface, MarginBottom: 4}
	case "address":
		return Style{Size: 1, Color: ColorMuted, MarginTop: 4, MarginBottom: 8}
	case "script", "style", "head", "title", "meta", "link", "template", "noscript":
		return Style{Skip: true}
	}
	return Style{Size: 1, Color: ColorText}
}
