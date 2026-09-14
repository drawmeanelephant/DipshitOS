/*
 * hv-probe.c -- can THIS host actually host a hypervisor?
 *
 * Hypervisor.framework is what Virtualization.framework is built on, so a
 * refusal here means no class-B gate can boot a guest on this machine,
 * whatever macOS version it reports. tools/lib/gate-run.sh compiles and signs
 * this (see hv-probe.entitlements) and reads the single line it prints.
 *
 * Do NOT read the result as a capability verdict unless the signature took.
 *
 *   * An UNSIGNED probe returns 0xfae94007 HV_DENIED -- a statement about the
 *     signature wearing the shape of a statement about the machine. The caller
 *     treats that code as a harness fault, never as "this host cannot".
 *   * HV_UNSUPPORTED (0xfae9400f) is the real refusal.
 *
 * Header note, because it cost a build: <Hypervisor/hv.h> is x86-only
 * (guarded by #ifdef __x86_64__). On arm64 the umbrella header is
 * <Hypervisor/Hypervisor.h>.
 *
 * Measured 2026-09-14: 0x00000000 on this project's reference host (macOS 27),
 * 0xfae9400f on GitHub's hosted runners, which are themselves guests.
 */
#include <stdio.h>
#include <Hypervisor/Hypervisor.h>

int main(void) {
    hv_return_t r = hv_vm_create(NULL);
    const char *name;

    switch ((unsigned)r) {
        case 0x00000000: name = "HV_SUCCESS";      break;
        case 0xfae94001: name = "HV_ERROR";        break;
        case 0xfae94002: name = "HV_BUSY";         break;
        case 0xfae94003: name = "HV_BAD_ARGUMENT"; break;
        case 0xfae94005: name = "HV_NO_RESOURCES"; break;
        case 0xfae94006: name = "HV_NO_DEVICE";    break;
        case 0xfae94007: name = "HV_DENIED";       break;
        case 0xfae94008: name = "HV_FAULT";        break;
        case 0xfae9400f: name = "HV_UNSUPPORTED";  break;
        default:         name = "HV_UNKNOWN";      break;
    }

    printf("hv_vm_create(NULL) -> 0x%08x (%s)\n", (unsigned)r, name);
    printf("HV_CODE=0x%08x HV_NAME=%s\n", (unsigned)r, name);

    if (r == 0) {
        hv_vm_destroy();
    }
    return 0;
}
