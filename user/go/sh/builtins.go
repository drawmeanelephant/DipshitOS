// GOSH's builtin table — the daily-use set SH.BIN offered (M49 bar), minus
// the M68a non-goals (no vi-mode set -o, no functions/arith/conditionals).
package main

import (
	"strings"

	"virelai/vsys"
)

// parseInt is the guest-side decimal parser (the stdlib strconv is not
// ported to this GOOS). Accepts an optional sign; rejects overflow.
func parseInt(s string) (int, bool) {
	neg := false
	i := 0
	if len(s) > 0 && (s[0] == '-' || s[0] == '+') {
		neg = s[0] == '-'
		i = 1
	}
	if i >= len(s) {
		return 0, false
	}
	n := 0
	for ; i < len(s); i++ {
		c := s[i]
		if c < '0' || c > '9' {
			return 0, false
		}
		n = n*10 + int(c-'0')
		if n > 1<<30 {
			return 0, false
		}
	}
	if neg {
		n = -n
	}
	return n, true
}

var builtins map[string]func(*cmdCtx) int

func init() {
	builtins = map[string]func(*cmdCtx) int{
		"echo": bEcho, "cat": bCat, "pwd": bPwd, "cd": bCd,
		"env": bEnv, "printenv": bPrintenv, "set": bSet, "unset": bUnset,
		"export": bExport, "read": bRead, "jobs": bJobs, "fg": bFg,
		"history": bHistory, "help": bHelp, "exit": bExit, "monitor": bMonitor,
		"sleep": bSleep, "clear": bClear,
		// M50 trust surface (ADR 0024): identity, owner-only chmod, and the
		// secret store's names. Same verbs and the same output text as the
		// Zig shell, so the M50 gates retarget without weakening an assert.
		"whoami": bWhoami, "id": bID, "chmod": bChmod, "secrets": bSecrets,
	}
}

// uidSystem is the kernel's system principal (ADR 0024 D1). Duplicated here
// so the engine's output text does not depend on the guest syscall package.
const uidSystem = 0

// bWhoami prints the caller's principal, exactly as the Zig shell did:
// `uid=<n> user` (or `system`), and a refusal when the seam cannot answer.
func bWhoami(c *cmdCtx) int {
	uid, _, ok := c.sh.host.Principal()
	if !ok {
		c.out([]byte("whoami: no principal\n"))
		return 1
	}
	c.out([]byte("uid=" + vsys.Itoa64(int64(uid)) + principalKind(uid) + "\n"))
	return 0
}

// bID adds the capability mask; the M50 gate asserts it agrees with whoami.
func bID(c *cmdCtx) int {
	uid, caps, ok := c.sh.host.Principal()
	if !ok {
		c.out([]byte("id: no principal\n"))
		return 1
	}
	c.out([]byte("uid=" + vsys.Itoa64(int64(uid)) + principalKind(uid) +
		" caps=" + vsys.Itoa64(int64(caps)) + "\n"))
	return 0
}

func principalKind(uid uint32) string {
	if uid == uidSystem {
		return " system"
	}
	return " user"
}

// bChmod forwards an owner-only mode change through slot 69. The kernel is
// the authority on ownership and on the group triplet; the shell only parses
// the octal mode and reports the kernel's own errno name.
func bChmod(c *cmdCtx) int {
	if len(c.args) < 2 {
		c.out([]byte("chmod: usage: chmod MODE FILE\n"))
		return 1
	}
	mode, ok := parseOctMode(c.args[0])
	if !ok {
		c.out([]byte("chmod: invalid mode (use octal, e.g. 600)\n"))
		return 1
	}
	file := c.args[1]
	if err := c.sh.host.Chmod(file, mode); err != nil {
		if oe, denial := deniedAs(err); denial {
			c.out([]byte("chmod: " + oe.path + ": " + oe.name + "\n"))
		} else {
			c.out([]byte("chmod: " + file + ": " + err.Error() + "\n"))
		}
		return 1
	}
	c.out([]byte("chmod: ok\n"))
	return 0
}

// bSecrets lists the CALLER's store entry names (slot 70). Values never
// travel through this seam, so the never-logged contract holds here too
// (ADR 0024 D8).
func bSecrets(c *cmdCtx) int {
	names, ok := c.sh.host.SecretNames()
	if !ok {
		c.out([]byte("secrets: unavailable\n"))
		return 1
	}
	if len(names) == 0 {
		c.out([]byte("secrets: (none)\n"))
		return 0
	}
	for _, n := range names {
		c.out([]byte("  " + n + "\n"))
	}
	return 0
}

