package main

type sshReader struct {
	b   []byte
	pos int
}

func (r *sshReader) remaining() int { return len(r.b) - r.pos }

func (r *sshReader) byte() (byte, bool) {
	if r.remaining() < 1 {
		return 0, false
	}
	v := r.b[r.pos]
	r.pos++
	return v, true
}

func (r *sshReader) boolVal() (bool, bool) {
	v, ok := r.byte()
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

func (r *sshReader) u32() (uint32, bool) {
	if r.remaining() < 4 {
		return 0, false
	}
	v := uint32(r.b[r.pos])<<24 | uint32(r.b[r.pos+1])<<16 | uint32(r.b[r.pos+2])<<8 | uint32(r.b[r.pos+3])
	r.pos += 4
	return v, true
}

func (r *sshReader) str() ([]byte, bool) {
	n, ok := r.u32()
	if !ok || int(n) > r.remaining() {
		return nil, false
	}
	s := r.b[r.pos : r.pos+int(n)]
	r.pos += int(n)
	return s, true
}

func (r *sshReader) strUTF8() (string, bool) {
	s, ok := r.str()
	if !ok {
		return "", false
	}
	return string(s), true
}

func (r *sshReader) nameList() ([]string, bool) {
	raw, ok := r.str()
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

type sshWriter struct {
	b []byte
}

func (w *sshWriter) byte(v byte) { w.b = append(w.b, v) }

func (w *sshWriter) boolVal(v bool) {
	if v {
		w.b = append(w.b, 1)
	} else {
		w.b = append(w.b, 0)
	}
}

func (w *sshWriter) u32(v uint32) {
	w.b = append(w.b, byte(v>>24), byte(v>>16), byte(v>>8), byte(v))
}

func (w *sshWriter) str(s []byte) {
	w.u32(uint32(len(s)))
	w.b = append(w.b, s...)
}

func (w *sshWriter) strS(s string) { w.str([]byte(s)) }

func (w *sshWriter) nameList(names []string) {
	if len(names) == 0 {
		w.str(nil)
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
	w.str(buf)
}

func (w *sshWriter) raw(s []byte) { w.b = append(w.b, s...) }

func containsName(list []string, want string) bool {
	for _, s := range list {
		if s == want {
			return true
		}
	}
	return false
}
