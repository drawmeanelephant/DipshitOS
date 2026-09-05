# live-xhci.spec -- claim 4272 (milestone seven, card I1) class-B
#
# gate: the XHCI host-controller transport on real VZ hardware.
#
# Mechanism: the runner's --input flag (milestone seven I1) attaches the
# keyboard + pointing devices (VZUSBKeyboardConfiguration +
# VZUSBScreenCoordinatePointingDeviceConfiguration). Claim 3868 established
# that these present to the guest NOT as a virtio-input device (DID 0x1052)
# but as an Apple XHCI USB host controller — PCI VID=0x106b DID=0x1a06

vgate_name live-xhci "claim 4272 (milestone seven, card I1) class-B"

vgate_file script.txt <<'EOF'
usb
echo xhci-obs-done
EOF

vgate_run 01 -- --input --script '$RUN_DIR/script.txt' --script-expect "xhci-obs-done" --timeout 40

vgate_assert 01 serial-absent 'xhci: init ok base=0x0000000050001000'
vgate_assert 01 serial-absent 'usb: did=0x0000000000001a06 class=0x00000000000c0330 dev=8'
vgate_assert 01 serial-absent 'usb: bar0=0x0000000050001000 bar1=0x0000000050000000 base=0x0000000050001000'
vgate_assert 01 serial-absent 'usb: caplen=0x0000000000000020 hciver=0x0000000000000110 dboff=0x0000000000000940 rtsoff=0x0000000000000520'
vgate_assert 01 serial-contains 'usb: maxslots=16 maxintrs=32 maxports=16'
vgate_assert 01 serial-absent 'usb: pre-reset sts=0x0000000000000009 cmd=0x0000000000000000'
vgate_assert 01 serial-absent 'usb: usbsts=0x0000000000000000 noop_cc=0x0000000000000001 noop=ok'
vgate_assert 01 serial-contains 'usb: port9='
vgate_assert 01 serial-contains 'usb: port10='
vgate_assert 01 serial-absent 'usb: port1='
vgate_assert 01 serial-absent 'usb: port16=0x00000000000202a0 ccs=0 ped=0 pp=1'
vgate_assert 01 serial-contains 'xhci-obs-done'
vgate_assert 01 serial-absent '[EXC] parking:'
