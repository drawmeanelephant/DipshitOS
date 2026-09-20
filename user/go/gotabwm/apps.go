// GOTABWM.ELF — M69c2 (#1535): parse /host/APPS.TXT. The manifest is the
// catalog (D2): no second hardcoded app list. Wire format matches the M13
// line `NAME | Display Name | icon | dock=true`. Pure so the host tests pin
// it without a guest.
package main

// AppEntry is one catalog row. Bin is the executable name on the share.
type AppEntry struct {
	Bin   string
	Label string
	Icon  byte
	Dock  bool
}

const (
	appsMax      = 24
	appsMaxBytes = 4096
	appsPath     = "/host/APPS.TXT"
)

// parseAppsTXT decodes the M13 manifest. `#` comments and blank lines are
// skipped. Entries are capped at appsMax. Slices alias `text`.
func parseAppsTXT(text string) []AppEntry {
	var out []AppEntry
	rest := text
	for len(rest) > 0 && len(out) < appsMax {
		var line string
		line, rest = cutLine(rest)
		line = trimSpace(trimCR(line))
		if line == "" || hasPrefix(line, "#") {
			continue
		}
		e, ok := parseAppLine(line)
		if ok {
			out = append(out, e)
		}
	}
	return out
}

func parseAppLine(line string) (AppEntry, bool) {
	fields := splitPipe(line)
	if len(fields) < 2 {
		return AppEntry{}, false
	}
	bin := trimSpace(fields[0])
	label := trimSpace(fields[1])
	if bin == "" || label == "" {
		return AppEntry{}, false
	}
	icon := byte('?')
	if len(fields) >= 3 {
		ic := trimSpace(fields[2])
		if len(ic) > 0 {
			icon = ic[0]
		}
	}
	dock := false
	if len(fields) >= 4 {
		dock = trimSpace(fields[3]) == "dock=true"
	}
	return AppEntry{Bin: bin, Label: label, Icon: icon, Dock: dock}, true
}

func filterApps(catalog []AppEntry, q string) []int {
	var idx []int
	for i, e := range catalog {
		if q == "" || asciiContainsFold(e.Bin, q) || asciiContainsFold(e.Label, q) {
			idx = append(idx, i)
		}
	}
	return idx
}

func trimCR(s string) string {
	if len(s) > 0 && s[len(s)-1] == '\r' {
		return s[:len(s)-1]
	}
	return s
}

func trimSpace(s string) string {
	i, j := 0, len(s)
	for i < j && (s[i] == ' ' || s[i] == '\t') {
		i++
	}
	for j > i && (s[j-1] == ' ' || s[j-1] == '\t') {
		j--
	}
	return s[i:j]
}

func hasPrefix(s, p string) bool {
	return len(s) >= len(p) && s[:len(p)] == p
}

func splitPipe(s string) []string {
	n := 1
	for i := 0; i < len(s); i++ {
		if s[i] == '|' {
			n++
		}
	}
	out := make([]string, 0, n)
	start := 0
	for i := 0; i < len(s); i++ {
		if s[i] == '|' {
			out = append(out, s[start:i])
			start = i + 1
		}
	}
	return append(out, s[start:])
}

func asciiFold(c byte) byte {
	if c >= 'A' && c <= 'Z' {
		return c + ('a' - 'A')
	}
	return c
}

// asciiContainsFold is a substring search that folds A–Z only. HID type-in
// is lowercase ASCII. strings.ToLower pulls unicode case tables into the
// writable segment and pushes memsz%4096 past 1792, so mallocinit dies
// with "cannot allocate memory" (the GOEDIT / vsys clipboard wall).
func asciiContainsFold(s, q string) bool {
	if q == "" {
		return true
	}
	if len(q) > len(s) {
		return false
	}
	n := len(s) - len(q)
	for i := 0; i <= n; i++ {
		ok := true
		for j := 0; j < len(q); j++ {
			if asciiFold(s[i+j]) != asciiFold(q[j]) {
				ok = false
				break
			}
		}
		if ok {
			return true
		}
	}
	return false
}
