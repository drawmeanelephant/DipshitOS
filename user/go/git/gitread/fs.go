package gitread

// The reader talks to a filesystem through FS so the same code runs over
// the guest share (vi syscalls) and over a host temp dir in tests (osfs_test.go).
// M74b #1645: the TUI opens a repository at a path; nothing in the reader
// assumes a kernel.

import "virelai/vi"

// DirInfo is one directory entry, reduced to what the reader needs.
type DirInfo struct {
	Name  string
	IsDir bool
}

// FS is the read-only surface gitread needs: whole-file reads and one-level
// directory listings.
type FS interface {
	// ReadFile returns the file's bytes, or an error when it is missing.
	ReadFile(path string) ([]byte, error)
	// ReadDir returns the directory's entries. An error is returned when
	// the directory is missing. Order is unspecified; callers sort.
	ReadDir(path string) ([]DirInfo, error)
}

type fsErr string

func (e fsErr) Error() string { return string(e) }

// VirelaiFS reads through the vi syscall surface (share, DATA partition).
//
// Bounds (measured, deliverable-4 #1645): vi.DirList serves at most
// vi.MaxDirEntries (16) rows per call with no offset, and each row's name
// is vi.DirEntry.Name[32] — a 38-hex git object filename or a 50-byte
// pack filename cannot come back whole, which is why the reader
// constructs object paths from shas (repo.go) and never enumerates
// objects. Files are capped at vi.MaxFileBytes (256 KiB); paths at
// file_table.max_path_len (64).
type VirelaiFS struct{}

// ReadFile reads a whole file (up to vi.MaxFileBytes).
func (VirelaiFS) ReadFile(path string) ([]byte, error) {
	b, rc := vi.ReadFileAll(path, vi.MaxFileBytes)
	if rc < 0 || b == nil {
		return nil, fsErr("read " + path)
	}
	return b, nil
}

// ReadDir lists one directory (up to vi.MaxDirEntries entries).
func (VirelaiFS) ReadDir(path string) ([]DirInfo, error) {
	buf := make([]vi.DirEntry, vi.MaxDirEntries)
	n, rc := vi.DirList(path, buf)
	if rc < 0 {
		return nil, fsErr("list " + path)
	}
	out := make([]DirInfo, 0, n)
	for i := 0; i < n; i++ {
		out = append(out, DirInfo{Name: buf[i].NameString(), IsDir: buf[i].Dir()})
	}
	return out, nil
}
