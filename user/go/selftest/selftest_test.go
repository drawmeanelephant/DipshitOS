package main

import (
	"bytes"
	"regexp"
	"sort"
	"strings"
	"testing"

	"virelai/vi"
)

// fakeFS is an in-memory share for the case logic: it implements the syscalls
// struct over maps, so `go test ./selftest` exercises real case behavior with
// no guest (the host `vi` stubs return -ENOSYS by design). Fault switches let
// a test drive the failure paths an adapter can actually hit.
type fakeFS struct {
	files   map[string][]byte
	dirs    map[string]bool
	handles map[int64]string
	hflags  map[int64]uint32 // the flags each handle was opened with (truncate's gate)
	cursors map[int64]int
	next    int64
	clock   int64

	frozenClock bool   // sleep does not advance the clock
	shortWrite  bool   // every write accepts one byte (the loop path)
	corruptRead bool   // reads return the wrong bytes
	denyWrite   bool   // every write-op fails
	denyPath    string // write-opens of this path fail (the intake copy is unaffected)
	zeroRead    bool   // reads return the right length of zeros (issue #1391)

	denyTruncate bool // truncate fails with EACCES
	lieDelete    bool // delete reports success and leaves the file
	listStale    bool // deleted paths: removed from the table, still listed
	ghosts       []string
}

func newFakeFS() *fakeFS {
	return &fakeFS{
		files:   map[string][]byte{},
		dirs:    map[string]bool{},
		handles: map[int64]string{},
		hflags:  map[int64]uint32{},
		cursors: map[int64]int{},
		clock:   1000,
	}
}

func (f *fakeFS) syscalls() *syscalls {
	return &syscalls{
		now: func() int64 { return f.clock },
		sleep: func(ticks uint64) {
			if !f.frozenClock {
				f.clock += int64(ticks)
			}
		},
		mkdir: func(path string) int64 {
			if f.dirs[path] {
				return -9 // EEXIST, the kernel's MODE_DIR value
			}
			f.dirs[path] = true
			return 0
		},
		open:     f.open,
		read:     f.read,
		write:    f.writeGuarded,
		truncate: f.truncate,
		remove:   f.remove,
		list:     f.list,
		close: func(h uint32) {
			delete(f.handles, int64(h))
			delete(f.hflags, int64(h))
		},
	}
}

// writeGuarded applies the fake's write fault switches, then the plain write.
func (f *fakeFS) writeGuarded(h uint32, b []byte) (int, int64) {
	if f.denyWrite {
		return 0, -2
	}
	if f.shortWrite && len(b) > 1 {
		b = b[:1]
	}
	return f.write(h, b)
}

// truncate mirrors file_table.truncate: EBADF for a dead handle, EACCES
// without MODE_WRITE, shrink keeps the prefix, growth zero-fills, and the
// cursor is clamped to the new size.
func (f *fakeFS) truncate(h uint32, size uint32) int64 {
	p, ok := f.handles[int64(h)]
	if !ok {
		return -2 // EBADF
	}
	if f.denyTruncate || f.hflags[int64(h)]&flagModeWrite == 0 {
		return -7 // EACCES
	}
	body := f.files[p]
	var next []byte
	if int(size) <= len(body) {
		next = append([]byte(nil), body[:size]...)
	} else {
		next = make([]byte, size)
		copy(next, body)
	}
	f.files[p] = next
	if f.cursors[int64(h)] > int(size) {
		f.cursors[int64(h)] = int(size)
	}
	return 0
}

// remove mirrors file_table.delete: ENOENT for a path that is not a file,
// EINVAL for a directory.
func (f *fakeFS) remove(path string) int64 {
	if _, ok := f.files[path]; !ok {
		return -6 // ENOENT
	}
	if f.dirs[path] {
		return -1 // EINVAL: a directory is not a file
	}
	if f.lieDelete {
		return 0 // reports success, leaves the bytes: the case must catch it
	}
	delete(f.files, path)
	if f.listStale {
		f.ghosts = append(f.ghosts, path)
	}
	return 0
}

