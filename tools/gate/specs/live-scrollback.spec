# live-scrollback.spec -- milestone-eighteen card T1 class-B gate (issue #404):
#
# the terminal scrollback ring on real VZ. Scripted input fills the
# scrollback with 30 echo lines, then the scroll keys (PageUp/PageDown/
# Escape) are typed through the SYNTHESIZED KEYBOARD as NSEvents
# (--input-chords, claim 1809 + claim 5093), and the shell's own `input`
# report proves every chord reached the guest keymap with dropped=0.
#
# Mechanism: the production image is booted with the runner's scripted-input

vgate_name live-scrollback "milestone-eighteen card T1 class-B gate (issue #404):"
vgate_repeat 1 BOOTS

vgate_file script.txt <<'EOF'
echo line-01
echo line-02
echo line-03
echo line-04
echo line-05
echo line-06
echo line-07
echo line-08
echo line-09
echo line-10
echo line-11
echo line-12
echo line-13
echo line-14
echo line-15
echo line-16
echo line-17
echo line-18
echo line-19
echo line-20
echo line-21
echo line-22
echo line-23
echo line-24
echo line-25
echo line-26
echo line-27
echo line-28
echo line-29
echo line-30
echo scrollback-fill-ready
EOF

vgate_run 01 -- --input --display --script '$RUN_DIR/script.txt' --input-chords "pageup,pageup,pageup,pagedown,pagedown,pagedown,escape,e,c,h,o,space,s,c,r,o,l,l,space,k,e,y,s,space,o,k,return,i,n,p,u,t,return" --input-chords-after "scrollback-fill-ready" --input-chords-delay 2.0 --script-expect "input: armed=1 fifo=0/64 dropped=0 events=33" --timeout 240

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'scrollback-fill-ready'
vgate_assert 01 serial-contains 'scroll keys ok'
vgate_assert 01 serial-absent 'input: armed=1 fifo=0/64 dropped=0 events=33'
vgate_assert 01 serial-absent '[EXC] parking:'
