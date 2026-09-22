package main

// linkFile is the article URL handed to WEB.ELF. The exec argument is the
// short "@" + path form; the kernel keeps 31 bytes of each argument, and an
// article link does not fit.
const (
	linkFile   = "/host/RSS.LINK"
	execArgMax = 31
)

// browserHandoff splits an article link into the file WEB.ELF reads and the
// single exec argument that names it. ok is false when the link is empty or
// the argument itself would be truncated.
func browserHandoff(link string) (path string, body []byte, arg string, ok bool) {
	if link == "" {
		return "", nil, "", false
	}
	arg = "@" + linkFile
	if len(arg) > execArgMax {
		return "", nil, "", false
	}
	body = make([]byte, len(link)+1)
	copy(body, link)
	body[len(link)] = '\n'
	return linkFile, body, arg, true
}
