package sshlib

func ParseHex(s string) ([]byte, bool) {
	if len(s)%2 != 0 {
		return nil, false
	}
	out := make([]byte, len(s)/2)
	for i := 0; i < len(out); i++ {
		hi, ok := nibble(s[2*i])
		if !ok {
			return nil, false
		}
		lo, ok := nibble(s[2*i+1])
		if !ok {
			return nil, false
		}
		out[i] = hi<<4 | lo
	}
	return out, true
}

func ParseHex32(s string) ([32]byte, bool) {
	var out [32]byte
	b, ok := ParseHex(s)
	if !ok || len(b) != 32 {
		return out, false
	}
	copy(out[:], b)
	return out, true
}

func nibble(c byte) (byte, bool) {
	switch {
	case c >= '0' && c <= '9':
		return c - '0', true
	case c >= 'a' && c <= 'f':
		return c - 'a' + 10, true
	case c >= 'A' && c <= 'F':
		return c - 'A' + 10, true
	}
	return 0, false
}

func EncodeHex(b []byte) string {
	const digits = "0123456789abcdef"
	out := make([]byte, len(b)*2)
	for i, v := range b {
		out[i*2] = digits[v>>4]
		out[i*2+1] = digits[v&0xf]
	}
	return string(out)
}

func Wipe(b []byte) {
	for i := range b {
		b[i] = 0
	}
}
