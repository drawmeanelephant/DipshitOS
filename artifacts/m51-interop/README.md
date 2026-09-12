# M51 real-OpenSSH interop evidence — issues #1209/#1210 (goal #1066, ADR 0025 D8)

Date: 2026-09-12. Host: macOS 27.0 (26A428), arm64. Revision: `#1209` ran on
`t3code/m51-interop`; `#1210` ran on `t3code/m51-ssh-padding`.
Server: `/usr/sbin/sshd` from Apple's OpenSSH_10.3p1 (LibreSSL 3.3.6),
started non-root on port 2222 with `sshd/sshd_config`, a generated
ssh-ed25519 host key, and the RFC 8032 TEST 2 client key in
`sshd/authorized_keys`. Client seed provisioned via `share/SECRETS.TXT`;
host-key pin via `share/SSH/KNOWN_HOSTS` (see `sshd-hostpin.txt`).

This is a documented manual check (ADR 0025 D8), NOT a CI gate. The full
analysis lives in ADR 0025 D8 and `docs/ssh-scoping.md`.

## Result (claim #1210): OBSERVED end to end against real OpenSSH

After the #1210 padding realignment (and two further real-server fixes it
exposed — see below), the canonical run is `runs/relay-06/` (raw
`vm-serial.log`, `run.out`, `sshd.log` DEBUG3, `cap.bin`, scripts, and
`seed-absence-check.txt`; all small enough to commit in full):

- `exec SSH.BIN tbuddy@10.0.0.2:2222 echo VIRELAI-INTEROP-OK` →
  `ssh: kex-ok` → `ssh: pin-ok` → `ssh: auth-ok method=publickey` →
  `ssh: channel-open remote=0` → **remote stdout `VIRELAI-INTEROP-OK`** →
  `ssh: eof` → `ssh: exit-status=0` → `ssh: bye rc=0`.
- Real sshd's DEBUG3 log shows `Accepted publickey ... port 64116`, the
  session channel open, the `exec` request with `exit 0`, and a clean
  close. Runner rc=0 (`interop-relay-done` observed).
- The client seed appears in **no** log (`seed-absence-check.txt`).
- The three class-B gates re-ran green with the realigned responder:
  `gates/live-ssh-endpoint-rerun.txt` (PASS 1/1),
  `gates/live-ssh-negative-rerun.txt` (PASS 3/3),
  `gates/live-ssh-packet-rerun.txt` (PASS 1/1).

The fix: `packet.Alignment` selects the padding rule by cipher
(`.plaintext` `4 + packet_length` for KEX, `.aead` `packet_length % 8 == 0`
for `chacha20-poly1305@openssh.com`), mirrored in VSSH. The same run then
exposed two more real-server gaps, both fixed with class-A vectors:
`channel.open()` rejected OpenSSH's pre-confirmation
`hostkeys-00@openssh.com` GLOBAL_REQUEST (it carries request-specific
host-key data; RFC 4254 §4 says ignore it) and treated sender channel id
**0** as "unset". Progression runs: `runs/relay-03/` (padding fixed,
userauth accepted; channel-stage `Protocol`), `runs/relay-04/` (global
request with data still failing), `runs/relay-05/` (channel id 0 rejected).

## History: the #1209 run (transport proved, one padding gap)

- VZ-NAT guest→host TCP is a dead end on this host (evidence:
  `runs/nat-*/`, `runs/nat-debug/host-observations.txt`). While the VM ran,
  no host interface carried the guest subnet (`vmenet0` inactive, no
  address), there was no host route/ARP entry for 192.168.64.0/24, the
  gateway MAC was synthetic, the macOS firewall was OFF, and sshd at
  DEBUG3 logged **no** connection while both SSH.BIN and the monitor's own
  `net tcp connect` sat in SYN_SENT.
- The interop therefore ran over a new byte-transparent runner relay
  (`--net-tcp-respond 10.0.0.2:2222:relay --net-tcp-respond-relay
  127.0.0.1:2222`; no crypto in the runner): `runs/relay-02/`.
- Observed against real OpenSSH: KEX negotiated `curve25519-sha256` +
  `ssh-ed25519` + `chacha20-poly1305@openssh.com`, no compression, and the
  client verified the real server's host-key signature against the pin
  (`ssh: kex-ok` in `runs/relay-02/vm-serial.log`, KEX proposal lines in
  `runs/relay-02/sshd-log-delta.txt`).
- Real sshd then rejected the FIRST encrypted packet
  (`SSH2_MSG_SERVICE_REQUEST`) with
  `padding error: need 28 block 8 mod 4`,
  `sshpkt_disconnect: sending SSH2_MSG_DISCONNECT: Packet corrupt`,
  `message authentication code incorrect`. **Userauth, the remote stdout
  and `exit-status` were NOT observed.**
- Root cause (verified against openssh-portable `packet.c`): for
  `chacha20-poly1305@openssh.com` OpenSSH pads so `packet_length` — the
  encrypted part after the 4-byte length field — is a multiple of the
  cipher block size (8); the client and VSSH aligned `4 + packet_length`
  (the RFC 4253 §6 plaintext rule, which is why KEX completed). For the
  observed SERVICE_REQUEST the client sent `packet_length=28` where
  OpenSSH requires a multiple of 8 (24).
- The client seed never appears in the serial, runner, or sshd logs
  (`runs/relay-02/seed-absence-check.txt`).

## File map

- `setup-sshd.sh` — regenerates keys/config/share, prints the pin.
- `sshd/sshd_config`, `sshd/authorized_keys` — server config and public keys
  (private keys are intentionally not committed).
- `sshd.log` — full sshd DEBUG3 log (host sanity check + relay runs).
- `sshd-hostpin.txt` — the real server's host-key pin used in KNOWN_HOSTS.
- `runs/nat-01/`, `runs/nat-lan/` — VZ-NAT reachability attempts (monitor
  probe and guest→host-LAN).
- `runs/nat-debug/` — VM-alive host observations: `host-observations.txt`.
- `runs/relay-01/` — first relay run (guest KEX stalled; blocking relay).
- `runs/relay-02/` — #1209 canonical run: real OpenSSH KEX + padding
  rejection, `sshd-log-delta.txt`, `seed-absence-check.txt`, `cap.bin`
  (guest frames). The committed `vm-serial.head.log` / `run.out.head.txt`
  carry everything through the sshd disconnect; the full 100k-line
  originals (the tail is periodic kernel worker output with no SSH
  content) are left on disk in the worktree, untracked.
- `runs/relay-03/` … `runs/relay-05/` — #1210 progression: padding fixed +
  userauth accepted (`03`), pre-confirmation GLOBAL_REQUEST with data still
  failing (`04`), sender channel id 0 still rejected (`05`). The run-local
  132 KiB serial/runner logs are not committed; each dir carries
  `ssh-evidence.txt` (the exact SSH/relay/sshd grep extract of those logs)
  plus the full `sshd.log` DEBUG3 and guest `cap.bin`.
- `runs/relay-06/` — #1210 canonical success: full raw evidence (serial,
  runner stdout, sshd DEBUG3, `cap.bin`, scripts, seed-absence scan, and
  `sshd_config.used`, the exact config the run's sshd was started with).
- `gates/` — post-change re-runs: `live-ssh-endpoint-rerun.log` /
  `live-ssh-negative-rerun.log` from #1209, plus
  `live-ssh-endpoint-rerun-1210.txt` (PASS 1/1),
  `live-ssh-negative-rerun-1210.txt` (PASS 3/3) and
  `live-ssh-packet-rerun-1210.txt` (PASS 1/1) from #1210, and the
  gate-inventory check.