// list mirrors sys_dir_list over the share: the direct children of an
// existing directory, sorted, as 40-byte rows. A missing directory is ENOENT
// (the host's LIST has no entries to return).
func (f *fakeFS) list(path string, buf []vi.DirEntry) (int, int64) {
	if !f.dirs[path] {
		return 0, -6 // ENOENT
	}
	prefix := path + "/"
	type row struct {
		name string
		dir  bool
	}
	var rows []row
	add := func(p string, dir bool) {
		rest, ok := strings.CutPrefix(p, prefix)
		if !ok || rest == "" || strings.Contains(rest, "/") {
			return // not a direct child
		}
		rows = append(rows, row{name: rest, dir: dir})
	}
	for p := range f.files {
		add(p, false)
	}
	for d := range f.dirs {
		add(d, true)
	}
	for _, g := range f.ghosts {
		add(g, false) // a stale listing still reports a deleted name
	}
	sort.Slice(rows, func(i, j int) bool { return rows[i].name < rows[j].name })
	n := 0
	for _, r := range rows {
		if n >= len(buf) {
			break
		}
		var e vi.DirEntry
		copy(e.Name[:], r.name)
		if r.dir {
			e.IsDir = 1
		} else {
			e.Size = uint32(len(f.files[prefix+r.name]))
		}
		buf[n] = e
		n++
	}
	return n, int64(n)
}

const (
	flagModeRead   = 0x0001
	flagModeWrite  = 0x0002
	flagModeCreate = 0x0004
	flagModeDir    = 0x0010
)

func (f *fakeFS) open(path string, flags uint32) (int64, int64) {
	switch {
	case flags&flagModeDir != 0:
		// The kernel's open validates MODE_DIR against
		// MODE_WRITE|MODE_CREATE — a bare MODE_DIR is EINVAL, which is what
		// the guest's mkdir helper used to pass (and therefore always
		// failed silently).
		if flags&(flagModeWrite|flagModeCreate) != flagModeWrite|flagModeCreate {
			return 0, -1
		}
		if f.dirs[path] {
			return 0, -9
		}
		f.dirs[path] = true
		return 0, 0
	case flags&flagModeWrite != 0:
		if f.denyWrite || (f.denyPath != "" && f.denyPath == path) {
			return 0, -2
		}
		f.files[path] = nil // ADR 0010 replace semantics
		f.next++
		f.handles[f.next] = path
		f.hflags[f.next] = flags
		f.cursors[f.next] = 0
		return f.next, f.next
	case flags&flagModeRead != 0:
		if _, ok := f.files[path]; !ok {
			return 0, -6 // ENOENT
		}
		f.next++
		f.handles[f.next] = path
		f.hflags[f.next] = flags
		f.cursors[f.next] = 0
		return f.next, f.next
	}
	return 0, -1 // EINVAL
}

func (f *fakeFS) read(h uint32, buf []byte) (int, int64) {
	p, ok := f.handles[int64(h)]
	if !ok {
		return 0, -2
	}
	cur := f.cursors[int64(h)]
	body := f.files[p]
	if cur >= len(body) {
		return 0, 0
	}
	n := copy(buf, body[cur:])
	f.cursors[int64(h)] = cur + n
	if f.corruptRead {
		buf[0] ^= 0xff
	}
	if f.zeroRead {
		for i := 0; i < n; i++ {
			buf[i] = 0
		}
	}
	return n, int64(n)
}

func (f *fakeFS) write(h uint32, b []byte) (int, int64) {
	p, ok := f.handles[int64(h)]
	if !ok {
		return 0, -2
	}
	f.files[p] = append(f.files[p], b...)
	return len(b), int64(len(b))
}

// wantReport is the byte-exact report after M61d: the M61f `share-equals`
// fixture shape, and the report the go-selftest spec requires on the share.
// Adding a case updates this and the spec together.
const wantReport = "case intake pass\ncase intake-altered pass\n" +
	"case clock-monotonic pass\ncase file-write pass\n" +
	"case file-roundtrip pass\ncase file-truncate pass\n" +
	"case file-delete pass\ncase file-list pass\nsummary cases=8 failed=0\n"

// seedFixtures is the host's half of the intake contract: IN/fixture.txt holds
// the canonical body, IN/altered.txt the altered one (ADR 0031 D2).
func seedFixtures(fs *fakeFS) {
	fs.files[intakePath] = []byte(intakeFixture)
	fs.files[alteredPath] = []byte(intakeAltered)
}

