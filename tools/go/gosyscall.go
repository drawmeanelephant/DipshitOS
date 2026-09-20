// M70c-S1P (#1525) / M70c-S1L (#1540) fixture: the GOOS=virelai std layer
// (syscall + os + fmt) exercised in the guest — not through the guest SDK.
//
// This is a program on this operating system whose file I/O goes through
// Go's *standard library*: `fmt` into `os.Stdout`, `os.Open`/`Read` for the
// bytes, `os.Mkdir`/`os.ReadDir`/`os.Stat`/`os.WriteFile`/`os.ReadFile`/
// `os.Remove` for the rest. Everything below the surface is the port landed
// by #1525 — syscall.Open/Read/Write/Close/Stat/ReadDirent/Mkdir/Unlink
// over the ADR 0007 slots, `internal/poll`'s FD, `internal/syscall/unix`'s
// path helpers — plus the two fixes #1540 had to make for it to run at all
// (the POSIX->kernel open-flag translation, and Stat for an entry the
// kernel's 16-row listing cannot reach).
//
// What each group proves:
//
//	setup: os.Mkdir into a directory this program owns, then two
//	       os.WriteFile + os.ReadFile round trips. The gate asserts the
//	       exact byte counts, and the host checks afterwards that the
//	       writes really landed in the share (and the removes really took
//	       them away) — state the guest cannot fake from inside.
//	read 2048        one sequential read at the handle's cursor, clamped to
//	                 the kernel's per-call bound, i.e. the raw read path.
//	second read 1    the next read continues the file (the host checks the
//	                 byte against the staged file: a layer that re-read page
//	                 one would print the ELF magic's second byte again).
//	stat size N      Stat through the parent-row route for a file whose
//	                 parent holds more than 16 entries, i.e. the reading
//	                 fallback #1540 added (the row cannot exist).
//	fstat size N     Fstat resolves the handle back to the path the port
//	                 remembered, then stats that.
//	raw dirent bytes this port's directory rows reach syscall.ReadDirent:
//	                 two entries in the owned directory, 40 bytes each.
//	absent ENOENT    the errno mapping on a path that really is absent,
//	                 printed through the Errno's own Error().
//	os bytes/hash    the WHOLE 9.5 MiB image read through os.File and folded
//	                 into FNV-1a — the host folds the same bytes off the
//	                 share, so this is the end-to-end proof of
//	                 os+internal/poll+syscall together.
//	os stat small    os.Stat of a file inside the owned directory, i.e. the
//	                 parent-row route when the parent is small (one syscall).
//	os dir entries N os.ReadDir over the owned directory — exactly the
//	                 entries this program created, then zero after its own
//	                 removes, both checked from the host side.
//	os remove        os.Remove, i.e. the delete slot through os.
//
// NOT proven here, deliberately: os/exec (no spawn slot), time/tzdata beyond
// the UTC fallback, and every socket call (no net slots). Those are ENOSYS by
// construction and the fixture does not pretend otherwise.
package main

import (
	"fmt"
	"io"
	"os"
	"syscall"
)

const (
	file   = "/host/GOBIG.ELF" // staged by the gate
	dir    = "/host/GOSYSCALL.D"
	pay    = dir + "/PAYLOAD.TXT"
	second = dir + "/SECOND.TXT"
)

const (
	payload = "gosyscall: payload 32 bytes ok!\n"
	other   = "gosyscall: second file.\n"
)

func main() {
	setup()
	rawLayer()
	osLayer()
	fmt.Println("gosyscall: GOSYSCALL OK")
}

// setup creates the directory the rest of the fixture works in, through the
// standard library. Everything after this runs against state this program
// put there, which is what makes the removes below (and the host's
// afterwards-the-fact checks) evidence rather than assertion.
func setup() {
	if err := os.Mkdir(dir, 0o755); err != nil {
		fail("os.Mkdir", err)
	}
	fmt.Println("gosyscall: os mkdir ok")

	if err := os.WriteFile(pay, []byte(payload), 0o644); err != nil {
		fail("os.WriteFile", err)
	}
	fmt.Println("gosyscall: os write PAYLOAD.TXT bytes", len(payload))
	if err := os.WriteFile(second, []byte(other), 0o644); err != nil {
		fail("os.WriteFile second", err)
	}
	fmt.Println("gosyscall: os write SECOND.TXT bytes", len(other))

	back, err := os.ReadFile(pay)
	if err != nil {
		fail("os.ReadFile", err)
	}
	if string(back) != payload {
		fmt.Println("gosyscall: os readback MISMATCH", len(back))
		os.Exit(1)
	}
	fmt.Println("gosyscall: os readback PAYLOAD.TXT ok bytes", len(back))
}

