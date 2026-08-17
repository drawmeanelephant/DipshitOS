#!/usr/bin/env bash
# Probe: sweep pointer routes against the same guest session, comparing
# host-side delivery (PTR-TRACE) with guest-side reports (ptr-reports).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

ROUTES="${1:-direct warp diag pid drag cg}"

echo "=== pointer-route probe ===" > artifacts/pointer-route-probe.txt
echo "date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')" >> artifacts/pointer-route-probe.txt
zig version >> artifacts/pointer-route-probe.txt

for ROUTE in $ROUTES; do
    echo "--- route: $ROUTE ---"
    cat > artifacts/pointer-probe-script.txt <<EOF
dui
exec WINLOOP.BIN
echo pointer-probe-ready-$ROUTE
EOF
    rm -f artifacts/efi-vars.bin artifacts/vm-serial.log
    START=$(date +%s)
    host/vm-runner/.build/release/VMRunner artifacts/disk.img artifacts/vm-serial.log \
        --input --display \
        --script artifacts/pointer-probe-script.txt \
        --pointer "960,100;960,100,c;200,150;200,150,c;640,600;640,600,c" \
        --pointer-after "winloop: present ok" \
        --pointer-route "$ROUTE" \
        --expect "pointer-probe-ready-$ROUTE" \
        --timeout 200 \
        > /tmp/pointer-route-$ROUTE-run.txt 2>&1
    RC=$?
    DUR=$(( $(date +%s) - START ))
    echo "runner-rc=$RC dur=${DUR}s"
    # guest-side
    if [ -f artifacts/vm-serial.log ]; then
        REPORTS=$(grep -a -o "ptr-reports=[0-9]*" artifacts/vm-serial.log | tail -1 | cut -d= -f2 || true)
        FOCUS=$(grep -a -o "dui: pointer focus=[0-9]*" artifacts/vm-serial.log | sort -u | tr '\n' ' ' || true)
        READY=$(grep -a -c -F "pointer-probe-ready-$ROUTE" artifacts/vm-serial.log || true)
    else
        REPORTS=0; FOCUS=""; READY=0
    fi
    # host-side delivery evidence
    TRACES=$(grep -a -c "PTR-TRACE" /tmp/pointer-route-$ROUTE-run.txt || true)
    TRACE_LAST=$(grep -a "PTR-TRACE" /tmp/pointer-route-$ROUTE-run.txt | tail -3 | tr '\n' ' | ' || true)
    EVENTS=$(grep -a -c "PTR-EVT" /tmp/pointer-route-$ROUTE-run.txt || true)
    echo "route=$ROUTE rc=$RC ready=$READY ptr-reports=${REPORTS:-0} focus=[$FOCUS] evtdel=$EVENTS trace=$TRACES last=[${TRACE_LAST}]"
    {
        echo "route=$ROUTE rc=$RC ready=$READY ptr-reports=${REPORTS:-0} focus=[$FOCUS] events=$EVENTS traces=$TRACES last=[${TRACE_LAST}]"
    } >> /tmp/pointer-route-probe.txt
    # kill any stragglers
    pkill -f "VMRunner artifacts/disk.img" 2>/dev/null
done
cat /tmp/pointer-route-probe.txt