// Command selftest is GOSELF.ELF (M61b/M61c, issues #1382/#1383): the first
// guest-owned pass/fail evidence in the fleet.
//
// The contract is ADR 0031 (docs/decisions/0031-guest-selftest.md):
//
//	/host/SELFTEST/REPORT.txt  `case <id> pass|fail <detail>` lines in list
//	                           order, then `summary cases=<n> failed=<k>`
//	/host/SELFTEST/OUT/        one small receipt per case (the proof the host
//	                           reads back on macOS)
//	serial                     `selftest: case <id> pass|fail`, then
//	                           `selftest: FAIL n=<k>` and `selftest OK` (k==0)
//
// Serial is the heartbeat; the files are the proof. The report is written and
// closed BEFORE any summary line is printed, so the host can never read a
// summary while the report is missing or stale, and every marker is printed
// only AFTER its syscall returned (the GOEDIT/GOCALC discipline). The report
// bytes are deterministic — no timestamps, no pointers — which is what makes a
// `share-equals` fixture legal in M61f.
//
// The cases drive a `syscalls` struct rather than calling `vi` directly, so
// the case logic is host-testable: `go test ./selftest` injects fakes and the
// guest build uses guestSyscalls.
package main

import (
	"errors"
	"strconv"
	"strings"

	"virelai/vi"
)

// Host-share paths (ADR 0031 D2). IN/ belongs to the host (M61c seeds it);
// this app owns REPORT.txt and OUT/.
const (
	selftestDir = "/host/SELFTEST"
	outDir      = selftestDir + "/OUT"
	inDir       = selftestDir + "/IN"
	reportPath  = selftestDir + "/REPORT.txt"
	summaryPath = outDir + "/summary.txt"
	helloPath   = outDir + "/hello.txt"

	// M61c intake (issue #1383). The host seeds two fixtures; the cases prove
	// they were READ from the share, not carried in the binary, by copying the
	// bytes they read into OUT/ — where the spec byte-compares the copy
	// against the file it seeded on macOS.
	intakePath  = inDir + "/fixture.txt"
	alteredPath = inDir + "/altered.txt"

	intakeCopy     = outDir + "/fixture.copy"
	alteredCopy    = outDir + "/altered.copy"
	intakeReceipt  = outDir + "/intake.txt"
	alteredReceipt = outDir + "/intake-altered.txt"
)

// The intake fixture bodies. intakeFixture is seeded at IN/fixture.txt and is
// what the `intake` case requires the share to return; intakeAltered is seeded
// at IN/altered.txt — the same bytes with one character changed — and is what
// the `intake-altered` case requires the share to return INSTEAD (see
// fixtureCheck: a case that must NOT find the canonical bytes is what proves
// the comparison reads the share rather than a constant).
const (
	intakeFixture = "goself intake fixture v1\n"
	intakeAltered = "goself intake fixture v2\n"
)

// helloPayload is the file-write case's known bytes: short, fixed, and
// compared on the host side (the go-selftest spec reads OUT/hello.txt on
// macOS and requires these exact bytes).
const helloPayload = "goself smoke\n"

// syscalls is the slice of the ADR 0010 file ABI (plus the clock) the cases
// use, as function fields so tests can fake every one of them.
type syscalls struct {
	now   func() int64
	sleep func(ticks uint64)
	mkdir func(path string) int64
	open  func(path string, flags uint32) (int64, int64)
	read  func(h uint32, buf []byte) (int, int64)
	write func(h uint32, b []byte) (int, int64)
	close func(h uint32)
}

// guestSyscalls is the real EL0 surface (vi over ADR 0007).
func guestSyscalls() syscalls {
	return syscalls{
		now:   vi.Time,
		sleep: vi.Sleep,
		// MODE_DIR is the ADR 0010 mkdir row; the returned handle is a
		// directory slot. "already exists" is not an error here — a
		// pre-created SELFTEST/OUT must not fail a run (ADR 0031 D2).
		mkdir: func(path string) int64 {
			h, rc := vi.FileOpen(path, vi.ModeDir)
			if rc >= 0 {
				vi.FileClose(uint32(h))
			}
			return rc
		},
		open:  vi.FileOpen,
		read:  vi.FileRead,
		write: vi.FileWrite,
		close: vi.FileClose,
	}
}

// result is one case verdict. id is the report key; detail is a one-line
// human reason, printed only when the case failed.
type result struct {
	id     string
	ok     bool
	detail string
}