func TestRunCasesAllPassAndReportBytes(t *testing.T) {
	fs := newFakeFS()
	seedFixtures(fs)
	rs := runCases(fs.syscalls())

	if len(rs) != 8 {
		t.Fatalf("cases = %d, want 8", len(rs))
	}
	for _, r := range rs {
		if !r.ok {
			t.Fatalf("case %s failed: %s", r.id, r.detail)
		}
	}
	if got := string(renderReport(rs)); got != wantReport {
		t.Fatalf("report bytes:\n got %q\nwant %q", got, wantReport)
	}
	if got := string(renderSummary(rs)); got != "summary cases=8 failed=0\n" {
		t.Fatalf("summary = %q", got)
	}
	if got := fs.files[helloPath]; !bytes.Equal(got, []byte(helloPayload)) {
		t.Fatalf("hello.txt = %q, want %q", got, helloPayload)
	}
	if !fs.dirs[outDir] {
		t.Fatal("the file-write case did not ensure OUT/ exists")
	}
}

// The intake case copies the bytes it READ into OUT/, and its receipt is the
// byte-exact line the spec requires. The copy is what the host compares, so a
// case that copied its own expectation instead of the read bytes fails here.
func TestIntakeCopiesTheBytesItRead(t *testing.T) {
	fs := newFakeFS()
	seedFixtures(fs)
	rs := runCases(fs.syscalls())

	if !rs[0].ok || rs[0].id != "intake" {
		t.Fatalf("intake should have passed, got %+v", rs[0])
	}
	if got := fs.files[intakeCopy]; !bytes.Equal(got, []byte(intakeFixture)) {
		t.Fatalf("OUT/fixture.copy = %q, want %q", got, intakeFixture)
	}
	wantLine := "case intake path=IN/fixture.txt bytes=25 match=yes\n"
	if got := string(fs.files[intakeReceipt]); got != wantLine {
		t.Fatalf("intake receipt = %q, want %q", got, wantLine)
	}
	wantAltered := "case intake-altered path=IN/altered.txt bytes=25 differs=yes\n"
	if got := string(fs.files[alteredReceipt]); got != wantAltered {
		t.Fatalf("altered receipt = %q, want %q", got, wantAltered)
	}
	if got := fs.files[alteredCopy]; !bytes.Equal(got, []byte(intakeAltered)) {
		t.Fatalf("OUT/altered.copy = %q, want %q", got, intakeAltered)
	}
}

// A mutated seed must FAIL the intake case (ADR 0031 D2) — that is the whole
// point of reading the share instead of carrying a constant. The copy still
// holds what was read, so the host can see the mutation that failed it.
func TestIntakeFailsOnAMutatedSeed(t *testing.T) {
	fs := newFakeFS()
	fs.files[intakePath] = []byte(intakeAltered)
	fs.files[alteredPath] = []byte(intakeFixture)
	rs := runCases(fs.syscalls())

	if rs[0].ok {
		t.Fatal("intake passed on a mutated seed")
	}
	if !strings.Contains(rs[0].detail, "fixture mismatch: got=25 want=25") {
		t.Fatalf("detail = %q", rs[0].detail)
	}
	// The altered case now sees the canonical bytes: an embedded constant
	// would report success here, the share read reports the truth.
	if rs[1].ok {
		t.Fatal("intake-altered passed while the share held the canonical bytes")
	}
	report := string(renderReport(rs))
	if !strings.Contains(report, "case intake fail fixture mismatch") {
		t.Fatalf("report lacks the intake failure: %q", report)
	}
	if !strings.Contains(report, "summary cases=8 failed=2") {
		t.Fatalf("report summary wrong: %q", report)
	}
	if got := fs.files[intakeCopy]; !bytes.Equal(got, []byte(intakeAltered)) {
		t.Fatalf("the copy is %q, want the mutated bytes", got)
	}
	wantLine := "case intake path=IN/fixture.txt bytes=25 match=no\n"
	if got := string(fs.files[intakeReceipt]); got != wantLine {
		t.Fatalf("intake receipt = %q, want %q", got, wantLine)
	}
}

