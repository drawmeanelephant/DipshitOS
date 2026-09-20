// M70c-S1P (#1525) fixture: the new GOOS=virelai std layer, exercised in the
// guest through `os` and `fmt` — not through the guest SDK.
//
// This is the first program on this operating system whose file I/O goes
// through Go's *standard library*: `fmt` into `os.Stdout`, `os.Open`/`Read`
// for the bytes, `os.ReadDir` for a listing, `os.WriteFile`/`ReadFile` for a
// round trip. Everything below the surface is the port landed by this card —
// syscall.Open/Read/Write/Close/Stat/ReadDirent over the ADR 0007 slots,
// `internal/poll`'s FD, and `internal/syscall/unix`'s path helpers.
//
// What each line proves:
//
//	read 2048        one sequential read at the handle's cursor, clamped to
//	                 the kernel's per-call bound, i.e. the raw read path.
//	second read 1    the next read continues the file (checked against the
//	                 staged file on macOS: a layer that re-read page one
//	                 would print the ELF magic's second byte again).
//	stat size N      Stat has no slot: N comes from a sys_dir_list row on the
//	                 entry's PARENT, so the parent-listing route is real.
//	fstat size N     Fstat resolves the handle back to the path the port
//	                 remembered, then to the same row.
//	dirent bytes N   this port's directory rows reach os's readdir.
//	absent ENOENT    the errno mapping on a path that really is absent,
//	                 printed through the Errno's own Error().
//	os bytes/hash    the WHOLE 9.5 MiB image read through os.File and folded
//	                 into FNV-1a — the host checks the hash, so this is the
//	                 end-to-end proof of os+internal/poll+syscall together.
//	os dir entries N os.ReadDir over the share, i.e. the listing again but
//	                 through os's own DirEntry construction.
//	os write/read    os.WriteFile then os.ReadFile of the same bytes: the
//	                 create/truncate translation and the write slot.
//	os remove        os.Remove, i.e. the delete slot through the *openat path.
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
	file = "/host/GOBIG.ELF" // staged by the gate
	dir  = "/host"
	tmp  = "/host/GOSYSCALL.TXT"
)

func main() {
	rawLayer()
	osLayer()
	fmt.Println("gosyscall: GOSYSCALL OK")
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
	fmt.Println("gosyscall: dirent bytes", nr)
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

	const payload = "gosyscall: payload 32 bytes ok!\n"
	if err := os.WriteFile(tmp, []byte(payload), 0o644); err != nil {
		fail("os.WriteFile", err)
	}
	back, err := os.ReadFile(tmp)
	if err != nil {
		fail("os.ReadFile", err)
	}
	if string(back) != payload {
		fmt.Println("gosyscall: os write MISMATCH", len(back))
		os.Exit(1)
	}
	fmt.Println("gosyscall: os write ok bytes", len(back))
	if err := os.Remove(tmp); err != nil {
		fail("os.Remove", err)
	}
	fmt.Println("gosyscall: os remove ok")
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