// rawLayer exercises the syscall package directly, so a failure here names
// the layer rather than the std code built on top of it.
func rawLayer() {
	fd, err := syscall.Open(file, syscall.O_RDONLY, 0)
	if err != nil {
		fail("open", err)
	}
	buf := make([]byte, 4096) // over the kernel's 2048 clamp on purpose
	n, err := syscall.Read(fd, buf)
	if err != nil {
		fail("read", err)
	}
	fmt.Println("gosyscall: read", n)

	n2, err := syscall.Read(fd, buf[:1])
	if err != nil {
		fail("second read", err)
	}
	fmt.Println("gosyscall: second read", n2, "byte", int(buf[0]))
	if err := syscall.Close(fd); err != nil {
		fail("close", err)
	}

	var st syscall.Stat_t
	if err := syscall.Stat(file, &st); err != nil {
		fail("stat", err)
	}
	fmt.Println("gosyscall: stat size", st.Size, "isdir", st.Mode&0o40000 != 0)

	var fst syscall.Stat_t
	fd2, err := syscall.Open(file, syscall.O_RDONLY, 0)
	if err != nil {
		fail("reopen", err)
	}
	if err := syscall.Fstat(fd2, &fst); err != nil {
		fail("fstat", err)
	}
	fmt.Println("gosyscall: fstat size", fst.Size)
	syscall.Close(fd2)

	dfd, err := syscall.Open(dir, syscall.O_RDONLY, 0)
	if err != nil {
		fail("open dir", err)
	}
	rows := make([]byte, 16*40)
	nr, err := syscall.ReadDirent(dfd, rows)
	if err != nil {
		fail("readdir", err)
	}
	fmt.Println("gosyscall: raw dirent bytes", nr)
	if err := syscall.Close(dfd); err != nil {
		fail("close dir", err)
	}

	if _, aerr := syscall.Open("/host/NO-SUCH-FILE.ELF", syscall.O_RDONLY, 0); aerr == nil {
		fmt.Println("gosyscall: absent none")
	} else {
		fmt.Println("gosyscall: absent", errtext(aerr))
	}
}

// osLayer is the part this card is about: the same operations through the
// standard library, where every call passes through os -> internal/poll ->
// the port's syscall package.
func osLayer() {
	f, err := os.Open(file)
	if err != nil {
		fail("os.Open", err)
	}
	h := uint32(2166136261) // FNV-1a
	var total int64
	buf := make([]byte, 4096)
	for {
		n, rerr := f.Read(buf)
		for i := 0; i < n; i++ {
			h ^= uint32(buf[i])
			h *= 16777619
		}
		total += int64(n)
		if rerr != nil {
			if rerr == io.EOF {
				break
			}
			fail("os read", rerr)
		}
	}
	f.Close()
	fmt.Printf("gosyscall: os bytes %d hash 0x%08x\n", total, h)

	st, err := os.Stat(file)
	if err != nil {
		fail("os.Stat", err)
	}
	fmt.Println("gosyscall: os stat size", st.Size(), "isdir", st.IsDir())

	small, err := os.Stat(pay)
	if err != nil {
		fail("os.Stat small", err)
	}
	fmt.Println("gosyscall: os stat PAYLOAD.TXT size", small.Size(), "isdir", small.IsDir())

	entries, err := os.ReadDir(dir)
	if err != nil {
		fail("os.ReadDir", err)
	}
	dirs, files := 0, 0
	for _, e := range entries {
		if e.IsDir() {
			dirs++
		} else {
			files++
		}
	}
	fmt.Println("gosyscall: os dir entries", len(entries), "files", files, "dirs", dirs)

	removed := 0
	for _, p := range []string{pay, second} {
		if err := os.Remove(p); err != nil {
			fail("os.Remove "+p, err)
		}
		removed++
	}
	fmt.Println("gosyscall: os remove ok", removed)

	// Re-list after the removes: the directory must now be empty. The host
	// checks the same fact from its side of the share.
	left, err := os.ReadDir(dir)
	if err != nil {
		fail("os.ReadDir after remove", err)
	}
	dirs, files = 0, 0
	for _, e := range left {
		if e.IsDir() {
			dirs++
		} else {
			files++
		}
	}
	fmt.Println("gosyscall: os dir entries", len(left), "files", files, "dirs", dirs)
}

// errtext names a failed call the way a reader can check: the Errno's own
// message, or "none" when the call unexpectedly succeeded.
func errtext(err error) string {
	if err == nil {
		return "none"
	}
	if e, ok := err.(syscall.Errno); ok {
		return e.Error()
	}
	return err.Error()
}

func fail(what string, err error) {
	fmt.Println("gosyscall: FAIL", what, errtext(err))
	os.Exit(1)
}