// A missing fixture is a failed case with the open error as its detail, never
// a crash and never a skipped report (issue #1383 acceptance).
func TestIntakeFailsWhenTheFixtureIsMissing(t *testing.T) {
	fs := newFakeFS()
	rs := runCases(fs.syscalls())

	if rs[0].ok || rs[0].id != "intake" {
		t.Fatalf("intake should have failed, got %+v", rs[0])
	}
	if !strings.Contains(rs[0].detail, "open rc=-6") {
		t.Fatalf("detail = %q", rs[0].detail)
	}
	if got := string(fs.files[alteredReceipt]); !strings.Contains(got, "bytes=0 err=open rc=-6") {
		t.Fatalf("altered receipt = %q", got)
	}
	// The report is still complete: 8 cases, the 2 intake ones failed (the
	// clock and file cases do not read IN/).
	report := string(renderReport(rs))
	if !strings.Contains(report, "summary cases=8 failed=2") {
		t.Fatalf("report summary wrong: %q", report)
	}
	if lines := strings.Count(report, "\n"); lines != len(rs)+1 {
		t.Fatalf("report has %d lines, want %d", lines, len(rs)+1)
	}
}

// The #1391 shape — the right length of zeros — is named in the case detail
// rather than reported as a bare mismatch, so a future flake says what it was.
func TestIntakeNamesZerosReads(t *testing.T) {
	fs := newFakeFS()
	seedFixtures(fs)
	fs.zeroRead = true
	rs := runCases(fs.syscalls())

	if rs[0].ok {
		t.Fatalf("intake passed on a zeros read, got %+v", rs[0])
	}
	if !strings.Contains(rs[0].detail, "25B of zeros (issue #1391)") {
		t.Fatalf("detail = %q", rs[0].detail)
	}
}

// A zeros read must fail the NEGATIVE case too: while issue #1391 was live,
// `intake-altered` PASSED on 25 bytes of zeros because zeros do differ from
// the canonical body. That is a wrong answer reported as a verdict, so the
// negative check requires a body (right length, not all zeros) as well.
func TestAlteredCaseFailsOnAZerosRead(t *testing.T) {
	fs := newFakeFS()
	seedFixtures(fs)
	fs.zeroRead = true
	rs := runCases(fs.syscalls())

	if rs[1].ok {
		t.Fatalf("intake-altered passed on a zeros read, got %+v", rs[1])
	}
	if !strings.Contains(rs[1].detail, "not a body: 25B of zeros") {
		t.Fatalf("detail = %q", rs[1].detail)
	}
}

// readFile is the intake/read-back substrate for M61c/M61d; M61b's cases do
// not read yet, so it is exercised directly here (including the failure path
// the guest must not paper over — see issue #1391).
func TestReadFileReturnsTheWholeFile(t *testing.T) {
	fs := newFakeFS()
	s := fs.syscalls()
	if _, err := writeFile(s, helloPath, []byte(helloPayload)); err != nil {
		t.Fatalf("writeFile: %v", err)
	}
	got, err := readFile(s, helloPath, 4096)
	if err != nil {
		t.Fatalf("readFile: %v", err)
	}
	if string(got) != helloPayload {
		t.Fatalf("readFile = %q, want %q", got, helloPayload)
	}
}

func TestReadFileSurfacesACorruptReadback(t *testing.T) {
	fs := newFakeFS()
	s := fs.syscalls()
	if _, err := writeFile(s, helloPath, []byte(helloPayload)); err != nil {
		t.Fatalf("writeFile: %v", err)
	}
	fs.corruptRead = true
	got, err := readFile(s, helloPath, 4096)
	if err != nil {
		t.Fatalf("readFile: %v", err)
	}
	if string(got) == helloPayload {
		t.Fatal("corrupt readback compared equal — the fake did not corrupt")
	}
}

func TestFileWriteCaseFailsWhenTheWriteIsRefused(t *testing.T) {
	fs := newFakeFS()
	seedFixtures(fs)
	fs.denyPath = helloPath
	rs := runCases(fs.syscalls())

	if rs[3].id != "file-write" || rs[3].ok {
		t.Fatalf("file-write should have failed, got %+v", rs[3])
	}
	report := string(renderReport(rs))
	if !strings.Contains(report, "case file-write fail ") {
		t.Fatalf("report lacks the fail detail: %q", report)
	}
	if !strings.Contains(report, "summary cases=8 failed=1") {
		t.Fatalf("report summary wrong: %q", report)
	}
}

func TestClockCaseFailsWhenTheClockStandsStill(t *testing.T) {
	fs := newFakeFS()
	fs.frozenClock = true
	rs := runCases(fs.syscalls())

	if rs[2].id != "clock-monotonic" || rs[2].ok {
		t.Fatalf("clock-monotonic should have failed, got %+v", rs[2])
	}
	if !strings.Contains(rs[2].detail, "clock did not advance") {
		t.Fatalf("detail = %q", rs[2].detail)
	}
}

