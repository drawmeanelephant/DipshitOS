package sshlib

type Reader struct {
	B   []byte
	Pos int
}

func (r *Reader) Remaining() int { return len(r.B) - r.Pos }

func (r *Reader) Byte() (byte, bool) {
	if r.Remaining() < 1 {
		return 0, false
	}
	v := r.B[r.Pos]
	r.Pos++
	return v, true
}

func (r *Reader) BoolVal() (bool, bool) {
	v, ok := r.Byte()
	if !ok {
		return false, false
	}
	switch v {
	case 0:
		return false, true
	case 1:
		return true, true
	}
	return false, false
}

func (r *Reader) U32() (uint32, bool) {
	if r.Remaining() < 4 {
		return 0, false
	}
	v := uint32(r.B[r.Pos])<<24 | uint32(r.B[r.Pos+1])<<16 | uint32(r.B[r.Pos+2])<<8 | uint32(r.B[r.Pos+3])
	r.Pos += 4
	return v, true
}

func (r *Reader) Str() ([]byte, bool) {
	n, ok := r.U32()
	if !ok || int(n) > r.Remaining() {
		return nil, false
	}
	s := r.B[r.Pos : r.Pos+int(n)]
	r.Pos += int(n)
	return s, true
}

func (r *Reader) StrUTF8() (string, bool) {
	s, ok := r.Str()
	if !ok {
		return "", false
	}
	return string(s), true
}

func (r *Reader) NameList() ([]string, bool) {
	raw, ok := r.Str()
	if !ok {
		return nil, false
	}
	if len(raw) == 0 {
		return nil, true
	}
	text := string(raw)
	parts := splitComma(text)
	for _, p := range parts {
		if p == "" {
			return nil, false
		}
	}
	return parts, true
}

func splitComma(s string) []string {
	n := 1
	for i := 0; i < len(s); i++ {
		if s[i] == ',' {
			n++
		}
	}
	out := make([]string, 0, n)
	start := 0
	for i := 0; i < len(s); i++ {
		if s[i] == ',' {
			out = append(out, s[start:i])
			start = i + 1
		}
	}
	out = append(out, s[start:])
	return out
}

type Writer struct {
	B []byte
}

func (w *Writer) Byte(v byte) { w.B = append(w.B, v) }

func (w *Writer) BoolVal(v bool) {
	if v {
		w.B = append(w.B, 1)
	} else {
		w.B = append(w.B, 0)
	}
}

func (w *Writer) U32(v uint32) {
	w.B = append(w.B, byte(v>>24), byte(v>>16), byte(v>>8), byte(v))
}

func (w *Writer) Str(s []byte) {
	w.U32(uint32(len(s)))
	w.B = append(w.B, s...)
}

func (w *Writer) StrS(s string) { w.Str([]byte(s)) }

func (w *Writer) NameList(names []string) {
	if len(names) == 0 {
		w.Str(nil)
		return
	}
	n := 0
	for i, s := range names {
		n += len(s)
		if i > 0 {
			n++
		}
	}
	buf := make([]byte, 0, n)
	for i, s := range names {
		if i > 0 {
			buf = append(buf, ',')
		}
		buf = append(buf, s...)
	}
	w.Str(buf)
}

func (w *Writer) Raw(s []byte) { w.B = append(w.B, s...) }

func ContainsName(list []string, want string) bool {
	for _, s := range list {
		if s == want {
			return true
		}
	}
	return false
}
