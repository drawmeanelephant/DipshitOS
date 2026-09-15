// Listing helpers for the M58a Go file manager (issue #1305).
//
// Path join/parent, entry labels, and the "is this the known share file?"
// check are plain functions so the host `go test` run can pin them without
// a guest syscall. The 16-entry dir_list window and 64-byte path cap are
// the kernel's (file_table.max_path_len / handle_dir_list).
package main

import "virelai/vi"

const (
	maxPath   = 64
	rootPath  = "/host"
	knownName = "KNOWN.TXT"
)

// joinPath appends name under dir. It refuses ".." and a result longer
// than the kernel path cap, so a hostile name cannot walk off the share
// or trip ENAMETOOLONG on the next dir_list.
func joinPath(dir, name string) (string, bool) {
	if name == "" || name == "." || name == ".." {
		return "", false
	}
	for i := 0; i < len(name); i++ {
		if name[i] == '/' {
			return "", false
		}
	}
	if dir == "" {
		dir = rootPath
	}
	if len(dir) > 0 && dir[len(dir)-1] == '/' {
		dir = dir[:len(dir)-1]
	}
	out := dir + "/" + name
	if len(out) > maxPath {
		return "", false
	}
	return out, true
}

// parentPath walks one directory up, stopping at the host-share root.
func parentPath(path string) string {
	if path == "" || path == rootPath || path == "/" {
		return rootPath
	}
	if len(path) > 0 && path[len(path)-1] == '/' {
		path = path[:len(path)-1]
	}
	slash := -1
	for i := 0; i < len(path); i++ {
		if path[i] == '/' {
			slash = i
		}
	}
	if slash <= 0 {
		return rootPath
	}
	out := path[:slash]
	if out == "" || out == "/host" {
		return rootPath
	}
	return out
}

// entryLabel is what the list widget shows: directories get a trailing slash.
func entryLabel(e vi.DirEntry) string {
	n := e.NameString()
	if n == "" {
		return n
	}
	if e.Dir() {
		return n + "/"
	}
	return n
}

// containsName reports whether the first n entries include name.
func containsName(entries []vi.DirEntry, n int, name string) bool {
	if n > len(entries) {
		n = len(entries)
	}
	for i := 0; i < n; i++ {
		if entries[i].NameString() == name {
			return true
		}
	}
	return false
}

// labelsOf builds the list-widget item slice for the first n entries.
func labelsOf(entries []vi.DirEntry, n int) []string {
	if n > len(entries) {
		n = len(entries)
	}
	if n <= 0 {
		return nil
	}
	out := make([]string, n)
	for i := 0; i < n; i++ {
		out[i] = entryLabel(entries[i])
	}
	return out
}