func TestFileWriteCaseDetailNamesTheOpenFailure(t *testing.T) {
	fs := newFakeFS()
	seedFixtures(fs)
	fs.denyPath = helloPath
	rs := runCases(fs.syscalls())

	if rs[3].ok {
		t.Fatalf("file-write should have failed, got %+v", rs[3])
	}
	if !strings.Contains(rs[3].detail, "open rc=-2") {
		t.Fatalf("detail = %q", rs[3].detail)
	}
}

func TestWriteFileLoopsUntilEveryByteLands(t *testing.T) {
	fs := newFakeFS()
	fs.shortWrite = true
	payload := []byte("goself smoke\n")
	n, err := writeFile(fs.syscalls(), helloPath, payload)
	if err != nil {
		t.Fatalf("writeFile: %v", err)
	}
	if n != len(payload) {
		t.Fatalf("wrote %d bytes, want %d", n, len(payload))
	}
	if got := fs.files[helloPath]; !bytes.Equal(got, payload) {
		t.Fatalf("hello.txt = %q, want %q", got, payload)
	}
}

// The report is deterministic (ADR 0031): two runs at different clock values
// render byte-identical bytes, which is what lets the host byte-compare it.
func TestReportIsDeterministicAcrossRuns(t *testing.T) {
	a, b := newFakeFS(), newFakeFS()
	seedFixtures(a)
	seedFixtures(b)
	b.clock = 999999
	ra, rb := runCases(a.syscalls()), runCases(b.syscalls())
	if !bytes.Equal(renderReport(ra), renderReport(rb)) {
		t.Fatalf("report changed between runs:\n%q\n%q", renderReport(ra), renderReport(rb))
	}
}

func TestCaseIDsAreUniqueAndContractShaped(t *testing.T) {
	shape := regexp.MustCompile(`^[a-z0-9-]+$`)
	seen := map[string]bool{}
	for _, c := range cases() {
		if !shape.MatchString(c.id) {
			t.Fatalf("case id %q is not [a-z0-9-]+", c.id)
		}
		if seen[c.id] {
			t.Fatalf("duplicate case id %q", c.id)
		}
		seen[c.id] = true
	}
}

// The serial contract is one FAIL line plus OK only on a clean run, and the
// count it carries is the report's failed count.
func TestSerialSummaryCarriesTheReportCount(t *testing.T) {
	fs := newFakeFS()
	seedFixtures(fs)
	rs := runCases(fs.syscalls())
	if got := failed(rs); got != 0 {
		t.Fatalf("failed = %d", got)
	}
	if got := strings.TrimSpace(string(renderSummary(rs))); got != summaryLine(rs) {
		t.Fatalf("summary file %q disagrees with summaryLine %q", got, summaryLine(rs))
	}
	lines := serialSummary(0)
	if len(lines) != 2 || lines[0] != "selftest: FAIL n=0" || lines[1] != "selftest OK" {
		t.Fatalf("serialSummary(0) = %q", lines)
	}
	// The report's last line is the same count line (the two files agree).
	report := string(renderReport(rs))
	if !strings.HasSuffix(report, summaryLine(rs)+"\n") {
		t.Fatalf("report does not end on the summary line: %q", report)
	}
	failing := serialSummary(1)
	if len(failing) != 1 || failing[0] != "selftest: FAIL n=1" {
		t.Fatalf("serialSummary(1) = %q", failing)
	}
}

func TestOneLineBoundsAndFlattensDetails(t *testing.T) {
	if got := oneLine("read\nback\rfailed\there"); got != "read back failed here" {
		t.Fatalf("oneLine = %q", got)
	}
	long := strings.Repeat("x", 200)
	if got := oneLine(long); len(got) != 48 {
		t.Fatalf("oneLine length = %d, want 48", len(got))
	}
	// A detail can never add a line to the report.
	fs := newFakeFS()
	seedFixtures(fs)
	fs.denyPath = helloPath
	rs := runCases(fs.syscalls())
	report := string(renderReport(rs))
	if got := strings.Count(report, "\n"); got != len(rs)+1 {
		t.Fatalf("report has %d lines, want %d", got, len(rs)+1)
	}
	for _, line := range strings.Split(strings.TrimSuffix(report, "\n"), "\n") {
		if !strings.HasPrefix(line, "case ") && !strings.HasPrefix(line, "summary ") {
			t.Fatalf("report line %q is outside the grammar", line)
		}
	}
}

