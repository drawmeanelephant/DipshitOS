// Strict DER reading (view-based: no copies, everything slices the input).
// The rules that matter: no indefinite lengths, minimal-length encodings
// only, exactly one top-level element, canonical BOOLEAN (0x00/0xff), and
// unsigned INTEGERs that reject negatives and non-minimal encodings. A
// malformed input returns an error, never a panic (the fuzz posture the Zig
// client pins in its x509 tests).

package tls

// derTag values used by the X.509 parser.
const (
	derTagBoolean     = 0x01
	derTagInteger     = 0x02
	derTagBitString   = 0x03
	derTagOctetString = 0x04
	derTagNull        = 0x05
	derTagOID         = 0x06
	derTagUTF8String  = 0x0c
	derTagPrintable   = 0x13
	derTagT61         = 0x14
	derTagIA5         = 0x16
	derTagUTCTime     = 0x17
	derTagGeneralized = 0x18
	derTagSequence    = 0x30
	derTagSet         = 0x31
)

// derElement is one parsed TLV: tag, content, and raw (the full element
// including the header). Content slices the caller's buffer.
type derElement struct {
	tag     byte
	content []byte
	raw     []byte
}

// isCtx reports whether the element has context-class tag number t
// (constructed or primitive).
func (e derElement) isCtx(t byte) bool {
	return e.tag == 0x80|t || e.tag == 0xa0|t
}

// derReader walks a buffer of DER elements.
type derReader struct {
	buf []byte
	pos int
}

func newDERReader(buf []byte) derReader { return derReader{buf: buf} }

func (r *derReader) atEnd() bool { return r.pos >= len(r.buf) }

// next parses one element.
func (r *derReader) next() (derElement, error) {
	start := r.pos
	if r.pos >= len(r.buf) {
		return derElement{}, errDER
	}
	tag := r.buf[r.pos]
	r.pos++
	// Length: short form, or long form with a minimal byte count. Indefinite
	// (0x80) is DER-forbidden.
	if r.pos >= len(r.buf) {
		return derElement{}, errDER
	}
	l0 := r.buf[r.pos]
	r.pos++
	var length int
	switch {
	case l0 < 0x80:
		length = int(l0)
	case l0 == 0x80:
		return derElement{}, errDER
	default:
		n := int(l0 & 0x7f)
		if n > 4 || r.pos+n > len(r.buf) {
			return derElement{}, errDER
		}
		if r.buf[r.pos] == 0 {
			return derElement{}, errDER // non-minimal long form
		}
		for i := 0; i < n; i++ {
			length = length<<8 | int(r.buf[r.pos+i])
		}
		r.pos += n
	}
	if length < 0 || r.pos+length > len(r.buf) {
		return derElement{}, errDER
	}
	elem := derElement{
		tag:     tag,
		content: r.buf[r.pos : r.pos+length],
		raw:     r.buf[start : r.pos+length],
	}
	r.pos += length
	return elem, nil
}

// expect parses one element and requires its tag.
func (r *derReader) expect(tag byte) (derElement, error) {
	e, err := r.next()
	if err != nil {
		return e, err
	}
	if e.tag != tag {
		return e, errDER
	}
	return e, nil
}

// derInteger returns the unsigned value bytes of an INTEGER element,
// rejecting negatives and non-minimal encodings.
func derInteger(e derElement) ([]byte, error) {
	if e.tag != derTagInteger {
		return nil, errDER
	}
	c := e.content
	if len(c) == 0 {
		return nil, errDER
	}
	if c[0]&0x80 != 0 {
		return nil, errDER // negative
	}
	if len(c) > 1 && c[0] == 0 {
		// A leading zero is legal only when the next octet has bit 8 set.
		if c[1]&0x80 == 0 {
			return nil, errDER
		}
		return c[1:], nil
	}
	return c, nil
}

// derIntegerU64 reads a small non-negative INTEGER.
func derIntegerU64(e derElement) (uint64, error) {
	v, err := derInteger(e)
	if err != nil {
		return 0, err
	}
	if len(v) > 8 {
		return 0, errDER
	}
	var out uint64
	for _, b := range v {
		out = out<<8 | uint64(b)
	}
	return out, nil
}

// derBoolean requires the canonical encoding.
func derBoolean(e derElement) (bool, error) {
	if e.tag != derTagBoolean || len(e.content) != 1 {
		return false, errDER
	}
	switch e.content[0] {
	case 0x00:
		return false, nil
	case 0xff:
		return true, nil
	}
	return false, errDER
}

// derBitString returns the payload of a BIT STRING and its unused-bit count.
// SPKI and signatureValue BIT STRINGs must have an unused count of zero; key
// Usage legally does not, so the count is the caller's check.
func derBitString(e derElement) ([]byte, byte, error) {
	if e.tag != derTagBitString || len(e.content) < 1 {
		return nil, 0, errDER
	}
	if e.content[0] > 7 {
		return nil, 0, errDER
	}
	return e.content[1:], e.content[0], nil
}

// derOIDBytes validates and returns the OID content.
func derOIDBytes(e derElement) ([]byte, error) {
	if e.tag != derTagOID || len(e.content) < 1 {
		return nil, errDER
	}
	return e.content, nil
}

// derEqlOid is an exact content comparison.
func derEqlOid(a, b []byte) bool {
	if len(a) != len(b) {
		return false
	}
	var v byte
	for i := range a {
		v |= a[i] ^ b[i]
	}
	return v == 0
}

// derParseTime parses UTCTime ("YYMMDDHHMMSSZ") and GeneralizedTime
// ("YYYYMMDDHHMMSSZ") into unix seconds. Fractional and offset forms are
// refused (the fixtures and every chain this client sees use Z form).
func derParseTime(e derElement) (int64, error) {
	s := e.content
	var year int
	rest := s
	switch e.tag {
	case derTagUTCTime:
		if len(s) != 13 || s[12] != 'Z' {
			return 0, errDER
		}
		y := int(s[0]-'0')*10 + int(s[1]-'0')
		if y >= 50 {
			year = 1900 + y
		} else {
			year = 2000 + y
		}
		rest = s[2:]
	case derTagGeneralized:
		if len(s) != 15 || s[14] != 'Z' {
			return 0, errDER
		}
		year = int(s[0]-'0')*1000 + int(s[1]-'0')*100 + int(s[2]-'0')*10 + int(s[3]-'0')
		rest = s[4:]
	default:
		return 0, errDER
	}
	if len(rest) != 11 {
		return 0, errDER
	}
	num := func(i int) int { return int(rest[i]-'0')*10 + int(rest[i+1]-'0') }
	month, day, hour, minute, sec := num(0), num(2), num(4), num(6), num(8)
	if rest[10] != 'Z' || month < 1 || month > 12 || day < 1 || day > 31 || hour > 23 || minute > 59 || sec > 59 {
		return 0, errDER
	}
	return unixSeconds(year, month, day, hour, minute, sec), nil
}

// unixSeconds does days-since-epoch arithmetic (proleptic Gregorian).
func unixSeconds(year, month, day, hour, minute, sec int) int64 {
	// Days from civil (Howard Hinnant's algorithm).
	y := int64(year)
	if month <= 2 {
		y--
	}
	era := y / 400
	yoe := y - era*400
	mp := int64((month + 9) % 12)
	doy := (153*mp+2)/5 + int64(day) - 1
	doe := yoe*365 + yoe/4 - yoe/100 + doy
	days := era*146097 + doe - 719468
	return days*86400 + int64(hour)*3600 + int64(minute)*60 + int64(sec)
}
