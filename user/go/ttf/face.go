package ttf

// The ergonomic face the renderer consumes: glyph id -> coverage mask +
// advance, behind a bounded cache.
//
// The cache is a fixed-capacity ring with a key index. Capacity is a project
// decision, not a growth curve: a page of text at two sizes touches a few
// hundred distinct (glyph, size) pairs, and a bounded cache is the only kind a
// 512x384 guest window can afford. Eviction is FIFO over the ring — simple,
// deterministic, and impossible to get wrong.

// defaultCacheEntries bounds the glyph cache. 256 entries is comfortably more
// than one screenful of text at two sizes.
const defaultCacheEntries = 256

type cacheKey struct {
	gid uint16
	px  uint8
}

type cacheVal struct {
	mask *Mask
	adv  int
}

type glyphCache struct {
	keys  []cacheKey
	vals  []cacheVal
	valid []bool
	index map[cacheKey]int
	next  int
}

func newGlyphCache(n int) *glyphCache {
	if n < 1 {
		n = 1
	}
	return &glyphCache{
		keys:  make([]cacheKey, n),
		vals:  make([]cacheVal, n),
		valid: make([]bool, n),
		index: make(map[cacheKey]int, n),
	}
}

func (c *glyphCache) get(k cacheKey) (cacheVal, bool) {
	if c == nil {
		return cacheVal{}, false
	}
	if i, ok := c.index[k]; ok && c.valid[i] && c.keys[i] == k {
		return c.vals[i], true
	}
	return cacheVal{}, false
}

func (c *glyphCache) put(k cacheKey, v cacheVal) {
	if c == nil {
		return
	}
	if i, ok := c.index[k]; ok && c.valid[i] && c.keys[i] == k {
		c.vals[i] = v
		return
	}
	i := c.next
	c.next = (c.next + 1) % len(c.keys)
	if c.valid[i] {
		delete(c.index, c.keys[i])
	}
	c.keys[i] = k
	c.vals[i] = v
	c.valid[i] = true
	c.index[k] = i
}

// Glyph rasterizes glyph gid at pixel size px and returns its coverage mask
// and its pixel advance. px is clamped into [1, maxRasterPx]; gid outside the
// font is ErrNoGlyph.
//
// A glyph whose outline is malformed returns the error together with the
// advance width it would have had, so a renderer can keep the line moving
// instead of dropping the character.
func (f *Face) Glyph(gid uint16, px int) (*Mask, int, error) {
	adv := f.AdvanceGIDPx(gid, px)
	if int(gid) >= f.numGlyphs {
		return nil, 0, ErrNoGlyph
	}
	if px < 1 {
		return &Mask{}, 0, nil
	}
	if px > maxRasterPx {
		px = maxRasterPx
	}
	key := cacheKey{gid: gid, px: uint8(px)}
	if v, ok := f.cache.get(key); ok {
		return v.mask, v.adv, nil
	}
	contours, err := f.glyphContours(gid)
	if err != nil {
		return nil, adv, err
	}
	scale := float64(px) / float64(f.unitsPerEm)
	m := rasterize(flattenContours(contours, scale, flatTolerance))
	f.cache.put(key, cacheVal{mask: m, adv: adv})
	return m, adv, nil
}

// AdvanceGIDPx is GlyphAdvanceUPEM scaled to pixels at size px.
func (f *Face) AdvanceGIDPx(gid uint16, px int) int {
	if px <= 0 {
		return 0
	}
	return scaleUPEM(f.GlyphAdvanceUPEM(gid), px, f.unitsPerEm)
}

// Rasterize is Glyph by rune: the glyph the cmap resolves to, rasterized at px.
func (f *Face) Rasterize(r rune, px int) (*Mask, error) {
	m, _, err := f.Glyph(f.GlyphIndex(r), px)
	return m, err
}

// CacheLen is the number of entries the glyph cache holds (a fixed bound).
func (f *Face) CacheLen() int {
	if f.cache == nil {
		return 0
	}
	return len(f.cache.keys)
}
