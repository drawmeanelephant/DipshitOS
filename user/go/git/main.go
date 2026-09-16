package main

import "virelai/vi"

// GOTGIT.ELF — git-over-https clone (issue #1337 / ADR 0029). HTTPS is the
// Zig helper FETCHS.BIN; this process never opens a TCP socket and never
// sends a cleartext GET. No push.

const (
	appName = "GOTGIT.ELF"

	markerStart  = "gotgit: start"
	markerURL    = "gotgit: url "
	markerHelper = "gotgit: helper "
	markerPid    = "gotgit: helper pid="
	markerRefs   = "gotgit: refs "
	markerWant   = "gotgit: want "
	markerPack   = "gotgit: pack objects="
	markerBlob   = "gotgit: blob "
	markerTree   = "gotgit: tree "
	markerCommit = "gotgit: commit "
	markerDelta  = "gotgit: delta"
	markerCheck  = "gotgit: checkout "
	markerOK     = "gotgit OK"
	markerErr    = "gotgit: error "

	maxWrite = 2048

	// file_table MODE_DIR create returns -9 (EEXIST). ADR 0007 maps
	// magnitude 9 to ENXIO; vi has no ErrEXIST.
	errExist = int64(-9)

	// FETCHS.BIN success is exit_status 42 (user/src/fetchs.zig).
	fetchsOK = int64(42)
)

// argvPad keeps the Go sbrk heap from overlapping the kernel's argv+envp
// block (same GOFETCH.ELF fix). GOTGIT's data/BSS last-page tail was 0x330
// with a 2 KiB pad — still short of the 2304-byte argv+envp packing — so
// this is 4 KiB.
var argvPad [4096]byte

func main() {
	argvPad[0] = 1
	vi.ConsoleLine(markerStart)

	url, dest := startArgs()
	vi.ConsoleLine(markerURL + url)
	tgt := classify(url)
	if wouldSendCleartext(tgt) {
		fail("cleartext refused")
		return
	}
	if tgt.Kind != kindHTTPS {
		fail(tgt.Kind)
		return
	}

	if !mkdirAll(dest) {
		fail("mkdir dest")
		return
	}
	gitDir, ok := joinPath(dest, ".git")
	if !ok || !mkdirAll(gitDir) {
		fail("mkdir git")
		return
	}
	if !clone(tgt, dest, gitDir) {
		return
	}
	vi.ConsoleLine(markerOK)
	vi.Exit(0)
}

func startArgs() (url, dest string) {
	args := vi.Args()
	url = "https://10.0.0.2:24541/g.git"
	dest = "/host/G"
	if len(args) > 1 && args[1] == "clone" {
		if len(args) > 2 && args[2] != "" {
			url = args[2]
		}
		if len(args) > 3 && args[3] != "" {
			dest = args[3]
		}
		return url, dest
	}
	if len(args) > 1 && args[1] != "" {
		url = args[1]
	}
	if len(args) > 2 && args[2] != "" {
		dest = args[2]
	}
	return url, dest
}

