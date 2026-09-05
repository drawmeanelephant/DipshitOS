# live-usb.spec -- claim 4116 (milestone seven, card I2) class-B gate:
#
# USB enumeration + HID over the XHCI transport on real VZ hardware.
#
# Mechanism: the runner's --input flag attaches the keyboard + pointing
# devices (VZUSBKeyboardConfiguration +
# VZUSBScreenCoordinatePointingDeviceConfiguration). Claim 3868 established
# these present as an Apple XHCI USB controller (DID 0x1a06) with the two HID
# devices behind it; I1 (claim 4272) built the controller's register-map +

vgate_name live-usb "claim 4116 (milestone seven, card I2) class-B gate:"

vgate_file script.txt <<'EOF'

usb devices
usb report
echo usb-gate-ok
EOF

vgate_run 01 -- --input --display --input-key 0 --input-key-after "usb devices: count=" --script '$RUN_DIR/script.txt' --script-expect "usb-gate-ok" --timeout 40

vgate_assert 01 serial-absent 'usb: enumerated=0x0000000000000002 ok'
vgate_assert 01 serial-contains 'usb devices: count=2'
vgate_assert 01 serial-absent 'usb dev0: slot=1 port=9 speed=1 vid=0x5ac pid=0x8105 class=0 protocol=1 epin=1 maxpkt=8 interval=8 boot=1'
vgate_assert 01 serial-absent 'usb dev1: slot=2 port=10 speed=1 vid=0x5ac pid=0x8106 class=0 protocol=0 epin=1 maxpkt=10 interval=8 boot=0'
vgate_assert 01 serial-absent 'usb report: dev0 seq=0 len=8 bytes=0x0 0x0 0x4 0x0 0x0 0x0 0x0 0x0'
vgate_assert 01 serial-absent 'usb report: kb mod=0x0 keys=0x4'
vgate_assert 01 serial-contains 'usb-gate-ok'
vgate_assert 01 serial-absent '[EXC] parking:'
