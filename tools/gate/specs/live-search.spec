# live-search.spec -- milestone-eighteen card T3 class-B gate (issue #406):
#
# reverse-i-search (Ctrl+R) on real VZ.
#
# Mechanism: boots the production image with scripted input: phase 1 submits
# distinctive commands to history. Phase 2 sends ONLY the Ctrl+R entry over
# serial (a modifier chord — VZ's synthesized keyboard cannot deliver it,
# activation wall, hardware contract). Phase 3 types the QUERY and the
# Enter-accept through the synthesized keyboard (--input-chords, claims

vgate_name live-search "milestone-eighteen card T3 class-B gate (issue #406):"
vgate_repeat 1 BOOTS

vgate_file script.txt <<'EOF'
echo build-up-1
echo build-up-2
echo special-search-target-777
echo build-up-4
echo build-up-5
echo fill-ready
EOF

vgate_run 01 -- --input --display --script '$RUN_DIR/script.txt' --input-chords "s,p,e,c,i,a,l,return,e,c,h,o,space,s,e,a,r,c,h,-,l,i,v,e,-,o,k,return" --input-chords-after "fill-ready" --input-chords-delay 2.0 --script2 artifacts/live-search-keys.txt --script2-after "fill-ready" --script-expect "search-live-ok" --timeout 240

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'fill-ready'
vgate_assert 01 serial-contains '(reverse-i-search)`'
vgate_assert 01 serial-contains '(reverse-i-search)`special`: echo special-search-target-777'
vgate_assert 01 serial-contains 'search-live-ok'
vgate_assert 01 serial-absent '[EXC] parking:'
