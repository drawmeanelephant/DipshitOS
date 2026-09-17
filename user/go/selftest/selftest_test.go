package main

import (
	"bytes"
	"regexp"
	"strings"
	"testing"
)

// fakeFS is an in-memory share for the case logic: it implements the syscalls
// struct over maps, so `go test ./selftest` exercises real case behavior with
// no guest (the host `vi` stubs return -ENOSYS by design). Fault switches let
// a test drive the failure paths an adapter can actually hit.
type fakeFS struct {
	files   map[string][]byte
	dirs    map[string]bool
	handles map[int64]string
	cursors map[int64]int
	next    int64
	clock   int64

	frozenClock bool   // sleep does not advance the clock
	shortWrite  bool   // every write accepts one byte (the loop path)
	corruptRead bool   // reads return the wrong bytes
	denyWrite   bool   // every write-op fails
	denyPath    string // write-opens of this path fail (the intake copy is unaffected)
	zeroRead    bool   // reads return the right length of zeros (issue #1391)
}

func newFakeFS() *fakeFS {
	return &fakeFS{
		files:   map[string][]byte{},
		dirs:    map[string]bool{},
		handles: map[int64]string{},
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
		open: f.open,
		read: f.read,
		write: func(h uint32, b []byte) (int, int64) {
			if f.denyWrite {
				return 0, -2
			}
			if f.shortWrite && len(b) > 1 {
				b = b[:1]
			}
			return f.write(h, b)
		},
		close: func(h uint32) { delete(f.handles, int64(h)) },
	}
}

const (
	flagModeRead  = 0x0001
	flagModeWrite = 0x0002
	flagModeDir   = 0x0010
)

func (f *fakeFS) open(path string, flags uint32) (int64, int64) {
	switch {
	case flags&flagModeDir != 0:
		if f.dirs[path] {
			return 0, -9
		}
		f.dirs[path] = true
		return 0, 0
	case flags&flagModeRead != 0:
		if _, ok := f.files[path]; !ok {
			return 0, -6 // ENOENT
		}
		f.next++
		f.handles[f.next] = path
		f.cursors[f.next] = 0
		return f.next, f.next
	case flags&flagModeWrite != 0:
		if f.denyWrite || (f.denyPath != "" && f.denyPath == path) {
			return 0, -2
		}
		f.files[path] = nil // ADR 0010 replace semantics
		f.next++
		f.handles[f.next] = path
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

// wantReport is the byte-exact report of the four cases after M61c: the M61f
// `share-equals` fixture shape, and the report the go-selftest spec requires on
// the share. Adding a case updates this and the spec together.
const wantReport = "case intake pass\ncase intake-altered pass\n" +
	"case clock-monotonic pass\ncase file-write pass\nsummary cases=4 failed=0\n"

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

	if len(rs) != 4 {
		t.Fatalf("cases = %d, want 4", len(rs))
	}
	for _, r := range rs {
		if !r.ok {
			t.Fatalf("case %s failed: %s", r.id, r.detail)
		}
	}
	if got := string(renderReport(rs)); got != wantReport {
		t.Fatalf("report bytes:\n got %q\nwant %q", got, wantReport)
	}
	if got := string(renderSummary(rs)); got != "summary cases=4 failed=0\n" {
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
	if !strings.Contains(report, "summary cases=4 failed=2") {
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
	// The report is still complete: 4 cases, 2 of them failed (the clock and
	// file-write cases do not read the share).
	report := string(renderReport(rs))
	if !strings.Contains(report, "summary cases=4 failed=2") {
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
	if !strings.Contains(report, "summary cases=4 failed=1") {
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
