package main

// This file is intentionally untagged. These types cross pulse's host/guest
// seam: the guest poller (snapshot.go) fills a snapshot, the host stub
// (snapshot_host.go) fakes one, and the pure derive layer (derive.go) reads
// one. While they lived in model.go under `//go:build virelai || pulse`, a
// tagless build paired the host stub with no declarations at all and
// `go test ./...` failed with "undefined: snapshot" (M72c follow-up, #1611).

// procInfo is one display-ready process row.
type procInfo struct {
	pid   uint64
	name  string
	state uint64
}

// snapshot is one 1 Hz poll of everything the UI shows. On the guest it is
// filled from real syscalls (snapshot.go); on the host it is canned
// (snapshot_host.go) so the model, update and view stay testable.
type snapshot struct {
	uptimeNs int64
	procs    []procInfo
	dataFree int64
	espFree  int64
	tcpOpen  bool
	taken    bool
}

// Sort columns for the process table.
type sortCol int

const (
	sortPID sortCol = iota
	sortName
	sortState
)

func (c sortCol) name() string {
	switch c {
	case sortPID:
		return "pid"
	case sortName:
		return "name"
	case sortState:
		return "state"
	}
	return "?"
}
