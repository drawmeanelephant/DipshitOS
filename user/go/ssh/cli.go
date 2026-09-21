package main

import "strings"

const (
	defaultUser = "virelai"
	defaultPort = 22
)

type target struct {
	user string
	host string
	port uint16
	cmd  string
}

func parseTarget(args []string) (target, bool) {
	if len(args) == 0 {
		return target{}, false
	}
	user := defaultUser
	rest := args[0]
	if i := strings.IndexByte(rest, '@'); i >= 0 {
		if i == 0 || i > 64 {
			return target{}, false
		}
		user = rest[:i]
		rest = rest[i+1:]
	}
	port := uint16(defaultPort)
	if i := strings.IndexByte(rest, ':'); i >= 0 {
		p, ok := parsePort(rest[i+1:])
		if !ok {
			return target{}, false
		}
		port = p
		rest = rest[:i]
	}
	if rest == "" || len(rest) > 255 {
		return target{}, false
	}
	if !validIPv4(rest) {
		return target{}, false
	}
	cmd := ""
	if len(args) > 1 {
		cmd = strings.Join(args[1:], " ")
		if len(cmd) > 512 {
			return target{}, false
		}
	}
	return target{user: user, host: rest, port: port, cmd: cmd}, true
}

func validIPv4(text string) bool {
	if text == "" || len(text) > 15 {
		return false
	}
	n := 0
	start := 0
	for i := 0; i <= len(text); i++ {
		if i < len(text) && text[i] != '.' {
			continue
		}
		part := text[start:i]
		if len(part) == 0 || len(part) > 3 {
			return false
		}
		v := 0
		for j := 0; j < len(part); j++ {
			c := part[j]
			if c < '0' || c > '9' {
				return false
			}
			v = v*10 + int(c-'0')
		}
		if v > 255 {
			return false
		}
		n++
		start = i + 1
	}
	return n == 4
}

func parsePort(text string) (uint16, bool) {
	if text == "" || len(text) > 5 {
		return 0, false
	}
	var v int
	for i := 0; i < len(text); i++ {
		c := text[i]
		if c < '0' || c > '9' {
			return 0, false
		}
		v = v*10 + int(c-'0')
		if v > 65535 {
			return 0, false
		}
	}
	if v == 0 {
		return 0, false
	}
	return uint16(v), true
}
