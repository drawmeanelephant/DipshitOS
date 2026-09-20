// The socket-shaped syscall surface, for GOOS=virelai.
//
// internal/poll's FD type is one type for files AND sockets: its Accept,
// Recvfrom, Sendto, Recvmsg, SendmsgN and Shutdown methods compile on every
// unix-shaped GOOS whether or not the platform has sockets. This GOOS has
// none — the kernel's slot table (ADR 0007) has no socket, bind, listen or
// connect — so the types exist for the compiler and every operation refuses.
//
// The types are the POSIX shapes on purpose: poll hands their field
// addresses to nothing (it cannot, since the calls refuse), but net-shaped
// code and the guest SDK read Addr/Port, and a member layout that disagreed
// with what a caller expects would be a silent lie rather than a loud one.
package syscall

// Iovec is the scatter/gather element internal/poll caches per descriptor.
type Iovec struct {
	Base *byte
	Len  uint64
}

func (iov *Iovec) SetLen(length int) { iov.Len = uint64(length) }

// SockaddrInet4/6 are storage for addresses this GOOS cannot produce.
type SockaddrInet4 struct {
	Port int
	Addr [4]byte
}

func (sa *SockaddrInet4) sockaddr() {}

type SockaddrInet6 struct {
	Port   int
	ZoneId uint32
	Addr   [16]byte
}

func (sa *SockaddrInet6) sockaddr() {}

// The socket operations. Each is ENOSYS rather than a zero result: a caller
// that reads a byte count of 0 believes it hit EOF, and there is no socket to
// hit EOF on.
func Accept4(fd int, flags int) (nfd int, sa Sockaddr, err error) { return -1, nil, ENOSYS }
func Shutdown(fd int, how int) error                              { return ENOSYS }

func Recvfrom(fd int, p []byte, flags int) (n int, from Sockaddr, err error) {
	return 0, nil, ENOSYS
}

func Sendto(fd int, p []byte, flags int, to Sockaddr) error { return ENOSYS }

func Recvmsg(fd int, p, oob []byte, flags int) (n, oobn, recvflags int, from Sockaddr, err error) {
	return 0, 0, 0, nil, ENOSYS
}

func SendmsgN(fd int, p, oob []byte, to Sockaddr, flags int) (n int, err error) {
	return 0, ENOSYS
}

// Pread/Pwrite would need a seek slot to address an offset; the kernel's file
// channel is cursor-based (sequential, and its cursor is the kernel's own),
// so an offset read is refused rather than silently turned into a sequential
// one — that mistake returns the WRONG BYTES instead of an error.
func Pread(fd int, p []byte, offset int64) (n int, err error)  { return 0, ENOSYS }
func Pwrite(fd int, p []byte, offset int64) (n int, err error) { return 0, ENOSYS }

// No socket seam exists, so the connection-shaped errors cannot be produced
// here. They are defined because std compares against them (net, internal/poll
// and os's error classification) and a missing constant would read as a
// compile error rather than as "this GOOS has no sockets", which is the fact.
const (
	EADDRINUSE      Errno = 26
	EADDRNOTAVAIL   Errno = 27
	EAFNOSUPPORT    Errno = 28
	ECONNABORTED    Errno = 29
	ECONNREFUSED    Errno = 30
	ECONNRESET      Errno = 31
	EHOSTUNREACH    Errno = 32
	EINPROGRESS     Errno = 33
	EISCONN         Errno = 34
	ENETDOWN        Errno = 35
	ENETUNREACH     Errno = 36
	ENOTCONN        Errno = 37
	EOPNOTSUPP      Errno = 38
	ENOTSUP         Errno = 38 // the same refusal, spelled as os does
	EPROTONOSUPPORT Errno = 39
)
