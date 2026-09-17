// Command selftest is GOSELF.ELF (M61b, issue #1382): the first guest-owned
// pass/fail evidence in the fleet.
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
	reportPath  = selftestDir + "/REPORT.txt"
	summaryPath = outDir + "/summary.txt"
	helloPath   = outDir + "/hello.txt"
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

// cases is the built-in list, in report order. M61c/d/e append here; M61b's
// scope is the framework plus two smoke cases.
func cases() []testCase {
	return []testCase{
		{id: "clock-monotonic", run: caseClockMonotonic},
		{id: "file-write", run: caseFileWrite},
	}
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
// in selftest_test.go; M61b's cases do not read yet.
//
// KNOWN ISSUE (#1391, filed from this card): on the guest, the FIRST read a
// process issues can return the correct length of zeros with no error while
// the host serves the real bytes. Every later read is correct. Do not hide it
// with a warm-up read — the intake/read-back cases must surface it until it is
// fixed.
func readFile(s *syscalls, path string, max int) ([]byte, error) {
	h, rc := s.open(path, vi.ModeRead)
	if rc < 0 {
		return nil, errors.New("open rc=" + strconv.FormatInt(rc, 10))
	}
	defer s.close(uint32(h))
	var out []byte
	buf := make([]byte, 512)
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
