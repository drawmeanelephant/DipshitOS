# live-net-dns.spec -- the bounded DNS client live: two A-record
# queries answered by the host responder, parsed and extracted in
# the guest, with the resolver counters to prove it.
# Mirrors tools/verify-live-net-dns.sh (claim 7566, card N2, issue #149).

vgate_name live-net-dns "bounded DNS client A-record queries live on VZ"
vgate_fmt boot/src/*.zig kernel/src/*.zig build.zig

vgate_file script-1.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
net dns example.com 10.0.0.2
net dns myhost.local 10.0.0.2
net
echo net-dns-ok
EOF

vgate_run 01 -- --net '$RUN_DIR/cap.bin' --net-arp-respond 10.0.0.2 --net-dns-respond 10.0.0.2:53 --script '$RUN_DIR/script-1.txt' --script-expect 'net-dns-ok' --timeout 60

vgate_assert 01 serial-contains 'net ip: ip=10.0.0.1'
vgate_assert 01 serial-contains 'net dns: example.com -> 93.184.216.34'
vgate_assert 01 serial-contains 'net dns: myhost.local -> 10.0.0.2'
vgate_assert 01 serial-contains 'dns=resolved,q=2,r=2,err=0,timeout=0'
vgate_assert 01 output-contains "NET-DNS: answered the guest's DNS query for 'example.com'"
vgate_assert 01 output-contains "NET-DNS: answered the guest's DNS query for 'myhost.local'"
vgate_assert 01 output-contains 'net-dns-respond: ENABLED'