// testCase is one built-in case. The ids are part of the report contract (ADR
// 0031): renaming one is a report-format change, not a refactor.
type testCase struct {
	id  string
	run func(s *syscalls) error
}

// cases is the built-in list, in report order. M61c/d/e append here.
// The two intake cases come first: they are the ones that read what the host
// seeded, and their verdicts are what makes the rest of the run meaningful.
func cases() []testCase {
	return []testCase{
		{id: intakeCase.id, run: intakeCase.run},
		{id: alteredCase.id, run: alteredCase.run},
		{id: "clock-monotonic", run: caseClockMonotonic},
		{id: "file-write", run: caseFileWrite},
	}
}

// The two intake cases, as fixtureCheck values.
var (
	intakeCase = fixtureCheck{
		id:      "intake",
		path:    intakePath,
		want:    intakeFixture,
		mustEqu: true,
		copy:    intakeCopy,
		receipt: intakeReceipt,
	}
	alteredCase = fixtureCheck{
		id:      "intake-altered",
		path:    alteredPath,
		want:    intakeFixture,
		mustEqu: false,
		copy:    alteredCopy,
		receipt: alteredReceipt,
	}
)

// fixtureCheck is the intake case (ADR 0031 D2, M61c #1383): read a share
// fixture the HOST seeded, compare it with a known body, and copy the bytes
// that were actually READ into OUT/.
//
// The copy is the load-bearing part. A binary that answered from an embedded
// constant would pass a self-comparison and still write the constant's bytes,
// so the spec byte-compares OUT/*.copy against the file it seeded on macOS —
// bytes only the share can supply. `mustEqu=false` is the same check pointed
// the other way (the altered fixture must NOT be the canonical bytes), which
// is what makes a mutated seed a FAILED case rather than a silent pass.
type fixtureCheck struct {
	id      string
	path    string // the fixture's path on the share (/host/SELFTEST/IN/...)
	want    string // the known body the case compares against
	mustEqu bool   // true: the fixture must equal want; false: must differ
	copy    string // OUT/ copy of the bytes read
	receipt string // OUT/ receipt for this case
}

func (c fixtureCheck) run(s *syscalls) error {
	// The READ comes first, before anything else in this run touches the
	// share: intake is "what the host seeded", and the app reads it before it
	// writes anything of its own. Order is also load-bearing for issue #1391
	// — on VZ a share read that follows another share operation in the same
	// process has come back as the right length of zeros, while a process's
	// first share operation, when it is the read, has been correct in every
	// run measured. The case still FAILS and names #1391 if the channel lies
	// (that is what the check below is for); it does not retry or warm up.
	//
	// One byte over the expectation: a longer fixture is a mismatch, and the
	// bound keeps a hostile file from being read into memory unboundedly.
	got, err := readFile(s, c.path, len(c.want)+1)
	if err != nil {
		c.writeReceipt(s, 0, false, err.Error())
		return err
	}
	equal := string(got) == c.want

	// The app owns OUT/ and ensures it (EEXIST tolerated) before its first
	// write, so the case does not depend on the spec or on case order.
	s.mkdir(outDir)

	// Copied from `got`, never from `want`.
	if _, werr := writeFile(s, c.copy, got); werr != nil {
		c.writeReceipt(s, len(got), equal, werr.Error())
		return werr
	}
	if werr := c.writeReceipt(s, len(got), equal, ""); werr != nil {
		return werr
	}

	switch {
	case c.mustEqu && !equal:
		// A read that returns the right LENGTH of zeros is issue #1391, a
		// file-channel defect seen on VZ during M61b. Name it here: the
		// detail is the only place a human sees it, and the reported bytes
		// are what the investigation needs.
		if isAllZero(got) {
			return errors.New("read returned " + strconv.Itoa(len(got)) + "B of zeros (issue #1391)")
		}
		return errors.New("fixture mismatch: got=" + strconv.Itoa(len(got)) +
			" want=" + strconv.Itoa(len(c.want)))
	case !c.mustEqu && equal:
		return errors.New("altered fixture matched the expectation: " +
			strconv.Itoa(len(got)) + "B")
	}
	return nil
}

