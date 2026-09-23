package gitread

// Text diff of tracked files: HEAD blob vs current worktree bytes, one
// change region per file (common prefix/suffix trimmed, no context lines —
// a TUI view, not a patch). Tracked = in HEAD or in the index, so a staged
// addition (HEAD side empty) still shows.

import (
	"bytes"
	"sort"
)

// DiffLine is one rendered diff line.
type DiffLine struct {
	Op   byte // '-' removed, '+' added
	Text string
}

// FileDiff is one file's change region plus its @@ header.
type FileDiff struct {
	Path   string
	Header string // "@@ -a,b +c,d @@"
	Lines  []DiffLine
}

// splitLines splits on \n and drops the trailing empty element.
func splitLines(b []byte) []string {
	if len(b) == 0 {
		return nil
	}
	s := string(b)
	if len(s) > 0 && s[len(s)-1] == '\n' {
		s = s[:len(s)-1]
	}
	if s == "" {
		return nil
	}
	out := []string{}
	start := 0
	for i := 0; i < len(s); i++ {
		if s[i] == '\n' {
			out = append(out, s[start:i])
			start = i + 1
		}
	}
	return append(out, s[start:])
}

// Diff returns one FileDiff per tracked path whose content differs from
// HEAD, sorted by path.
func (r *Repo) Diff() ([]FileDiff, error) {
	head, err := r.headFiles()
	if err != nil {
		return nil, err
	}
	// Union of tracked paths: HEAD files plus index entries (staged adds).
	tracked := map[string]bool{}
	for p := range head {
		tracked[p] = true
	}
	if raw, err := r.FS.ReadFile(r.GitDir + "/index"); err == nil {
		if ents, err := ParseIndex(raw); err == nil {
			for _, e := range ents {
				tracked[e.Path] = true
			}
		}
	}
	paths := make([]string, 0, len(tracked))
	for p := range tracked {
		paths = append(paths, p)
	}
	sort.Strings(paths)

	var out []FileDiff
	for _, p := range paths {
		var oldB []byte
		if id, inHead := head[p]; inHead {
			if o, ok := r.Get(id); ok && o.Type == ObjBlob {
				oldB = o.Data
			}
		}
		newB, readErr := r.FS.ReadFile(r.Root + "/" + p)
		if readErr != nil {
			newB = nil // deleted in the worktree
		}
		if bytes.Equal(oldB, newB) {
			continue
		}
		out = append(out, makeFileDiff(p, oldB, newB))
	}
	return out, nil
}

func makeFileDiff(path string, oldB, newB []byte) FileDiff {
	a := splitLines(oldB)
	b := splitLines(newB)
	// trim common prefix
	p := 0
	for p < len(a) && p < len(b) && a[p] == b[p] {
		p++
	}
	// trim common suffix
	s := 0
	for s < len(a)-p && s < len(b)-p && a[len(a)-1-s] == b[len(b)-1-s] {
		s++
	}
	oldMid := a[p : len(a)-s]
	newMid := b[p : len(b)-s]
	fd := FileDiff{Path: path, Header: hunkHeader(p, len(oldMid), len(newMid))}
	for _, ln := range oldMid {
		fd.Lines = append(fd.Lines, DiffLine{'-', ln})
	}
	for _, ln := range newMid {
		fd.Lines = append(fd.Lines, DiffLine{'+', ln})
	}
	return fd
}

// hunkHeader is git's @@ convention: start is 1-based when the side has
// lines, else the line count before the insertion point.
func hunkHeader(prefix, oldN, newN int) string {
	oldStart := prefix
	if oldN > 0 {
		oldStart = prefix + 1
	}
	newStart := prefix
	if newN > 0 {
		newStart = prefix + 1
	}
	return "@@ -" + itoa(oldStart) + "," + itoa(oldN) +
		" +" + itoa(newStart) + "," + itoa(newN) + " @@"
}

func itoa(v int) string {
	if v == 0 {
		return "0"
	}
	neg := v < 0
	if neg {
		v = -v
	}
	var buf [20]byte
	i := len(buf)
	for v > 0 {
		i--
		buf[i] = byte('0' + v%10)
		v /= 10
	}
	if neg {
		i--
		buf[i] = '-'
	}
	return string(buf[i:])
}
