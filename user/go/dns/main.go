// Command dns is GODNS.ELF, the M78a Go replacement for DNS.BIN.
// RFC 1035 framing, UDP bounds, resolver deadlines, and refusal behavior are
// provided by the existing guest Go network layer (vi.ResolveDNS).
package main

import (
	"virelai/vi"
	"virelai/vsys"
)

const (
	appName     = "GODNS.ELF"
	dnsPort     = 53
	exitOK      = 0
	exitUsage   = 2
	exitFailure = 1
)

// Preserve space for the kernel's fixed argv/envp block in the writable
// segment so the guest Go runtime can initialize its heap.
var argvEnvpGuard [0x1000]byte

type dnsArgs struct {
	host   string
	server [4]byte
	help   bool
}

func cliArgs(raw []string) []string {
	if len(raw) > 0 && raw[0] == appName {
		return raw[1:]
	}
	return raw
}

func parseArgs(raw []string) (dnsArgs, bool) {
	args := cliArgs(raw)
	if len(args) == 0 {
		return dnsArgs{help: true}, true
	}
	if len(args) == 1 && (args[0] == "-h" || args[0] == "--help") {
		return dnsArgs{help: true}, true
	}
	if len(args) < 1 || len(args) > 2 || args[0] == "-h" || args[0] == "--help" {
		return dnsArgs{}, false
	}
	server := vi.DefaultDNSServer
	if len(args) == 2 {
		parsed, err := vsys.ParseIPv4(args[1])
		if err != nil {
			return dnsArgs{}, false
		}
		server = parsed
	}
	return dnsArgs{host: args[0], server: server}, true
}

func usage() {
	vi.Console("GODNS.ELF - VirelaiOS DNS A-record query\n" +
		"usage: exec GODNS.ELF <hostname> [<server_ip>]\n" +
		"       exec GODNS.ELF -h   show this help\n" +
		"example: exec GODNS.ELF example.com 10.0.0.2\n")
}

func main() {
	argvEnvpGuard[0] = 1
	cfg, ok := parseArgs(vi.Args())
	if !ok {
		vi.Console("dns: usage: exec GODNS.ELF <hostname> [<server_ip>]\n")
		vi.Exit(exitUsage)
	}
	if cfg.help {
		usage()
		vi.Exit(exitOK)
	}
	server := vi.FormatIPv4(cfg.server)
	vi.ConsoleLine("DNS query for " + cfg.host + " via " + server + ":53")
	ip, err := vi.ResolveDNS(cfg.host, cfg.server, 0)
	if err != nil {
		vi.ConsoleLine("dns: error: " + err.Error())
		vi.ConsoleLine("dns: status=err")
		vi.Exit(exitFailure)
	}
	// ResolveDNS returns the A address, not a TTL. Do not invent one.
	vi.ConsoleLine("Answer: " + cfg.host + " -> " + vi.FormatIPv4(ip) + " (TTL unavailable)")
	vi.ConsoleLine("dns: status=ok")
	vi.Exit(exitOK)
}
