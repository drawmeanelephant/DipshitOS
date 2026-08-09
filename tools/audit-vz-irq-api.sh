#!/usr/bin/env bash
# Record the selected Xcode/macOS SDK's public host interrupt surface.
# This is a read-only class-D premise audit; it does not boot a VM.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

OUT="artifacts/vz-irq-api-audit.txt"
exec > >(tee "$OUT") 2>&1

SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
VZ_PATH="$SDK_PATH/System/Library/Frameworks/Virtualization.framework"
HV_HEADERS="$SDK_PATH/System/Library/Frameworks/Hypervisor.framework/Headers"

echo "DIPSHITOS VZ IRQ public-API audit (claim 9187)"
date -u '+date: %Y-%m-%dT%H:%M:%SZ'
uname -m
sw_vers
xcode-select -p
xcodebuild -version
echo "sdk-path: $SDK_PATH"
echo "sdk-version: $(xcrun --sdk macosx --show-sdk-version)"

echo "Virtualization.framework runtime class probes:"
xcrun swift -e '
import Foundation
import Virtualization

for name in ["VZGICConfiguration", "VZInterruptControllerConfiguration", "VZGenericInterruptControllerConfiguration"] {
    print("\(name): \(NSClassFromString(name) == nil ? "ABSENT" : "PRESENT")")
}
'

echo "Virtualization.framework matches:"
if ! rg -n -i \
    'VZGIC|GICConfiguration|interrupt controller|interruptController|send.*interrupt|inject.*interrupt|set.*IRQ|\bIRQ\b' \
    "$VZ_PATH"; then
    echo "NO_PUBLIC_VZ_INTERRUPT_API_MATCHES"
fi

echo "Hypervisor.framework GIC host APIs and architectural offsets:"
rg -n \
    'hv_gic_(create|set_spi|send_msi)|HV_GIC_REDISTRIBUTOR_REG_GICR_(IGROUPR0|ISENABLER0|ICFGR1)' \
    "$HV_HEADERS"