// parseOctMode parses a 1..4 digit octal mode (e.g. `600`, `0600`, `644`),
// bounded to the permission bits. The kernel re-validates.
func parseOctMode(s string) (uint16, bool) {
	if len(s) == 0 || len(s) > 4 {
		return 0, false
	}
	var v uint16
	for i := 0; i < len(s); i++ {
		ch := s[i]
		if ch < '0' || ch > '7' {
			return 0, false
		}
		v = v*8 + uint16(ch-'0')
	}
	if v > 0o777 {
		return 0, false
	}
	return v, true
}

func bEcho(c *cmdCtx) int {
	args := c.args
	nl := true
	if len(args) > 0 && args[0] == "-n" {
		nl = false
		args = args[1:]
	}
	c.out([]byte(strings.Join(args, " ")))
	if nl {
		c.out([]byte("\n"))
	}
	return 0
}

// bCat prints bound stdin, or the named files. `cat` with no redirect only
// makes sense with `< FILE` (SH.BIN's builtin behaves the same way).
func bCat(c *cmdCtx) int {
	if len(c.args) == 0 {
		c.out(c.stdin)
		return 0
	}
	for _, f := range c.args {
		b, err := c.sh.readBounded(f)
		if err != nil {
			if err == errTooLarge {
				c.out([]byte("gosh: cat: " + f + ": " + errTooLarge.Error() + "\n"))
				return 1
			}
			c.out([]byte(openDenial(f, err)))
			return 1
		}
		c.out(b)
	}
	return 0
}

func bPwd(c *cmdCtx) int {
	v, _ := c.sh.env.Get("PWD")
	c.out([]byte(v + "\n"))
	return 0
}

func bCd(c *cmdCtx) int {
	target := "/"
	if len(c.args) > 0 {
		target = c.args[0]
	}
	if err := c.sh.host.Chdir(target); err != nil {
		if oe, denial := deniedAs(err); denial {
			c.out([]byte("gosh: cd: " + oe.path + ": " + oe.name + "\n"))
		} else {
			c.out([]byte("gosh: cd: " + target + ": not a directory\n"))
		}
		return 1
	}
	c.sh.env.Set("PWD", target)
	return 0
}

func bEnv(c *cmdCtx) int {
	for _, v := range c.sh.env.List() {
		c.out([]byte(v.name + "=" + v.val + "\n"))
	}
	return 0
}

func bPrintenv(c *cmdCtx) int {
	missing := false
	if len(c.args) == 0 {
		return bEnv(c)
	}
	for _, name := range c.args {
		if v, ok := c.sh.env.Get(name); ok {
			c.out([]byte(v + "\n"))
		} else {
			missing = true
		}
	}
	if missing {
		return 1
	}
	return 0
}

func bSet(c *cmdCtx) int {
	if len(c.args) == 0 {
		for _, v := range c.sh.env.List() {
			c.out([]byte(v.name + "=" + v.val + "\n"))
		}
		return 0
	}
	if c.args[0] == "-o" {
		c.out([]byte("gosh: set -o is not supported (no vi mode)\n"))
		return 1
	}
	eq := strings.IndexByte(c.args[0], '=')
	if eq <= 0 {
		c.out([]byte("gosh: set NAME=VALUE\n"))
		return 2
	}
	c.sh.env.Set(c.args[0][:eq], c.args[0][eq+1:])
	return 0
}

func bUnset(c *cmdCtx) int {
	if len(c.args) == 0 {
		c.out([]byte("gosh: unset NAME\n"))
		return 2
	}
	c.sh.env.Unset(c.args[0])
	return 0
}

func bExport(c *cmdCtx) int {
	if len(c.args) == 0 {
		for _, v := range c.sh.env.List() {
			if v.exported {
				c.out([]byte("export " + v.name + "=" + v.val + "\n"))
			}
		}
		return 0
	}
	eq := strings.IndexByte(c.args[0], '=')
	if eq < 0 {
		if !c.sh.env.Export(c.args[0]) {
			c.out([]byte("gosh: export: " + c.args[0] + ": not set\n"))
			return 1
		}
		return 0
	}
	if eq == 0 {
		c.out([]byte("gosh: export NAME=VALUE\n"))
		return 2
	}
	c.sh.env.Set(c.args[0][:eq], c.args[0][eq+1:])
	c.sh.env.Export(c.args[0][:eq])
	return 0
}