func clone(tgt target, dest, gitDir string) bool {
	pathF, ok := joinPath(gitDir, "P")
	if !ok {
		return fail("path file")
	}
	outF, ok := joinPath(gitDir, "O")
	if !ok {
		return fail("out file")
	}
	bodyF, ok := joinPath(gitDir, "B")
	if !ok {
		return fail("body file")
	}

	repo := repoPath(tgt)
	if !writeFile(pathF, []byte(infoRefsPath(repo))) {
		return fail("write path")
	}
	if !runHelper(tgt, "GET", pathF, outF, "") {
		return false
	}
	resp, rok := readFile(outF)
	if !rok {
		return fail("read refs")
	}
	_, body, err := splitHTTP(resp)
	if err != nil {
		return fail("http refs")
	}
	refs, err := parseInfoRefs(body)
	if err != nil {
		return fail("parse refs")
	}
	vi.ConsoleLine(markerRefs + uitoa(uint64(len(refs))))
	want, ok := pickWant(refs)
	if !ok {
		return fail("no want")
	}
	vi.ConsoleLine(markerWant + want.Name + " " + hexEncode(want.SHA[:]))

	if !writeFile(pathF, []byte(uploadPackPath(repo))) {
		return fail("write post path")
	}
	if !writeFile(bodyF, wantBody(want.SHA)) {
		return fail("write want")
	}
	if !runHelper(tgt, "POST", pathF, outF, bodyF) {
		return false
	}
	resp, rok = readFile(outF)
	if !rok {
		return fail("read pack")
	}
	_, body, err = splitHTTP(resp)
	if err != nil {
		return fail("http pack")
	}
	pack, err := extractPack(body)
	if err != nil {
		return fail("extract pack")
	}
	objs, nDelta, err := parsePack(pack)
	if err != nil {
		return fail("parse pack")
	}
	vi.ConsoleLine(markerPack + uitoa(uint64(len(objs))))
	if nDelta > 0 {
		vi.ConsoleLine(markerDelta)
	}
	if !noteObjects(objs) {
		return fail("empty pack")
	}
	if !writeStore(gitDir, objs, want) {
		return fail("store")
	}
	if !checkout(dest, objs, want.SHA) {
		return fail("checkout")
	}
	// Transfer scratch (path/out/body). Not .git/index or config:
	// #1337 is object store + checkout, not a working-tree clone.
	_ = vi.FileDelete(pathF)
	_ = vi.FileDelete(outF)
	_ = vi.FileDelete(bodyF)
	return true
}

func runHelper(tgt target, method, pathF, outF, bodyF string) bool {
	plan, ok := planHelper(tgt, method, pathF, outF, bodyF)
	if !ok {
		return fail("plan " + method)
	}
	line := markerHelper + plan.Name
	for _, a := range plan.Args {
		line += " " + a
	}
	vi.ConsoleLine(line)
	pid, err := vi.Exec(plan.Name, plan.Args...)
	if err != nil {
		return fail("exec " + method)
	}
	vi.ConsoleLine(markerPid + vi.Itoa64(pid))
	st := waitPID(pid)
	if st < 0 {
		return fail("wait " + method)
	}
	// 0 is accepted when waitPID observes the pid gone after ProcExited.
	if method != "" && st != 0 && st != fetchsOK {
		return fail("helper status " + vi.Itoa64(st))
	}
	return true
}

func waitPID(pid int64) int64 {
	var rows [16]vi.ProcRow
	deadline := vi.Nanos() + 120*int64(1e9)
	seen := false
	for vi.Nanos() < deadline {
		n, rc := vi.Procs(rows[:])
		if rc >= 0 {
			found := false
			for i := 0; i < n; i++ {
				if int64(rows[i].PID) != pid {
					continue
				}
				found = true
				seen = true
				if rows[i].State == vi.ProcExited {
					return int64(rows[i].ExitStatus)
				}
			}
			if seen && !found {
				return 0
			}
		}
		vi.Yield()
	}
	return -1
}

func noteObjects(objs []gitObj) bool {
	var blobs, trees, commits int
	for _, o := range objs {
		switch o.Type {
		case objBlob:
			blobs++
			vi.ConsoleLine(markerBlob + hexEncode(o.ID[:]))
		case objTree:
			trees++
			vi.ConsoleLine(markerTree + hexEncode(o.ID[:]))
		case objCommit:
			commits++
			vi.ConsoleLine(markerCommit + hexEncode(o.ID[:]))
		}
	}
	return blobs > 0 && trees > 0 && commits > 0
}