// writeReceipt writes the case's OUT/<id>.* receipt: the fixture it read, the
// length it got, and what the comparison said. Deterministic (no clocks, no
// pointers), so the spec can require these exact bytes. A receipt that cannot
// be written fails the case — the file is the evidence, not the serial line.
func (c fixtureCheck) writeReceipt(s *syscalls, n int, equal bool, errText string) error {
	// The receipt names the share-relative path (the form the host cats):
	// /host/SELFTEST/IN/fixture.txt -> IN/fixture.txt.
	rel := strings.TrimPrefix(c.path, selftestDir+"/")
	line := "case " + c.id + " path=" + rel + " bytes=" + strconv.Itoa(n)
	if errText != "" {
		line += " err=" + oneLine(errText)
	} else if c.mustEqu {
		line += " match=" + yesNo(equal)
	} else {
		line += " differs=" + yesNo(!equal)
	}
	_, err := writeFile(s, c.receipt, []byte(line+"\n"))
	return err
}

func yesNo(b bool) string {
	if b {
		return "yes"
	}
	return "no"
}

// isAllZero reports whether b is non-empty and every byte is zero — the shape
// of issue #1391's wrong answer (a correct LENGTH of zeros).
func isAllZero(b []byte) bool {
	if len(b) == 0 {
		return false
	}
	for _, v := range b {
		if v != 0 {
			return false
		}
	}
	return true
}

// caseClockMonotonic: the kernel clock advances across a sleep. A clock that
// stands still — or a SlotTime that is not wired — fails honestly; there is
// nothing here a stub can print its way past, because t0 and t1 are reads.
func caseClockMonotonic(s *syscalls) error {
	t0 := s.now()
	for i := 0; i < 8; i++ {
		s.sleep(1)
	}
	t1 := s.now()
	if t1 <= t0 {
		return errors.New("clock did not advance: " + strconv.FormatInt(t0, 10) +
			" -> " + strconv.FormatInt(t1, 10))
	}
	return nil
}

// caseFileWrite: create the OUT directory (EEXIST tolerated), write a known
// payload to the share, and close it. The guest's claim is the syscall result
// (every byte was accepted); the BYTES are the host's claim — the go-selftest
// spec reads OUT/hello.txt on macOS and compares it byte-exactly, so a write
// that reported success without landing cannot pass the gate.
//
// The read-back half deliberately stays out of M61b: it lands with the
// file-ABI case pack (M61d, #1384), where the first-read behaviour filed as
// #1391 is fixed or explicitly worked around.
func caseFileWrite(s *syscalls) error {
	s.mkdir(outDir)
	payload := []byte(helloPayload)
	n, err := writeFile(s, helloPath, payload)
	if err != nil {
		return err
	}
	if n != len(payload) {
		return errors.New("wrote " + strconv.Itoa(n) + "B of " + strconv.Itoa(len(payload)) + "B")
	}
	return nil
}

// runCases executes the list in order and returns one result per case. A case
// fails by returning an error — never by panicking — so the report is always
// written and the summary always printed.
func runCases(s *syscalls) []result {
	list := cases()
	rs := make([]result, 0, len(list))
	for _, c := range list {
		r := result{id: c.id, ok: true}
		if err := c.run(s); err != nil {
			r.ok = false
			r.detail = oneLine(err.Error())
		}
		rs = append(rs, r)
	}
	return rs
}

// writeFile replaces path with b and closes it. MODE_WRITE|MODE_CREATE is the
// ADR 0010 replace semantics (a write-open without MODE_APPEND truncates to
// zero), so the file always holds exactly b. FileWrite is one kernel call and
// may accept fewer bytes than offered, so it loops.
func writeFile(s *syscalls, path string, b []byte) (int, error) {
	h, rc := s.open(path, vi.ModeWrite|vi.ModeCreate)
	if rc < 0 {
		return 0, errors.New("open rc=" + strconv.FormatInt(rc, 10))
	}
	written := 0
	for written < len(b) {
		n, wrc := s.write(uint32(h), b[written:])
		if wrc < 0 || n <= 0 {
			s.close(uint32(h))
			return written, errors.New("write rc=" + strconv.FormatInt(wrc, 10))
		}
		written += n
	}
	s.close(uint32(h))
	return written, nil
}