// ---------------------------------------------------------------------------
// M61d (#1384): the file-ABI pack
// ---------------------------------------------------------------------------
//
// Index map after M61d: 0 intake · 1 intake-altered · 2 clock-monotonic ·
// 3 file-write · 4 file-roundtrip · 5 file-truncate · 6 file-delete ·
// 7 file-list.

func TestFileRoundtripCopiesTheBytesItRead(t *testing.T) {
	fs := newFakeFS()
	seedFixtures(fs)
	rs := runCases(fs.syscalls())
	if !rs[4].ok || rs[4].id != "file-roundtrip" {
		t.Fatalf("file-roundtrip should have passed, got %+v", rs[4])
	}
	want := roundtripPayload()
	if len(want) != 525 {
		t.Fatalf("roundtrip payload = %d B, want 525 (25 units)", len(want))
	}
	if got := fs.files[roundtripPath]; !bytes.Equal(got, want) {
		t.Fatalf("roundtrip.txt = %q, want %q", got, want)
	}
	// The copy holds what was READ, not what was written: a write that
	// reported success without landing, or a read that invented bytes, cannot
	// pass the host's byte comparison.
	if got := fs.files[roundtripCopy]; !bytes.Equal(got, want) {
		t.Fatalf("roundtrip.copy = %q, want %q", got, want)
	}
	wantLine := "case file-roundtrip path=OUT/roundtrip.txt bytes=525 match=yes\n"
	if got := string(fs.files[roundtripOk]); got != wantLine {
		t.Fatalf("roundtrip receipt = %q, want %q", got, wantLine)
	}
}

// The #1391 shape is named by the round-trip case too: the right length of
// zeros is a lost kernel->user copy, not a byte mismatch — and the copy still
// holds the zeros, so the host sees what the app saw.
func TestFileRoundtripNamesAZerosRead(t *testing.T) {
	fs := newFakeFS()
	seedFixtures(fs)
	fs.zeroRead = true
	rs := runCases(fs.syscalls())
	if rs[4].ok {
		t.Fatalf("file-roundtrip passed on a zeros read, got %+v", rs[4])
	}
	if !strings.Contains(rs[4].detail, "525B of zeros (issue #1391)") {
		t.Fatalf("detail = %q", rs[4].detail)
	}
	if got := fs.files[roundtripCopy]; len(got) != 525 || !isAllZero(got) {
		t.Fatalf("roundtrip.copy = %d B (all zero: %v), want 525 zero bytes", len(got), isAllZero(got))
	}
}

func TestFileTruncateKeepsThePrefix(t *testing.T) {
	fs := newFakeFS()
	seedFixtures(fs)
	rs := runCases(fs.syscalls())
	if !rs[5].ok || rs[5].id != "file-truncate" {
		t.Fatalf("file-truncate should have passed, got %+v", rs[5])
	}
	kept := truncateKept()
	if len(kept) != 105 {
		t.Fatalf("kept prefix = %d B, want 105 (5 units)", len(kept))
	}
	if got := fs.files[truncatedCopy]; !bytes.Equal(got, kept) {
		t.Fatalf("truncated.copy = %q, want %q", got, kept)
	}
	if got := fs.files[truncatePath]; !bytes.Equal(got, kept) {
		t.Fatalf("truncate.txt = %q, want the kept prefix", got)
	}
	wantLine := "case file-truncate path=OUT/truncate.txt wrote=840 kept=105 bytes=105 match=yes\n"
	if got := string(fs.files[truncateOk]); got != wantLine {
		t.Fatalf("truncate receipt = %q, want %q", got, wantLine)
	}
}

// A refused truncate fails the case and names the code: the case keeps ONE
// write handle, so a refusal is the ABI rejecting a legitimate shrink, not the
// replace-on-open semantics the case deliberately avoids.
func TestFileTruncateFailsWhenTheAbiRefuses(t *testing.T) {
	fs := newFakeFS()
	seedFixtures(fs)
	fs.denyTruncate = true
	rs := runCases(fs.syscalls())
	if rs[5].ok {
		t.Fatalf("file-truncate passed with a refused truncate, got %+v", rs[5])
	}
	if !strings.Contains(rs[5].detail, "truncate rc=-7") {
		t.Fatalf("detail = %q", rs[5].detail)
	}
}