func writeStore(gitDir string, objs []gitObj, want gitRef) bool {
	objDir, ok := joinPath(gitDir, "objects")
	if !ok || !mkdir(objDir) {
		return false
	}
	refs, ok := joinPath(gitDir, "refs")
	if !ok || !mkdir(refs) {
		return false
	}
	heads, ok := joinPath(refs, "heads")
	if !ok || !mkdir(heads) {
		return false
	}
	for _, o := range objs {
		p, ok := objectPath(gitDir, o.ID)
		if !ok {
			return false
		}
		slash := lastSlash(p)
		if slash <= 0 {
			return false
		}
		if !mkdir(p[:slash]) {
			return false
		}
		if !writeFile(p, looseBytes(o)) {
			return false
		}
	}
	headPath, ok := joinPath(gitDir, "HEAD")
	if !ok {
		return false
	}
	refName := want.Name
	if refName == "HEAD" {
		refName = "refs/heads/main"
	}
	if !writeFile(headPath, []byte("ref: "+refName+"\n")) {
		return false
	}
	// refs/heads/main — last component only under heads/
	leaf := refName
	if i := lastSlash(refName); i >= 0 {
		leaf = refName[i+1:]
	}
	refPath, ok := joinPath(heads, leaf)
	if !ok {
		return false
	}
	return writeFile(refPath, []byte(hexEncode(want.SHA[:])+"\n"))
}

func checkout(dest string, objs []gitObj, commitID [20]byte) bool {
	c, ok := findObj(objs, commitID)
	if !ok || c.Type != objCommit {
		for _, o := range objs {
			if o.Type == objCommit {
				c = o
				ok = true
			}
		}
		if !ok {
			return false
		}
	}
	tid, ok := commitTree(c.Data)
	if !ok {
		return false
	}
	tree, ok := findObj(objs, tid)
	if !ok || tree.Type != objTree {
		return false
	}
	ents := parseTree(tree.Data)
	wrote := false
	for _, e := range ents {
		if !isBlobMode(e.Mode) {
			continue
		}
		blob, ok := findObj(objs, e.ID)
		if !ok || blob.Type != objBlob {
			continue
		}
		p, ok := joinPath(dest, e.Name)
		if !ok {
			continue
		}
		if !writeFile(p, blob.Data) {
			return false
		}
		vi.ConsoleLine(markerCheck + e.Name)
		wrote = true
	}
	return wrote
}

func lastSlash(s string) int {
	for i := len(s) - 1; i >= 0; i-- {
		if s[i] == '/' {
			return i
		}
	}
	return -1
}

func mkdir(path string) bool {
	h, r := vi.FileOpen(path, vi.ModeWrite|vi.ModeCreate|vi.ModeDir)
	if r >= 0 {
		vi.FileClose(uint32(h))
		return true
	}
	return r == errExist
}

func mkdirAll(path string) bool {
	if path == "" {
		return false
	}
	// one component at a time; parents must exist.
	start := 1
	if len(path) > 0 && path[0] != '/' {
		start = 0
	}
	for i := start; i <= len(path); i++ {
		if i < len(path) && path[i] != '/' {
			continue
		}
		if i == 0 {
			continue
		}
		comp := path[:i]
		if comp == "" || comp == "/" || comp == "/host" {
			if i == len(path) {
				break
			}
			continue
		}
		if !mkdir(comp) {
			return false
		}
		if i == len(path) {
			break
		}
	}
	return true
}

func writeFile(path string, data []byte) bool {
	h, r := vi.FileOpen(path, vi.ModeWrite|vi.ModeCreate)
	if r < 0 {
		return false
	}
	defer vi.FileClose(uint32(h))
	_ = vi.FileTruncate(uint32(h), 0)
	off := 0
	for off < len(data) {
		n := len(data) - off
		if n > maxWrite {
			n = maxWrite
		}
		wn, wr := vi.FileWrite(uint32(h), data[off:off+n])
		if wr < 0 || wn <= 0 {
			return false
		}
		off += wn
	}
	return vi.FileTruncate(uint32(h), uint32(len(data))) >= 0
}

func readFile(path string) ([]byte, bool) {
	b, r := vi.ReadFileAll(path, vi.MaxFileBytes)
	if r < 0 || b == nil {
		return nil, false
	}
	return b, true
}

func fail(detail string) bool {
	vi.ConsoleLine(markerErr + detail)
	vi.Exit(1)
	return false
}