// readFile reads a whole file up to max bytes. It is the substrate for the
// intake (M61c) and read-back (M61d) cases, unit-tested through the fake share
// in selftest_test.go.
//
// KNOWN ISSUE (#1391, M61b, root-caused in M61c): the FIRST kernel->user copy
// into a user buffer whose pages EL0 has never written is silently lost — the
// syscall returns the right byte count and the app reads zeros. Observed as a
// zeros read for APPS.TXT (852 B) and for a file the guest had just written
// (13 B) in M61b, and reproduced on demand in M61c with a probe that reads into
// a fresh buffer: touch the buffer first (see the workaround below) and the
// same read returns the real bytes. The host file channel is NOT at fault —
// the runner's own stdout shows the bytes served — and the guest's write path
// is not either (a write's pages are dirty before the syscall). fixtureCheck
// names the shape in the case detail so a regression is never a bare
// "mismatch", and nothing here retries or warms up as a substitute for a fix.
func readFile(s *syscalls, path string, max int) ([]byte, error) {
	h, rc := s.open(path, vi.ModeRead)
	if rc < 0 {
		return nil, errors.New("open rc=" + strconv.FormatInt(rc, 10))
	}
	defer s.close(uint32(h))
	var out []byte
	buf := make([]byte, 4096)
	// Issue #1391 workaround, and ONLY that: on VZ the first kernel->user
	// copy into a user buffer whose pages EL0 has never written is silently
	// lost — the syscall reports success and the app reads the page's zeros.
	// Writing the buffer's ends first makes every page the read can touch
	// warm, which is measurable (a probe that skips this line returns nothing
	// but zeros in every VZ run so far). It hides no bad data: the case below
	// still requires the exact fixture bytes and fails, naming #1391, on
	// anything else. Delete this when #1391 is fixed.
	buf[0] = 0
	buf[len(buf)-1] = 0
	for len(out) < max {
		n, rrc := s.read(uint32(h), buf)
		if rrc < 0 {
			return out, errors.New("read rc=" + strconv.FormatInt(rrc, 10))
		}
		if n == 0 {
			break
		}
		out = append(out, buf[:n]...)
	}
	return out, nil
}

// renderReport is the report grammar of ADR 0031: one
// `case <id> pass|fail <detail>` line per case in list order, then the
// `summary cases=<n> failed=<k>` line. Deterministic on purpose.
func renderReport(rs []result) []byte {
	var b strings.Builder
	for _, r := range rs {
		b.WriteString("case " + r.id + " ")
		if r.ok {
			b.WriteString("pass\n")
			continue
		}
		b.WriteString("fail")
		if r.detail != "" {
			b.WriteString(" " + r.detail)
		}
		b.WriteString("\n")
	}
	b.WriteString(summaryLine(rs) + "\n")
	return []byte(b.String())
}

// renderSummary is the OUT/summary.txt body: the same counts as the report's
// summary line, so the two files can never disagree.
func renderSummary(rs []result) []byte {
	return []byte(summaryLine(rs) + "\n")
}

// summaryLine is the one count line shared by REPORT.txt and summary.txt.
func summaryLine(rs []result) string {
	return "summary cases=" + strconv.Itoa(len(rs)) + " failed=" + strconv.Itoa(failed(rs))
}

// failed counts the failed cases.
func failed(rs []result) int {
	n := 0
	for _, r := range rs {
		if !r.ok {
			n++
		}
	}
	return n
}

// caseLine is the per-case serial heartbeat line (ADR 0031: these are welcome
// before the summary, and are never the proof).
func caseLine(r result) string {
	if r.ok {
		return "selftest: case " + r.id + " pass"
	}
	line := "selftest: case " + r.id + " fail"
	if r.detail != "" {
		line += " " + r.detail
	}
	return line
}

// serialSummary is the serial contract, in order: the FAIL line carrying the
// count, then `selftest OK` when nothing failed. The spec stops the VM on
// `selftest: FAIL n=` (any N) and asserts n=0.
func serialSummary(nFailed int) []string {
	lines := []string{"selftest: FAIL n=" + strconv.Itoa(nFailed)}
	if nFailed == 0 {
		lines = append(lines, "selftest OK")
	}
	return lines
}

// oneLine keeps a failure detail on one line and bounds its length, so the
// report stays a fixed-shape text file and the paint stays inside the frame.
func oneLine(s string) string {
	s = strings.Map(func(r rune) rune {
		if r == '\n' || r == '\r' || r == '\t' {
			return ' '
		}
		return r
	}, s)
	const maxDetail = 48
	if len(s) > maxDetail {
		s = s[:maxDetail]
	}
	return s
}