func TestFileDeleteProvesThePathIsGone(t *testing.T) {
	fs := newFakeFS()
	seedFixtures(fs)
	rs := runCases(fs.syscalls())
	if !rs[6].ok || rs[6].id != "file-delete" {
		t.Fatalf("file-delete should have passed, got %+v", rs[6])
	}
	if _, exists := fs.files[deletePath]; exists {
		t.Fatal("deleted.txt survived the case")
	}
	wantLine := "case file-delete path=OUT/deleted.txt delete=0 reopen=-6\n"
	if got := string(fs.files[deleteOk]); got != wantLine {
		t.Fatalf("delete receipt = %q, want %q", got, wantLine)
	}
}

// A delete that reports success without removing the file must FAIL: the
// reopen failing is the only evidence the case accepts.
func TestFileDeleteCatchesALyingDelete(t *testing.T) {
	fs := newFakeFS()
	seedFixtures(fs)
	fs.lieDelete = true
	rs := runCases(fs.syscalls())
	if rs[6].ok {
		t.Fatalf("file-delete passed while the file survived, got %+v", rs[6])
	}
	if !strings.Contains(rs[6].detail, "open after delete succeeded") {
		t.Fatalf("detail = %q", rs[6].detail)
	}
}

func TestFileListSeesThenDoesNotSee(t *testing.T) {
	fs := newFakeFS()
	seedFixtures(fs)
	rs := runCases(fs.syscalls())
	if !rs[7].ok || rs[7].id != "file-list" {
		t.Fatalf("file-list should have passed, got %+v", rs[7])
	}
	if _, exists := fs.files[listedPath]; exists {
		t.Fatal("listed.txt survived the case")
	}
	wantLine := "case file-list dir=OUT/LIST file=listed.txt first=seen second=absent\n"
	if got := string(fs.files[listOk]); got != wantLine {
		t.Fatalf("list receipt = %q, want %q", got, wantLine)
	}
}

// A listing that keeps reporting a deleted name is a wrong answer: the case
// fails, and the detail names what it saw.
func TestFileListCatchesAStaleListing(t *testing.T) {
	fs := newFakeFS()
	seedFixtures(fs)
	fs.listStale = true
	rs := runCases(fs.syscalls())
	if rs[7].ok {
		t.Fatalf("file-list passed on a stale listing, got %+v", rs[7])
	}
	if !strings.Contains(rs[7].detail, "listing still shows listed.txt") {
		t.Fatalf("detail = %q", rs[7].detail)
	}
}

// Every M61d case leaves a receipt: the host reads one file per case instead
// of grepping a transcript, and the receipt is exactly one `case …` line.
func TestEveryM61dCaseWritesAReceipt(t *testing.T) {
	fs := newFakeFS()
	seedFixtures(fs)
	runCases(fs.syscalls())
	for _, path := range []string{writeOk, roundtripOk, truncateOk, deleteOk, listOk} {
		got, ok := fs.files[path]
		if !ok {
			t.Fatalf("receipt %s missing", path)
		}
		line := string(got)
		if !strings.HasPrefix(line, "case ") || strings.Count(line, "\n") != 1 || !strings.HasSuffix(line, "\n") {
			t.Fatalf("receipt %s = %q, want one 'case …' line", path, line)
		}
	}
}

// The MODE_DIR row needs MODE_WRITE|MODE_CREATE together (file_table.open
// validates them as a triple): a bare MODE_DIR is EINVAL, which is what the
// guest's mkdir helper used to send — so the app never actually created a
// directory and only the spec's host-side makedirs made OUT/ exist. The fake
// enforces the kernel's rule, so a regression here fails off-guest.
func TestMkdirRowNeedsCreateAndWrite(t *testing.T) {
	fs := newFakeFS()
	if _, rc := fs.open(listDir, flagModeDir); rc != -1 {
		t.Fatalf("bare MODE_DIR rc = %d, want -1 (EINVAL)", rc)
	}
	if _, rc := fs.open(listDir, flagModeWrite|flagModeCreate|flagModeDir); rc != 0 {
		t.Fatalf("MODE_WRITE|MODE_CREATE|MODE_DIR rc = %d, want 0", rc)
	}
	if !fs.dirs[listDir] {
		t.Fatal("the triple did not create the directory")
	}
	if _, rc := fs.open(listDir, flagModeWrite|flagModeCreate|flagModeDir); rc != -9 {
		t.Fatalf("second create rc = %d, want -9 (EEXIST)", rc)
	}
}
