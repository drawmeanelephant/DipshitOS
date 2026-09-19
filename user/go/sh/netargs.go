// `net [port] [open]` argv parser — the same grammar SH.BIN and TERM.BIN
// accepted (user/src/lib/netargs.zig, ADR 0024 D6). port defaults to 2323.
// Without `open` the caller must have a credential in the TS5 store.
package main

const defaultNetPort uint16 = 2323

type netArgs struct {
	port uint16
	open bool
}

// parseNetArgs reads `net [port] [open]` from argv. ok is false when the
// first word is not `net` (the caller then uses its default front-end).
// err is set when the verb is present but the rest is malformed (bad port
// or an unknown mode word) — the caller refuses rather than attaching.
func parseNetArgs(args []string) (na netArgs, ok bool, err string) {
	words := skipArgv0(args)
	if len(words) == 0 || words[0] != "net" {
		return netArgs{}, false, ""
	}
	na.port = defaultNetPort
	if len(words) >= 2 && words[1] != "" {
		p, good := parseUint16(words[1])
		if !good {
			return netArgs{}, false, "bad port"
		}
		na.port = p
	}
	if len(words) >= 3 && words[2] != "" {
		if words[2] != "open" {
			return netArgs{}, false, "unknown mode"
		}
		na.open = true
	}
	return na, true, ""
}

// skipArgv0 drops the program name when it is present. `net`, `serial` and
// `-c` can be argv[0] if the exec seam omitted the image name, so those
// stay.
func skipArgv0(args []string) []string {
	if len(args) == 0 {
		return args
	}
	switch args[0] {
	case "net", "serial", "-c":
		return args
	}
	return args[1:]
}

func parseUint16(s string) (uint16, bool) {
	n, ok := parseInt(s)
	if !ok || n < 0 || n > 65535 {
		return 0, false
	}
	return uint16(n), true
}
