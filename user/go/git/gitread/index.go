package gitread

// .git/index reader (format version 2/3; v4's path-prefix compression is
// refused honestly — git's default remains v2). Layout, fixed offsets:
//
//	12-byte header: "DIRC" u32ver u32count
//	entry (v2): ctime8 mtime8 dev4 ino4 mode4 uid4 gid4 size4 (40)
//	            sha1[20] flags2 (62) name[nameLen] NUL pad -> 8-byte align
//	entry (v3): ... flags2 extFlags2 (64) name...
//	flags: bits 0-11 nameLen, bits 12-13 stage, bit 14 extended.
//	20-byte SHA-1 trailer after extensions (ignored: verified end-to-end
//	by the in-guest gate against a real `git add` index).

import "encoding/binary"

// IndexEntry is one staged path.
type IndexEntry struct {
	Path  string
	Sha   [20]byte
	Stage int // 0 = normal; 1-3 = merge conflict stages
}

// ParseIndex decodes a v2/v3 index.
func ParseIndex(data []byte) ([]IndexEntry, error) {
	if len(data) < 12 || string(data[0:4]) != "DIRC" {
		return nil, fsErr("index: bad magic")
	}
	ver := binary.BigEndian.Uint32(data[4:8])
	if ver != 2 && ver != 3 {
		return nil, fsErr("index: unsupported version")
	}
	count := binary.BigEndian.Uint32(data[8:12])
	pos := 12
	out := make([]IndexEntry, 0, count)
	for i := uint32(0); i < count; i++ {
		base := 62
		if ver >= 3 {
			base = 64
		}
		if pos+base > len(data) {
			return nil, fsErr("index: truncated entry")
		}
		flags := binary.BigEndian.Uint16(data[pos+60 : pos+62])
		nameLen := int(flags & 0x0FFF)
		stage := int((flags >> 12) & 3)
		if nameLen == 0x0FFF {
			return nil, fsErr("index: oversize name unsupported")
		}
		nameEnd := pos + base + nameLen
		if nameEnd > len(data) {
			return nil, fsErr("index: truncated name")
		}
		var e IndexEntry
		copy(e.Sha[:], data[pos+40:pos+60])
		e.Path = string(data[pos+base : nameEnd])
		e.Stage = stage
		out = append(out, e)
		// Advance: the ENTRY (base + name + NUL) is padded to a multiple of
		// 8 relative to the entry's own start — git's first entry sits at
		// file offset 12, so file-offset alignment would drift by 4.
		next := pos + ((base + nameLen + 1 + 7) &^ 7)
		if next <= pos {
			return nil, fsErr("index: stuck")
		}
		pos = next
	}
	return out, nil
}