// bRead takes one line from bound stdin (a pipe or redirect), or from the
// terminal when stdin is unbound, into the named variable.
func bRead(c *cmdCtx) int {
	if len(c.args) != 1 {
		c.out([]byte("gosh: read VAR\n"))
		return 2
	}
	var line string
	ok := false
	if c.stdin != nil {
		if i := strings.IndexByte(string(c.stdin), '\n'); i >= 0 {
			line, ok = string(c.stdin[:i]), true
		} else {
			line, ok = string(c.stdin), true
		}
	} else {
		line, ok = c.sh.host.ReadTTYLine()
	}
	if !ok {
		return 1
	}
	c.sh.env.Set(c.args[0], strings.TrimSuffix(line, "\r"))
	return 0
}

// bJobs lists the job table; finished jobs are reported once and removed.
func bJobs(c *cmdCtx) int {
	c.sh.ReapJobs()
	for _, j := range append([]*Job{}, c.sh.jobs...) {
		if j.Done {
			c.out([]byte("[" + vsys.Itoa64(int64(j.N)) + "] Done: " + j.Display +
				" (exit=" + vsys.Itoa64(j.Status) + ")\n"))
			c.sh.removeJob(j)
		} else {
			c.out([]byte("[" + vsys.Itoa64(int64(j.N)) + "] running: " + j.Display + "\n"))
		}
	}
	return 0
}

// bFg waits for one background job and propagates its exit status into $?.
// There is no `bg` to return to (nothing suspends a guest job) and no
// `wait` for the table as a whole — fg is the way you wait, the same
// contract the kernel monitor's job table documents.
func bFg(c *cmdCtx) int {
	if len(c.args) != 1 {
		c.out([]byte("gosh: fg N\n"))
		return 2
	}
	id := strings.TrimPrefix(c.args[0], "%")
	n, ok := parseInt(id)
	if !ok {
		c.out([]byte("gosh: fg N\n"))
		return 2
	}
	j := c.sh.jobByN(n)
	if j == nil {
		c.out([]byte("fg: no such job\n"))
		return 1
	}
	for !j.Done {
		c.sh.ReapJobs()
		if j.Done {
			break
		}
		c.sh.host.SleepTick()
	}
	c.out([]byte("[" + vsys.Itoa64(int64(j.N)) + "] Done: " + j.Display +
		" (exit=" + vsys.Itoa64(j.Status) + ")\n"))
	c.sh.removeJob(j)
	return int(j.Status)
}

func bHistory(c *cmdCtx) int {
	for i, h := range c.sh.hist.Entries() {
		c.out([]byte(vsys.Itoa64(int64(i+1)) + "  " + h + "\n"))
	}
	return 0
}

func bHelp(c *cmdCtx) int {
	c.out([]byte(
		"builtins: " + strings.Join(builtinNames(), " ") + "\n" +
			"tools: " + strings.Join(toolNames(), " ") + "\n" +
			"externals: exec NAME [args...]  (& backgrounds it; jobs/fg track it)\n" +
			"subset: one pipe per line, > >> < redirects, $VAR ${VAR} $?\n"))
	return 0
}

func bExit(c *cmdCtx) int {
	c.sh.exitReq = true
	if len(c.args) > 0 {
		if n, ok := parseInt(c.args[0]); ok {
			return n
		}
		c.out([]byte("gosh: exit [status]\n"))
		return 2
	}
	return c.sh.status
}

func bMonitor(c *cmdCtx) int {
	c.sh.monitorRq = true
	return 0
}

// bSleep parks the shell for about n seconds (the scheduler runs at about
// 100 Hz; the glue converts seconds to ticks). Bound at 60 so a typo can
// not wedge the front-end forever.
func bSleep(c *cmdCtx) int {
	if len(c.args) != 1 {
		c.out([]byte("gosh: sleep SECONDS\n"))
		return 2
	}
	n, ok := parseInt(c.args[0])
	if !ok || n < 0 || n > 60 {
		c.out([]byte("gosh: sleep 0..60\n"))
		return 2
	}
	if n > 0 {
		c.sh.host.SleepSeconds(n)
	}
	return 0
}

func bClear(c *cmdCtx) int {
	c.out([]byte("\x1b[2J\x1b[H"))
	return 0
}
