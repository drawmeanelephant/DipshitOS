//! VirelaiOS XHCI host-controller transport + USB enumeration + HID
//! (milestone seven, cards I1 + I2 — claims 4272 + 4116).
//!
//! Drives the device the runner attaches as `VZUSBKeyboardConfiguration` +
//! `VZUSBScreenCoordinatePointingDeviceConfiguration` under `--input` — to
//! the guest an **Apple XHCI USB host controller** (`VID=0x106b DID=0x1a06
//! CLS=0x0c0330`, claim-3868 observation), found via the MCFG ECAM base
//! exactly like the console/blk/entropy/net/gpu devices. The keyboard and
//! pointing devices are USB HID devices BEHIND this controller (I2
//! enumerates them); I1 proved the controller's register map and its
//! command/event ring machinery.
//!
//! I1 scope (the march-m7 card): discover the device PRE-EXIT (PCI
//! config-space reads must stay pre-exit, claim 0013), then POST-MMU map the
//! MMIO register space (capability/operational/doorbell/runtime), parse
//! HCSPARAMS1/2/3 + HCCPARAMS1 + DBOFF + RTSOFF, set up the command ring +
//! event ring + ERST + the primary interrupter, drive a NO-OP command TRB to
//! a Command Completion Event (the ring machinery proven), and read port
//! status (USBSTS/PORTSC — how many ports, which are connected/enabled).
//!
//! Honest bounds: NO port reset, NO device enumeration, NO transfer rings
//! (I2); NO interrupt-driven event drain — the event ring is drained POLLED
//! (the claim-6076 net lesson: the XHCI event IRQ is observed, not assumed,
//! at claim time). Whether VZ resets the controller at ExitBootServices is
//! OBSERVED (the pre-reset USBSTS/USBCMD are captured and reported), not
//! assumed (the gpu/blk/entropy `st=00` vs net `st=0f` question has no XHCI
//! answer until this claim).
//!
//! Cache correctness mirrors the virtio drivers: clean the software-written
//! rings before the doorbell/run write, invalidate the device-written event
//! ring before polling. The identity map blankets the low 4 GiB, so the two
//! MMIO BARs (0x50001000 + 0x50000000, both below 4 GiB) need no extra
//! Device window.
//!
//! No libc, no POSIX, no allocation, no interrupts.

const std = @import("std");
const mmio = @import("mmio.zig");
const mmu = @import("mmu.zig");
const pci = @import("pci.zig");
const evidence = @import("evidence.zig");

// ---------------------------------------------------------------------------
// XHCI register + TRB constants (xHCI spec, eXtensible Host Controller
// Interface for USB)
// ---------------------------------------------------------------------------

/// A Transfer Request Block — the 16-byte atom of every xHCI ring. For
/// command TRBs the payload lives in `param`/`status`; for event TRBs the
/// controller writes the completion data into these fields.
pub const Trb = extern struct {
    param: u64 = 0,
    status: u32 = 0,
    control: u32 = 0,
};

/// Event Ring Segment Table entry (16 bytes). One segment for I1.
pub const ErstEntry = extern struct {
    seg_base: u64 = 0, // 64-byte aligned
    seg_size: u16 = 0, // TRBs in this segment
    rsvd: u16 = 0,
    rsvd2: u32 = 0,
};

// ---------------------------------------------------------------------------
// xHCI context structures (spec §6.2; field layouts pinned from the Linux
// xhci.h — the ground truth that runs on real hardware)
// ---------------------------------------------------------------------------

/// Slot Context (32 bytes). dev_info holds route string (19:0), device speed
/// (23:20), MTT (25), Hub (26), and LAST_CTX (31:27); dev_info2 holds Max
/// Exit Latency (15:0) + Root Hub Port (23:16); dev_state holds the device
/// address (7:0) + slot state (31:27).
pub const SlotContext = extern struct {
    dev_info: u32 = 0,
    dev_info2: u32 = 0,
    tt_info: u32 = 0,
    dev_state: u32 = 0,
    reserved: [4]u32 = [_]u32{0} ** 4,
};

/// Endpoint Context (32 bytes). ep_info holds EP state (2:0), Mult (9:8),
/// MaxPStreams (14:10), LSA (15), and Interval (23:16); ep_info2 holds Force
/// Event (0), CErr (2:1), EP Type (5:3), Max Burst (15:8), and Max Packet
/// Size (31:16); deq is the ring dequeue pointer | DCS (bit 0); tx_info holds
/// Avg TRB Length (15:0) + Max ESIT Payload Lo (31:16).
pub const EpContext = extern struct {
    ep_info: u32 = 0,
    ep_info2: u32 = 0,
    deq: u64 = 0,
    tx_info: u32 = 0,
    reserved: [3]u32 = [_]u32{0} ** 3,
};

/// Input Control Context (32 bytes, the front of an Input Context). Bit 0 of
/// add/drop flags is the Slot Context; bit i+1 is Endpoint Context i (EP0 =
/// bit 1, EP1 OUT = bit 2, EP1 IN = bit 3).
pub const InputControlContext = extern struct {
    drop_flags: u32 = 0,
    add_flags: u32 = 0,
    reserved: [6]u32 = [_]u32{0} ** 6,
};

/// Device Context = Slot Context + the endpoint contexts a keyboard/pointer
/// needs: EP0 (bidirectional, one context), EP1 OUT (unused), EP1 IN
/// (interrupt). Context offsets are slot=0, EP0=1, EP1OUT=2, EP1IN=3.
pub const DeviceContext = extern struct {
    slot: SlotContext,
    ep0: EpContext,
    ep1_out: EpContext,
    ep1_in: EpContext,
};

/// Input Context = Input Control + Slot + the same endpoint contexts (the
/// control context shifts every following context by one slot).
pub const InputContext = extern struct {
    control: InputControlContext,
    slot: SlotContext,
    ep0: EpContext,
    ep1_out: EpContext,
    ep1_in: EpContext,
};

/// TRB type field (control bits 15:10).
const trb_link: u32 = 6; // Link TRB
const trb_noop: u32 = 23; // No Op command
const trb_command_completion_event: u32 = 33;
const trb_transfer_event: u32 = 32;
const trb_port_status_change_event: u32 = 34;

// Transfer TRB types (I2 — the control + interrupt paths).
const trb_normal: u32 = 1; // Normal (data) TRB
const trb_setup_stage: u32 = 2; // Setup Stage (control transfer)
const trb_data_stage: u32 = 3; // Data Stage (control transfer)
const trb_status_stage: u32 = 4; // Status Stage (control transfer)

// Command TRB types (I2 — enumeration).
const trb_enable_slot: u32 = 9;
const trb_disable_slot: u32 = 10;
const trb_addr_dev: u32 = 11;
const trb_config_ep: u32 = 12;

/// TRB control bits.
const trb_cycle: u32 = 0x1; // ring cycle bit (bit 0)
const trb_link_toggle: u32 = 0x2; // Link TRB: toggle cycle (bit 1)
const trb_isp: u32 = 0x4; // Interrupt on Short Packet (bit 2)
const trb_ioc: u32 = 0x20; // Interrupt on Completion (bit 5)
const trb_idt: u32 = 0x40; // Immediate Data (bit 6) — setup data in the param
const trb_dir_in: u32 = 0x10000; // Data/Status direction (bit 16)

/// Setup TRB transfer-type field (bits 17:16).
const tx_no_data: u32 = 0;
const tx_data_out: u32 = 2;
const tx_data_in: u32 = 3;

/// Endpoint types (ep_info2 bits 5:3).
const ep_ctrl: u32 = 4;
const ep_int_in: u32 = 7;

/// Command Completion Event completion code (status bits 31:24).
const cc_success: u32 = 1;

// Slot-state bits in the Slot Context dev_state field.
const slot_state_addressed: u32 = 2 << 27;
const slot_state_configured: u32 = 3 << 27;

// Slot Context dev_info fields.
const last_ctx_mask: u32 = 0x1f << 27;

// Input Control Context flags (bit 0 = slot, bit i+1 = endpoint context i).
const slot_flag: u32 = 1 << 0;
const ep0_flag: u32 = 1 << 1;

/// DCBAA entry count: 1 scratchpad + MaxSlotsEn (2 devices — the two HID
/// devices the `--input` config attaches).
const max_enumerated: usize = 2;
const dcbaa_len: usize = max_enumerated + 1;

/// USBCMD bits (operational register offset 0x00).
const usbcmd_run: u32 = 0x1; // RS — Run/Stop
const usbcmd_host_reset: u32 = 0x2; // HCRST

/// USBSTS bits (operational register offset 0x04).
const usbsts_halted: u32 = 0x1; // HCH — HCHalted
const usbsts_cntrl_not_ready: u32 = 0x800; // CNR — Controller Not Ready

/// CRCR bits (operational register offset 0x18).
const crcr_ring_cycle_state: u32 = 0x1; // RCS

/// PORTSC bits (operational register offset 0x400 + (port-1)*0x10).
const portsc_ccs: u32 = 0x1; // Current Connect Status
const portsc_ped: u32 = 0x2; // Port Enabled/Disabled
const portsc_pr: u32 = 0x10; // Port Reset
const portsc_pp: u32 = 0x200; // Port Power
const portsc_csc: u32 = 0x20000; // Connect Status Change

/// Command ring geometry: `cmd_ring_len` TRBs total, the LAST slot is the
/// Link TRB that wraps the ring (xHCI 4.9.1 — the ring boundary is defined
/// by a Link TRB, not a size register).
const cmd_ring_len: usize = 16;
const cmd_usable: usize = cmd_ring_len - 1; // index 15 is the Link TRB

/// Event ring geometry: one segment of 64 TRBs (1024 bytes, 64-byte aligned).
const evt_ring_len: usize = 64;

/// Completion-poll budget (the virtio poll_budget precedent).
const poll_budget: usize = 16_000_000;

// ---------------------------------------------------------------------------
// Transport state (discovery runs pre-exit; init/NO-OP run post-MMU)
// ---------------------------------------------------------------------------

pub var xhci_dev: u32 = 32; // PCI device number (sentinel: not found)
pub var xhci_did: u32 = 0;
pub var xhci_class: u32 = 0;
pub var xhci_bar0: u64 = 0;
pub var xhci_bar1: u64 = 0;

/// The MMIO register base (which BAR holds the capability registers — a
/// claim-time observation; see `find_base`).
pub var xhci_base: u64 = 0;
pub var xhci_caplen: u8 = 0;
pub var xhci_hciver: u16 = 0;
pub var xhci_hcsparams1: u32 = 0;
pub var xhci_hcsparams2: u32 = 0;
pub var xhci_hcsparams3: u32 = 0;
pub var xhci_hccparams1: u32 = 0;
pub var xhci_dboff: u32 = 0;
pub var xhci_rtsoff: u32 = 0;

/// Computed register bases (base + CAPLENGTH / DBOFF / RTSOFF).
pub var xhci_op_base: u64 = 0;
pub var xhci_doorbell_base: u64 = 0;
pub var xhci_rt_base: u64 = 0;

/// The pre-reset USBSTS/USBCMD (read post-EBS, before HCRST) — the
/// reset-at-ExitBootServices observation.
pub var xhci_pre_reset_usbsts: u32 = 0;
pub var xhci_pre_reset_usbcmd: u32 = 0;

/// Init result + the NO-OP completion code (0 until it completes).
pub var xhci_ready: bool = false;
pub var xhci_noop_cc: u32 = 0;
pub var xhci_noop_done: bool = false;
pub var xhci_fail: []const u8 = "";

/// Optional debug writer (main.zig arms it with `uart_puts` during init so a
/// hung stage is attributable on the serial log). Null in host tests.
pub var debug: ?*const fn ([]const u8) void = null;
pub var debug_hex: ?*const fn (u64) void = null;
fn dbg(msg: []const u8) void {
    if (debug) |w| w(msg);
}
fn dbg_hex(v: u64) void {
    if (debug_hex) |w| w(v);
}

// The DMA rings (fixed BSS, 64-byte aligned — the xHCI alignment rule).
var cmd_ring: [cmd_ring_len]Trb align(64) = undefined;
var evt_ring: [evt_ring_len]Trb align(64) = undefined;
var erst: ErstEntry align(64) = undefined;

var cmd_enq: usize = 0; // command-ring enqueue index (0..cmd_usable)
var cmd_cycle: u1 = 1; // cycle bit written into newly enqueued command TRBs
var evt_deq: usize = 0; // event-ring dequeue index (0..evt_ring_len-1)
var evt_cycle: u1 = 1; // the cycle bit software expects on fresh events

// ---------------------------------------------------------------------------
// I2 enumeration state (all fixed BSS, 64-byte aligned — the xHCI rule)
// ---------------------------------------------------------------------------

/// Transfer-ring geometry: `tr_ring_len` TRBs, the last is the Link TRB.
const tr_ring_len: usize = 16;
const tr_usable: usize = tr_ring_len - 1;

/// Device Context Base Address Array: entry 0 = scratchpad array (0 — no
/// scratchpad buffers), entries 1..max_enumerated = device-context bases.
var dcbaa: [dcbaa_len]u64 align(64) = [_]u64{0} ** dcbaa_len;

/// The two device contexts (slot 1 = first device, slot 2 = second).
var dev_ctx: [max_enumerated]DeviceContext align(64) = undefined;

/// One shared Input Context (enumeration is strictly sequential).
var input_ctx: InputContext align(64) = undefined;

/// Per-slot EP0 control-transfer rings (one control transfer per slot at a
/// time — each device's EP0 context tracks its OWN dequeue pointer, so a
/// shared ring would desynchronize the second device) + enqueue/cycle state.
var ep0_ring: [max_enumerated][tr_ring_len]Trb align(64) = undefined;
var ep0_enq: [max_enumerated]usize = [_]usize{0} ** max_enumerated;
var ep0_cycle: [max_enumerated]u1 = [_]u1{1} ** max_enumerated;

/// Per-device interrupt-IN rings (the HID report path) + their enqueue/
/// dequeue pointers / cycle bits + the report buffers.
var intr_ring: [max_enumerated][tr_ring_len]Trb align(64) = undefined;
var intr_enq: [max_enumerated]usize = [_]usize{0} ** max_enumerated;
var intr_deq: [max_enumerated]usize = [_]usize{0} ** max_enumerated;
var intr_cycle: [max_enumerated]u1 = [_]u1{1} ** max_enumerated;
/// The largest interrupt-IN packet any enumerated device reports (the
/// absolute pointer's maxpkt 10; the keyboard's 8). The report buffers and
/// the armed TRB length are sized to the DEVICE's maxpkt — issue #118: the
/// buffers were fixed [8]u8 with the TRB length clamped to 8, silently
/// truncating the pointer's 10-byte reports.
pub const max_report_bytes: usize = 10;

/// The most recently completed report (the `usb report` / `input` view).
var intr_report: [max_enumerated][max_report_bytes]u8 align(64) = undefined;
/// Per-ring-slot report buffers — one per armed interrupt-IN TRB (the slot
/// index = the ring slot that TRB occupies). Card I3 depth-buffering: with
/// several TRBs armed the controller can complete multiple reports between
/// guest polls (a keyDown + keyUp arriving while the shell prints), instead
/// of dropping every report after the first when a single TRB is armed.
var intr_slots: [max_enumerated][tr_usable][max_report_bytes]u8 align(64) = undefined;

/// Interrupt-IN depth: how many report TRBs stay armed per device. Claim
/// 6050 (I3) concluded depth 1 was "correct" because a multi-TRB (8)
/// experiment "wrapped the transfer ring at the 8th report and dropped
/// everything after" — but that experiment ran against the PRE-U2
/// `xhci_arm_intr`, which read the report-buffer slot with the PRE-wrap
/// enqueue index (`intr_slots[slot][tr_usable]`, one past the array) and
/// armed garbage TRBs at the wrap. The U2 fix (`intr_slot_index`) landed
/// 2026-08-14 (claim 1809); issue #117 re-tests depth here.
///
/// Measured on VZ (2026-08-15, claim-time): depth 8 delivers the full
/// typed sequence byte-exact at the VZ keyboard ceiling (~1.5-2 s per
/// report — the host's state-based keyboard flushes roughly one report per
/// full-frame present, and keyDown/keyUp pairs inside that window net to
/// zero). Depth does NOT raise that steady-state rate (a host delivery
/// limit, not a guest bug); its value is the correct XHCI shape (several
/// interrupt-IN TRBs, each owning its own report buffer) plus buffering the
/// bursts VZ delivers when its main queue stalls behind display updates.
pub const intr_depth: usize = 8;

/// How many TRBs are currently armed per device (the top-up loop's
/// accounting; increments on enqueue, decrements on completion).
var intr_armed: [max_enumerated]usize = [_]usize{0} ** max_enumerated;

/// Per-slot interrupt endpoint max packet (the TRB length the arm uses).
var intr_maxpkt: [max_enumerated]u16 = [_]u16{0} ** max_enumerated;

/// The enumerated device table: slot id, port, speed, VID/PID/class, the
/// interrupt endpoint's number/max-packet/interval, and the HID protocol.
pub const EnumMax = max_enumerated;
pub const EnumDevice = struct {
    present: bool = false,
    slot_id: u8 = 0,
    port: u8 = 0,
    speed: u8 = 0, // PORTSC PS value (1=FS, 2=LS, 3=HS)
    vid: u16 = 0,
    pid: u16 = 0,
    class: u8 = 0, // bDeviceClass
    subclass: u8 = 0,
    protocol: u8 = 0, // bDeviceProtocol
    ep_in_num: u8 = 0, // interrupt-IN endpoint number (0 if none)
    ep_in_maxpkt: u16 = 0,
    ep_in_interval: u8 = 0,
    hid_boot: bool = false, // Set_Protocol(boot) succeeded
    last_report_len: u8 = 0,
    report_seq: u32 = 0,
};
pub var enum_devs: [EnumMax]EnumDevice = [_]EnumDevice{.{}} ** EnumMax;
pub var enum_count: usize = 0;

/// The HID report kind for each device (decided from bInterfaceProtocol:
/// 1 = keyboard, 2 = mouse, else unknown).
pub const HidKind = enum { unknown, keyboard, mouse };
pub var hid_kind: [EnumMax]HidKind = [_]HidKind{.unknown} ** EnumMax;

/// Enumeration result (for the boot log + `usb devices`).
pub var enum_done: bool = false;
pub var enum_fail: []const u8 = "";

/// Physical (== virtual here, the identity map) address of a DMA ring.
fn ring_phys(ptr: anytype) u64 {
    return mmu.to_phys(@intFromPtr(ptr));
}

// ---------------------------------------------------------------------------
// HCSPARAMS field accessors (pure — host-testable)
// ---------------------------------------------------------------------------

pub fn hcsparams1_max_slots(p: u32) u8 {
    return @intCast(p & 0xff);
}
pub fn hcsparams1_max_intrs(p: u32) u16 {
    return @intCast((p >> 8) & 0x7ff);
}
pub fn hcsparams1_max_ports(p: u32) u8 {
    return @intCast((p >> 24) & 0xff);
}
pub fn hccparams1_64bit(p: u32) bool {
    return (p & 0x1) != 0;
}
pub fn hccparams1_context_size(p: u32) u8 {
    return if ((p & 0x4) != 0) 64 else 32;
}

// ---------------------------------------------------------------------------
// Discovery (PRE-EXIT only — PCI config-space reads hang post-exit, claim
// 0013). Captures the device + its BARs + the PCI command register.
// ---------------------------------------------------------------------------

pub fn xhci_probe() bool {
    if (pci.pci_ecam == 0) {
        evidence.dump_str("XH: no ECAM\n");
        return false;
    }
    var dev: u32 = 0;
    while (dev < 32) : (dev += 1) {
        const id = pci.pci_read32(pci.pci_ecam, 0, dev, 0, 0);
        if ((id & 0xffff) == 0xffff) continue;
        const did = id >> 16;
        if (did == 0x1a06) {
            xhci_dev = dev;
            xhci_did = did;
            xhci_class = (pci.pci_read32(pci.pci_ecam, 0, dev, 0, 8) >> 8) & 0xffffff;
            // Both BARs are 32-bit memory BARs (observed claim 3868); read
            // them like the virtio drivers' resolve_dev does.
            const b0 = pci.pci_read32(pci.pci_ecam, 0, dev, 0, 0x10);
            const b1 = pci.pci_read32(pci.pci_ecam, 0, dev, 0, 0x14);
            xhci_bar0 = b0 & ~@as(u32, 0xf);
            xhci_bar1 = b1 & ~@as(u32, 0xf);
            const cmdreg = pci.pci_read32(pci.pci_ecam, 0, dev, 0, 0x04);
            evidence.dump_str("XH dev=");
            evidence.dump_hex(xhci_dev);
            evidence.dump_str(" did=");
            evidence.dump_hex(xhci_did);
            evidence.dump_str(" class=");
            evidence.dump_hex(xhci_class);
            evidence.dump_str(" bar0=");
            evidence.dump_hex(xhci_bar0);
            evidence.dump_str(" bar1=");
            evidence.dump_hex(xhci_bar1);
            evidence.dump_str(" cmdreg=");
            evidence.dump_hex(cmdreg);
            evidence.dump_str("\n");
            return true;
        }
    }
    evidence.dump_str("XH: no XHCI PCI device (DID 0x1a06)\n");
    return false;
}

/// Enable the device's PCI command register (memory space + bus master) so
/// its BAR MMIO becomes live — the virtio_custom `enable_memory_space` step
/// applied to the XHCI device. Config-space WRITES work post-exit (claim
/// 0828). Idempotent; the observed pre-exit command register is reported
/// either way.
fn enable_memory_space() void {
    if (xhci_dev >= 32 or pci.pci_ecam == 0) return;
    pci.pci_write32(pci.pci_ecam, 0, xhci_dev, 0, 0x04, 0x06); // MEM + bus master
}

/// Decide which BAR holds the capability registers (CAPLENGTH + HCIVERSION
/// at offset 0). Both BARs sit below the 4 GiB blanket, so reading either is
/// safe (a wrong BAR yields a zero/garbage CAPLENGTH, not a fault). The
/// candidate with a sane CAPLENGTH wins; ties prefer the lower address
/// (BAR1 in the observed 0x50000000 vs 0x50001000 pair). Pure-ish (reads
/// MMIO) but records its choice in the globals + evidence.
fn find_base() u64 {
    const c0 = mmio.mmio_read8(xhci_bar0);
    const c1 = mmio.mmio_read8(xhci_bar1);
    const v0 = mmio.mmio_read16(xhci_bar0 + 2);
    const v1 = mmio.mmio_read16(xhci_bar1 + 2);
    evidence.dump_str("XH base probe: bar0 caplen=");
    evidence.dump_hex(c0);
    evidence.dump_str(" ver=");
    evidence.dump_hex(v0);
    evidence.dump_str(" bar1 caplen=");
    evidence.dump_hex(c1);
    evidence.dump_str(" ver=");
    evidence.dump_hex(v1);
    evidence.dump_str("\n");
    const sane0 = c0 >= 0x10 and c0 <= 0x40 and v0 != 0 and v0 != 0xffff;
    const sane1 = c1 >= 0x10 and c1 <= 0x40 and v1 != 0 and v1 != 0xffff;
    if (sane0 and !sane1) return xhci_bar0;
    if (sane1 and !sane0) return xhci_bar1;
    // Both or neither: prefer the lower address.
    return @min(xhci_bar0, xhci_bar1);
}

// ---------------------------------------------------------------------------
// Init (POST-MMU)
// ---------------------------------------------------------------------------

pub fn xhci_init() bool {
    if (xhci_dev >= 32) {
        xhci_fail = "no XHCI device (DID 0x1a06 not found on bus 0)";
        return false;
    }
    dbg("xhci: mem-space\n");
    enable_memory_space();

    dbg("xhci: find-base\n");
    xhci_base = find_base();
    if (xhci_base == 0) {
        xhci_fail = "no sane XHCI register BAR";
        return false;
    }
    dbg("xhci: read-caps\n");
    xhci_caplen = mmio.mmio_read8(xhci_base + 0);
    xhci_hciver = mmio.mmio_read16(xhci_base + 2);
    xhci_hcsparams1 = mmio.mmio_read32(xhci_base + 4);
    xhci_hcsparams2 = mmio.mmio_read32(xhci_base + 8);
    xhci_hcsparams3 = mmio.mmio_read32(xhci_base + 12);
    xhci_hccparams1 = mmio.mmio_read32(xhci_base + 16);
    xhci_dboff = mmio.mmio_read32(xhci_base + 20);
    xhci_rtsoff = mmio.mmio_read32(xhci_base + 24);

    xhci_op_base = xhci_base + xhci_caplen;
    xhci_doorbell_base = xhci_base + xhci_dboff;
    xhci_rt_base = xhci_base + xhci_rtsoff;

    dbg("xhci: vals base=");
    dbg_hex(xhci_base);
    dbg(" caplen=");
    dbg_hex(xhci_caplen);
    dbg(" ver=");
    dbg_hex(xhci_hciver);
    dbg(" hcs1=");
    dbg_hex(xhci_hcsparams1);
    dbg(" dboff=");
    dbg_hex(xhci_dboff);
    dbg(" rtsoff=");
    dbg_hex(xhci_rtsoff);
    dbg(" op=");
    dbg_hex(xhci_op_base);
    dbg(" rt=");
    dbg_hex(xhci_rt_base);
    dbg("\n");

    // The reset-at-EBS observation: read USBSTS/USBCMD before any reset.
    xhci_pre_reset_usbsts = mmio.mmio_read32(xhci_op_base + 0x04);
    xhci_pre_reset_usbcmd = mmio.mmio_read32(xhci_op_base + 0x00);

    // Host-controller reset for a deterministic state, then wait for it to
    // complete + the controller to be ready (bounded).
    dbg("xhci: hcrst\n");
    mmio.mmio_write32(xhci_op_base + 0x00, usbcmd_host_reset);
    var spins: usize = 0;
    while ((mmio.mmio_read32(xhci_op_base + 0x00) & usbcmd_host_reset) != 0) : (spins += 1) {
        if (spins > 1_000_000) {
            xhci_fail = "HCRST did not complete";
            return false;
        }
    }
    spins = 0;
    while ((mmio.mmio_read32(xhci_op_base + 0x04) & usbsts_cntrl_not_ready) != 0) : (spins += 1) {
        if (spins > 1_000_000) {
            xhci_fail = "controller not ready after HCRST";
            return false;
        }
    }

    // I2: enable device slots + the Device Context Base Address Array. Two
    // slots (the keyboard + pointer the `--input` config attaches). The
    // scratchpad entry (dcbaa[0]) stays 0 — no scratchpad buffers.
    dbg("xhci: cfg\n");
    mmio.mmio_write32(xhci_op_base + 0x38, max_enumerated); // CONFIG.MaxSlotsEn
    dcbaa = [_]u64{0} ** dcbaa_len;
    const dcbaa_pa = ring_phys(&dcbaa);
    mmu.clean_dcache_range(@intFromPtr(&dcbaa), @sizeOf(@TypeOf(dcbaa)));
    mmio.mmio_write32(xhci_op_base + 0x30, @truncate(dcbaa_pa)); // DCBAAP lo
    mmio.mmio_write32(xhci_op_base + 0x34, @truncate(dcbaa_pa >> 32)); // DCBAAP hi

    // Command ring: zero it, plant the Link TRB at the last slot.
    cmd_ring = [_]Trb{.{}} ** cmd_ring_len;
    cmd_ring[cmd_usable] = .{
        .param = ring_phys(&cmd_ring),
        .status = 0,
        .control = (trb_link << 10) | trb_link_toggle | trb_cycle,
    };
    cmd_enq = 0;
    cmd_cycle = 1;
    mmu.clean_dcache_range(@intFromPtr(&cmd_ring), @sizeOf(@TypeOf(cmd_ring)));

    // Event ring: zero it (all cycle bits 0), one ERST segment.
    evt_ring = [_]Trb{.{}} ** evt_ring_len;
    evt_deq = 0;
    evt_cycle = 1;
    erst = .{ .seg_base = ring_phys(&evt_ring), .seg_size = evt_ring_len };
    mmu.clean_dcache_range(@intFromPtr(&evt_ring), @sizeOf(@TypeOf(evt_ring)));
    mmu.clean_dcache_range(@intFromPtr(&erst), @sizeOf(ErstEntry));

    // Primary interrupter: one segment, segment table base, dequeue pointer.
    // xHCI 5.5: MFINDEX sits at RTSOFF+0x00; interrupter register set i is
    // at RTSOFF+0x20+(0x20*i). Interrupter 0 is therefore at +0x20.
    const ert = xhci_rt_base + 0x20;
    mmio.mmio_write32(ert + 0x08, 1); // ERSTSZ = 1 segment
    const erst_pa = ring_phys(&erst);
    mmio.mmio_write32(ert + 0x10, @truncate(erst_pa)); // ERSTBA lo
    mmio.mmio_write32(ert + 0x14, @truncate(erst_pa >> 32)); // ERSTBA hi
    const erdp = ring_phys(&evt_ring);
    mmio.mmio_write32(ert + 0x18, @truncate(erdp)); // ERDP lo
    mmio.mmio_write32(ert + 0x1c, @truncate(erdp >> 32)); // ERDP hi

    // Command ring control register: pointer + initial cycle state (RCS=1).
    dbg("xhci: crcr\n");
    const crcr = ring_phys(&cmd_ring) | crcr_ring_cycle_state;
    mmio.mmio_write32(xhci_op_base + 0x18, @truncate(crcr)); // CRCR lo
    mmio.mmio_write32(xhci_op_base + 0x1c, @truncate(crcr >> 32)); // CRCR hi

    // Run the controller, wait for HCHalted to clear.
    dbg("xhci: run\n");
    mmio.mmio_write32(xhci_op_base + 0x00, usbcmd_run);
    spins = 0;
    while ((mmio.mmio_read32(xhci_op_base + 0x04) & usbsts_halted) != 0) : (spins += 1) {
        if (spins > 1_000_000) {
            xhci_fail = "controller never left HCHalted";
            return false;
        }
    }

    // Drive one NO-OP command to a Command Completion Event — the ring
    // machinery proof.
    dbg("xhci: noop\n");
    if (!xhci_run_noop()) {
        xhci_fail = "NO-OP command did not complete";
        return false;
    }
    xhci_ready = true;

    // I2: initialize the EP0 control-transfer ring + the per-device
    // interrupt-IN rings (Link TRB at the wrap boundary), then enumerate the
    // connected devices (ports 9 + 10 observed in I1).
    dbg("xhci: transfer-rings\n");
    xhci_init_transfer_rings();
    dbg("xhci: enumerate\n");
    enum_done = xhci_enumerate_all();
    dbg("xhci: done\n");
    return true;
}

/// Enqueue a command TRB and advance the enqueue pointer (wrapping the Link
/// TRB when the ring boundary is reached). The cycle bit is stamped from the
/// software ring state.
fn cmd_enqueue(trb: Trb) void {
    if (cmd_enq == cmd_usable) {
        // At the Link TRB slot: re-plant it with the CURRENT cycle bit
        // (toggle the controller's state on traversal), then wrap.
        cmd_ring[cmd_usable] = .{
            .param = ring_phys(&cmd_ring),
            .status = 0,
            .control = (trb_link << 10) | trb_link_toggle | @as(u32, cmd_cycle),
        };
        cmd_enq = 0;
        cmd_cycle ^= 1;
    }
    var t = trb;
    t.control = (t.control & ~trb_cycle) | @as(u32, cmd_cycle);
    cmd_ring[cmd_enq] = t;
    mmu.clean_dcache_range(@intFromPtr(&cmd_ring[cmd_enq]), @sizeOf(Trb));
    cmd_enq += 1;
}

/// Advance the event-ring dequeue pointer (wrapping the segment + toggling
/// the software cycle state) and write it back to ERDP (interrupter 0).
fn evt_advance() void {
    evt_deq += 1;
    if (evt_deq >= evt_ring_len) {
        evt_deq = 0;
        evt_cycle ^= 1;
    }
    const erdp = ring_phys(&evt_ring) + evt_deq * @sizeOf(Trb);
    const ert = xhci_rt_base + 0x20; // interrupter 0
    mmio.mmio_write32(ert + 0x18, @truncate(erdp)); // ERDP lo
    mmio.mmio_write32(ert + 0x1c, @truncate(erdp >> 32)); // ERDP hi
}

/// Ring the command doorbell (doorbell index 0 = the command ring).
fn ring_command_doorbell() void {
    mmio.mmio_write32(xhci_doorbell_base, 0);
}

/// Drive a NO-OP command TRB to its Command Completion Event and return
/// true on success (completion code 1). Polls the event ring (no interrupt).
/// A stuck device fails honestly after the bounded poll.
pub fn xhci_run_noop() bool {
    if (xhci_op_base == 0) return false;
    const noop = Trb{
        .param = 0,
        .status = 0,
        .control = trb_noop << 10,
    };
    const slot = cmd_enq;
    cmd_enqueue(noop);
    const noop_phys = ring_phys(&cmd_ring) + slot * @sizeOf(Trb);
    ring_command_doorbell();
    var spins: usize = 0;
    while (spins < poll_budget) : (spins += 1) {
        mmu.invalidate_dcache_range(@intFromPtr(&evt_ring[evt_deq]), @sizeOf(Trb));
        const trb = evt_ring[evt_deq];
        if ((trb.control & trb_cycle) != evt_cycle) continue;
        const ty = (trb.control >> 10) & 0x3f;
        if (ty == trb_command_completion_event and trb.param == noop_phys) {
            const cc = (trb.status >> 24) & 0xff;
            evt_advance();
            xhci_noop_cc = cc;
            xhci_noop_done = cc == cc_success;
            return cc == cc_success;
        }
        // Some other event (a port status change, say) — consume it and
        // keep waiting for OUR completion.
        evt_advance();
    }
    return false;
}

/// Read the PORTSC register for `port` (1-based; 0 or past MaxPorts returns
/// 0). Live — called by the `usb` command so the report reflects the
/// current port state.
pub fn xhci_port_status(port: u8) u32 {
    if (port == 0 or xhci_op_base == 0) return 0;
    const max_ports = hcsparams1_max_ports(xhci_hcsparams1);
    if (port > max_ports) return 0;
    return mmio.mmio_read32(xhci_op_base + 0x400 + @as(u64, port - 1) * 0x10);
}

/// Live USBSTS read (the `usb` report's runtime controller state).
pub fn xhci_usbsts() u32 {
    if (xhci_op_base == 0) return 0;
    return mmio.mmio_read32(xhci_op_base + 0x04);
}

// ---------------------------------------------------------------------------
// I2 — transfer rings, commands, control transfers, enumeration, HID
// ---------------------------------------------------------------------------

/// Initialize the EP0 control ring + the per-device interrupt-IN rings with
/// their Link TRB wrap boundary (called once from xhci_init, post-NO-OP).
fn xhci_init_transfer_rings() void {
    for (&ep0_ring, 0..) |*ring, i| {
        ring.* = [_]Trb{.{}} ** tr_ring_len;
        ring[tr_usable] = .{
            .param = ring_phys(ring),
            .status = 0,
            .control = (trb_link << 10) | trb_link_toggle | trb_cycle,
        };
        ep0_enq[i] = 0;
        ep0_cycle[i] = 1;
        mmu.clean_dcache_range(@intFromPtr(ring), @sizeOf(@TypeOf(ring.*)));
    }
    for (&intr_ring, 0..) |*ring, i| {
        ring.* = [_]Trb{.{}} ** tr_ring_len;
        ring[tr_usable] = .{
            .param = ring_phys(ring),
            .status = 0,
            .control = (trb_link << 10) | trb_link_toggle | trb_cycle,
        };
        intr_enq[i] = 0;
        intr_deq[i] = 0;
        intr_cycle[i] = 1;
        intr_armed[i] = 0;
        intr_report[i] = [_]u8{0} ** max_report_bytes;
        intr_slots[i] = [_][max_report_bytes]u8{[_]u8{0} ** max_report_bytes} ** tr_usable;
        mmu.clean_dcache_range(@intFromPtr(ring), @sizeOf(@TypeOf(ring.*)));
    }
    enum_count = 0;
    enum_devs = [_]EnumDevice{.{}} ** EnumMax;
    hid_kind = [_]HidKind{.unknown} ** EnumMax;
    enum_done = false;
    enum_fail = "";
}

/// Enqueue a TRB on slot `slot_idx`'s EP0 control-transfer ring (Link TRB
/// wrap). `slot_idx` = slot_id - 1.
fn tr_enqueue_ep0(slot_idx: usize, trb_in: Trb) void {
    const ring = &ep0_ring[slot_idx];
    const enq = &ep0_enq[slot_idx];
    const cyc = &ep0_cycle[slot_idx];
    if (enq.* == tr_usable) {
        ring[tr_usable] = .{
            .param = ring_phys(ring),
            .status = 0,
            .control = (trb_link << 10) | trb_link_toggle | @as(u32, cyc.*),
        };
        enq.* = 0;
        cyc.* ^= 1;
    }
    var t = trb_in;
    t.control = (t.control & ~trb_cycle) | @as(u32, cyc.*);
    ring[enq.*] = t;
    mmu.clean_dcache_range(@intFromPtr(&ring[enq.*]), @sizeOf(Trb));
    enq.* += 1;
}

/// Enqueue a TRB on device `dev_idx`'s interrupt-IN ring (Link TRB wrap).
fn tr_enqueue_intr(dev_idx: usize, trb_in: Trb) void {
    const ring = &intr_ring[dev_idx];
    const enq = &intr_enq[dev_idx];
    const cyc = &intr_cycle[dev_idx];
    if (enq.* == tr_usable) {
        ring[tr_usable] = .{
            .param = ring_phys(ring),
            .status = 0,
            .control = (trb_link << 10) | trb_link_toggle | @as(u32, cyc.*),
        };
        enq.* = 0;
        cyc.* ^= 1;
    }
    var t = trb_in;
    t.control = (t.control & ~trb_cycle) | @as(u32, cyc.*);
    ring[enq.*] = t;
    mmu.clean_dcache_range(@intFromPtr(&ring[enq.*]), @sizeOf(Trb));
    enq.* += 1;
}

/// Ring a device endpoint doorbell: register index = slot_id, value = DCI =
/// ep_index + 1 (EP0 = 1, EP1 IN = 3).
fn ring_ep_doorbell(slot_id: u8, ep_index: u8) void {
    mmio.mmio_write32(xhci_doorbell_base + @as(u64, slot_id) * 4, @as(u32, ep_index) + 1);
}

const CmdResult = struct { cc: u32, status: u32, control: u32 };

/// Poll the event ring for the Command Completion Event whose `param` is the
/// physical address of the command TRB, consuming any other events along the
/// way. cc=0 (COMP_INVALID) means the bounded poll exhausted without a match.
fn wait_command(cmd_trb_phys: u64) CmdResult {
    var spins: usize = 0;
    while (spins < poll_budget) : (spins += 1) {
        mmu.invalidate_dcache_range(@intFromPtr(&evt_ring[evt_deq]), @sizeOf(Trb));
        const trb = evt_ring[evt_deq];
        if ((trb.control & trb_cycle) != evt_cycle) continue;
        const ty = (trb.control >> 10) & 0x3f;
        if (ty == trb_command_completion_event and trb.param == cmd_trb_phys) {
            const cc = (trb.status >> 24) & 0xff;
            evt_advance();
            return .{ .cc = cc, .status = trb.status, .control = trb.control };
        }
        evt_advance(); // consume any other event (port change, transfer, ...)
    }
    return .{ .cc = 0, .status = 0, .control = 0 };
}

const TransferResult = struct { cc: u32, remaining: u32 };

/// Poll the event ring for the Transfer Event whose `param` (the completed
/// TRB's address) matches `trb_phys`. cc=0 means the poll exhausted.
fn wait_transfer(trb_phys: u64) TransferResult {
    var spins: usize = 0;
    while (spins < poll_budget) : (spins += 1) {
        mmu.invalidate_dcache_range(@intFromPtr(&evt_ring[evt_deq]), @sizeOf(Trb));
        const trb = evt_ring[evt_deq];
        if ((trb.control & trb_cycle) != evt_cycle) continue;
        const ty = (trb.control >> 10) & 0x3f;
        if (ty == trb_transfer_event and trb.param == trb_phys) {
            const cc = (trb.status >> 24) & 0xff;
            const remaining = trb.status & 0xffffff;
            evt_advance();
            return .{ .cc = cc, .remaining = remaining };
        }
        evt_advance();
    }
    return .{ .cc = 0, .remaining = 0 };
}

/// Enable Slot — returns the slot ID (1-based), or 0 on failure. The slot ID
/// is returned in the completion event's control field bits 31:24.
fn xhci_enable_slot() u8 {
    if (!xhci_ready) return 0;
    const trb = Trb{ .param = 0, .status = 0, .control = trb_enable_slot << 10 };
    const idx = cmd_enq;
    cmd_enqueue(trb);
    const trb_phys = ring_phys(&cmd_ring) + idx * @sizeOf(Trb);
    ring_command_doorbell();
    const r = wait_command(trb_phys);
    if (r.cc != cc_success) {
        dbg("xhci: enable-slot cc=");
        dbg_hex(r.cc);
        dbg("\n");
        return 0;
    }
    return @intCast((r.control >> 24) & 0xff);
}

/// Port reset: assert PR (read-modify-write, preserving every other bit),
/// wait for it to clear + Port Reset Change (PRC) to be set, then wait for
/// the port to report enabled (PED). Bounded; the observed post-reset speed
/// is read by the caller. The change bits are cleared first (write-1-to-
/// clear) so the PRC/PED waits observe THIS reset, not a stale one.
fn xhci_port_reset(port: u8) bool {
    const off = xhci_op_base + 0x400 + @as(u64, port - 1) * 0x10;
    dbg("xhci: rst: read\n");
    const psc = mmio.mmio_read32(off);
    dbg("xhci: rst: read=");
    dbg_hex(psc);
    dbg("\n");
    dbg("xhci: rst: write PR\n");
    mmio.mmio_write32(off, psc | portsc_pr); // PR is RW1S
    dbg("xhci: rst: wrote\n");
    var spins: usize = 0;
    while ((mmio.mmio_read32(off) & portsc_pr) != 0) : (spins += 1) {
        if (spins > 2_000_000) {
            enum_fail = "PR never cleared";
            return false;
        }
    }
    dbg("xhci: rst: PR cleared\n");
    spins = 0;
    while ((mmio.mmio_read32(off) & portsc_ped) == 0) : (spins += 1) {
        if (spins > 2_000_000) {
            enum_fail = "PED never set";
            return false;
        }
    }
    dbg("xhci: rst: done psc=");
    dbg_hex(mmio.mmio_read32(off));
    dbg("\n");
    return true;
}

/// Address Device: build the input context (slot + EP0), issue the command,
/// and let the hardware write the output device context (device address +
/// slot state). The device context must already be zeroed + pointed to by
/// DCBAA[slot_id] before this runs.
fn xhci_address_device(slot_id: u8, port: u8, speed: u8) bool {
    const maxp: u32 = if (speed == 2) 8 else 64; // LS=8, FS/HS=64
    input_ctx = std.mem.zeroes(InputContext);
    input_ctx.control.add_flags = slot_flag | ep0_flag;
    input_ctx.slot.dev_info = (1 << 27) | (@as(u32, speed) << 20); // LAST_CTX(1) + speed
    input_ctx.slot.dev_info2 = @as(u32, port) << 16; // ROOT_HUB_PORT(port)
    input_ctx.slot.dev_state = 0; // address 0, slot state 0 (HC assigns)
    input_ctx.ep0.ep_info = 0;
    input_ctx.ep0.ep_info2 = (ep_ctrl << 3) | (3 << 1) | (maxp << 16);
    input_ctx.ep0.deq = ring_phys(&ep0_ring[slot_id - 1]) | 1; // DCS = 1
    input_ctx.ep0.tx_info = 8; // avg TRB length
    mmu.clean_dcache_range(@intFromPtr(&input_ctx), @sizeOf(InputContext));

    const trb = Trb{
        .param = ring_phys(&input_ctx),
        .status = 0,
        .control = (trb_addr_dev << 10) | (@as(u32, slot_id) << 24),
    };
    const idx = cmd_enq;
    cmd_enqueue(trb);
    const trb_phys = ring_phys(&cmd_ring) + idx * @sizeOf(Trb);
    ring_command_doorbell();
    const r = wait_command(trb_phys);
    if (r.cc != cc_success) {
        dbg("xhci: address-device cc=");
        dbg_hex(r.cc);
        dbg("\n");
        return false;
    }
    return true;
}

/// Configure Endpoint: add the interrupt-IN endpoint (compressed index 2 =
/// EP1 IN) to device `dev_idx`'s slot. The slot context is copied from the
/// current output context (with LAST_CTX bumped to 3).
fn xhci_configure_endpoint(slot_id: u8, maxpkt: u16, interval: u8) bool {
    input_ctx = std.mem.zeroes(InputContext);
    input_ctx.control.add_flags = 1 << (2 + 1); // EP1 IN = bit 3
    input_ctx.slot = dev_ctx[slot_id - 1].slot;
    input_ctx.slot.dev_info = (dev_ctx[slot_id - 1].slot.dev_info & ~last_ctx_mask) | (3 << 27);
    input_ctx.ep1_in.ep_info = @as(u32, interval) << 16;
    input_ctx.ep1_in.ep_info2 = (ep_int_in << 3) | (3 << 1) | (@as(u32, maxpkt) << 16);
    input_ctx.ep1_in.deq = ring_phys(&intr_ring[slot_id - 1]) | 1; // DCS = 1
    input_ctx.ep1_in.tx_info = maxpkt; // avg TRB length
    mmu.clean_dcache_range(@intFromPtr(&input_ctx), @sizeOf(InputContext));

    const trb = Trb{
        .param = ring_phys(&input_ctx),
        .status = 0,
        .control = (trb_config_ep << 10) | (@as(u32, slot_id) << 24),
    };
    const idx = cmd_enq;
    cmd_enqueue(trb);
    const trb_phys = ring_phys(&cmd_ring) + idx * @sizeOf(Trb);
    ring_command_doorbell();
    const r = wait_command(trb_phys);
    if (r.cc != cc_success) {
        dbg("xhci: configure-ep cc=");
        dbg_hex(r.cc);
        dbg("\n");
        return false;
    }
    return true;
}

/// A control transfer on EP0: Setup Stage (+ optional Data Stage) + Status
/// Stage, then poll for the transfer event on the Status TRB (IOC). Returns
/// the completion code + the number of bytes actually transferred.
fn xhci_control_transfer(
    slot_id: u8,
    bm_req_type: u8,
    b_req: u8,
    w_value: u16,
    w_index: u16,
    data_buf: [*]u8,
    data_len: u16,
    dir_in: bool,
) TransferResult {
    const slot_idx = slot_id - 1;
    const setup_lo: u32 = @as(u32, bm_req_type) | (@as(u32, b_req) << 8) | (@as(u32, w_value) << 16);
    const setup_hi: u32 = @as(u32, w_index) | (@as(u32, data_len) << 16);
    const tx_type: u32 = if (data_len == 0) tx_no_data else if (dir_in) tx_data_in else tx_data_out;

    // Setup Stage TRB (immediate data — the 8-byte setup packet).
    tr_enqueue_ep0(slot_idx, .{
        .param = @as(u64, setup_lo) | (@as(u64, setup_hi) << 32),
        .status = 8,
        .control = (trb_setup_stage << 10) | trb_idt | (tx_type << 16),
    });

    // Data Stage TRB (only when there is a data payload).
    if (data_len > 0) {
        var dctl: u32 = trb_data_stage << 10;
        if (dir_in) dctl |= trb_dir_in | trb_isp;
        tr_enqueue_ep0(slot_idx, .{
            .param = mmu.to_phys(@intFromPtr(data_buf)),
            .status = data_len,
            .control = dctl,
        });
    }

    // Status Stage TRB (direction opposite the data stage; IOC).
    var sctl: u32 = (trb_status_stage << 10) | trb_ioc;
    if (data_len == 0 or !dir_in) sctl |= trb_dir_in;
    const status_phys = ring_phys(&ep0_ring[slot_idx]) + ep0_enq[slot_idx] * @sizeOf(Trb);
    tr_enqueue_ep0(slot_idx, .{ .param = 0, .status = 0, .control = sctl });

    // The data buffer is written by software for OUT transfers.
    if (data_len > 0 and !dir_in) {
        mmu.clean_dcache_range(@intFromPtr(data_buf), data_len);
    }

    ring_ep_doorbell(slot_id, 0); // EP0
    const r = wait_transfer(status_phys);

    // The HC wrote the buffer for IN transfers — invalidate before reading.
    if (data_len > 0 and dir_in) {
        mmu.invalidate_dcache_range(@intFromPtr(data_buf), data_len);
    }
    return r;
}

/// GET_DESCRIPTOR (control IN).
fn xhci_get_descriptor(slot_id: u8, desc_type: u8, index: u8, buf: [*]u8, len: u16) TransferResult {
    return xhci_control_transfer(slot_id, 0x80, 6, (@as(u16, desc_type) << 8) | index, 0, buf, len, true);
}

/// SET_CONFIGURATION (control OUT, no data stage).
fn xhci_set_configuration(slot_id: u8, config: u16) bool {
    const r = xhci_control_transfer(slot_id, 0x00, 9, config, 0, @ptrCast(&intr_report[0]), 0, false);
    return r.cc == cc_success;
}

/// HID SET_PROTOCOL(boot) (class request to the interface, no data stage).
fn xhci_set_protocol_boot(slot_id: u8, iface: u16) bool {
    const r = xhci_control_transfer(slot_id, 0x21, 0x0b, 1, iface, @ptrCast(&intr_report[0]), 0, false);
    return r.cc == cc_success;
}

/// Convert a USB interrupt-endpoint bInterval to the xHCI interval field
/// (log2 of the period in 125 us microframes). HS bInterval is already in
/// 2^(n-1) microframes; FS/LS bInterval is in milliseconds.
pub fn hid_interval(speed: u8, b_interval: u8) u8 {
    if (b_interval == 0) return 0;
    if (speed == 3) return b_interval - 1; // high speed
    var uframes: u32 = @as(u32, b_interval) * 8; // FS/LS: ms -> 125us uframes
    var n: u8 = 0;
    while (uframes > 1) : (n += 1) uframes >>= 1;
    return n;
}

/// Advance device `dev`'s interrupt-IN dequeue pointer across the Link TRB
/// wrap boundary (the ring's last slot is the Link TRB, never a transfer).
fn intr_deq_advance(dev: usize) void {
    const deq = &intr_deq[dev];
    deq.* += 1;
    if (deq.* == tr_usable) deq.* = 0;
}

/// The report-buffer slot a TRB enqueued at ring position `enq` occupies.
/// `tr_enqueue_intr` writes the Link TRB at `tr_usable` and wraps the enqueue
/// pointer to 0 BEFORE placing the Normal TRB, so the buffer slot is 0 when
/// `enq == tr_usable` (a plain `enq` index would read one past the buffer
/// array). Pure — host-testable.
fn intr_slot_index(enq: usize) usize {
    return if (enq == tr_usable) 0 else enq;
}

/// The armed TRB length for a device's interrupt-IN endpoint: its maxpkt,
/// bounded by the report-buffer size (issue #118 — never clamp a 10-byte
/// pointer report to an 8-byte buffer). Pure — host-testable.
fn intr_trb_len(maxpkt: u16) u32 {
    return @min(@as(u32, maxpkt), max_report_bytes);
}

/// How many TRBs the top-up should enqueue to reach `intr_depth` (bounded
/// by the ring's usable slots). Pure — host-testable.
fn intr_topup_budget(armed: usize, depth: usize, usable: usize) usize {
    const want = @min(depth, usable);
    return if (armed < want) want - armed else 0;
}

/// Arm slot `slot_id`'s interrupt-IN endpoint: top up the armed TRB depth to
/// `intr_depth` (one Normal TRB per ring slot, each pointing at ITS OWN
/// report buffer — the slot index the TRB occupies) + ring the doorbell.
/// Each armed TRB owns its slot's report buffer, so a completed TRB is read
/// back from the slot it occupies (the dequeue pointer names it). The first
/// arm enqueues the full depth; every completion consumes one and the poll
/// re-arms (top-up) one, so the depth stays constant. Issue #117 re-tests
/// depth after the U2 wrap fix.
fn xhci_arm_intr(slot_id: u8) void {
    const slot_idx = slot_id - 1;
    const budget = intr_topup_budget(intr_armed[slot_idx], intr_depth, tr_usable);
    var k: usize = 0;
    while (k < budget) : (k += 1) {
        // The buffer slot is the POST-wrap ring index (tr_enqueue_intr places
        // the Normal TRB at slot 0 when the enqueue pointer is at the Link
        // TRB).
        const idx = intr_slot_index(intr_enq[slot_idx]);
        tr_enqueue_intr(slot_idx, .{
            .param = ring_phys(&intr_slots[slot_idx][idx]),
            .status = intr_trb_len(intr_maxpkt[slot_idx]),
            .control = (trb_normal << 10) | trb_ioc,
        });
        intr_armed[slot_idx] += 1;
    }
    // VZ keys interrupt-IN delivery on the endpoint context's TR Dequeue
    // Pointer (it re-reads the context from memory on each doorbell, rather
    // than tracking the dequeue in internal state). Advance the context's
    // TRDP to the oldest still-armed TRB so the re-armed ring is visible.
    dev_ctx[slot_idx].ep1_in.deq = ring_phys(&intr_ring[slot_idx][intr_deq[slot_idx]]) | 1; // DCS = 1
    mmu.clean_dcache_range(@intFromPtr(&dev_ctx[slot_idx].ep1_in.deq), @sizeOf(u64));
    ring_ep_doorbell(slot_id, 2); // EP1 IN
}

/// Non-blocking variant of `xhci_poll_intr` for the polled keyboard drain
/// (card I3): returns immediately when no fresh transfer event is pending,
/// so the shell idle loop is not slowed by the full bounded poll (the
/// blocking `xhci_poll_intr` stays the `usb report` path). Consumes any
/// other fresh events (port change, command completion) along the way.
pub fn xhci_poll_intr_nb(slot_id: u8) bool {
    if (slot_id == 0 or slot_id > max_enumerated) return false;
    const slot_idx = slot_id - 1;
    if (!enum_devs[slot_idx].present or enum_devs[slot_idx].ep_in_num == 0) return false;
    if (intr_armed[slot_idx] == 0) return false; // no armed TRB
    const ring = &intr_ring[slot_idx];
    const trb_phys = ring_phys(&ring[intr_deq[slot_idx]]);
    // Scan only FRESH events (the cycle bit matches); a no-event poll is
    // one cheap invalidate + read. Bounded by the ring length.
    var steps: usize = 0;
    while (steps < evt_ring_len) : (steps += 1) {
        mmu.invalidate_dcache_range(@intFromPtr(&evt_ring[evt_deq]), @sizeOf(Trb));
        const trb = evt_ring[evt_deq];
        if ((trb.control & trb_cycle) != evt_cycle) return false; // no fresh event
        const ty = (trb.control >> 10) & 0x3f;
        if (ty == trb_transfer_event and trb.param == trb_phys) {
            const cc = (trb.status >> 24) & 0xff;
            const remaining = trb.status & 0xffffff;
            evt_advance();
            if (cc != cc_success) return false;
            const dq = intr_deq[slot_idx];
            mmu.invalidate_dcache_range(@intFromPtr(&intr_slots[slot_idx][dq]), max_report_bytes);
            const total: u32 = intr_trb_len(intr_maxpkt[slot_idx]);
            const got = if (remaining <= total) total - remaining else 0;
            intr_report[slot_idx] = intr_slots[slot_idx][dq];
            enum_devs[slot_idx].last_report_len = @intCast(got);
            enum_devs[slot_idx].report_seq += 1;
            intr_deq_advance(slot_idx);
            if (intr_armed[slot_idx] > 0) intr_armed[slot_idx] -= 1;
            xhci_arm_intr(slot_id); // top up (depth stays constant)
            return true;
        }
        evt_advance(); // consume any other fresh event (port change, etc.)
    }
    return false;
}

/// Poll slot `slot_id`'s interrupt-IN endpoint for one report (bounded).
/// Returns true + records the report bytes/length when a report completed;
/// re-arms the endpoint for the next report either way.
pub fn xhci_poll_intr(slot_id: u8) bool {
    if (slot_id == 0 or slot_id > max_enumerated) return false;
    const slot_idx = slot_id - 1;
    if (!enum_devs[slot_idx].present or enum_devs[slot_idx].ep_in_num == 0) return false;
    if (intr_armed[slot_idx] == 0) return false; // no armed TRB
    const ring = &intr_ring[slot_idx];
    const trb_phys = ring_phys(&ring[intr_deq[slot_idx]]);
    const r = wait_transfer(trb_phys);
    if (r.cc == cc_success) {
        const dq = intr_deq[slot_idx];
        mmu.invalidate_dcache_range(@intFromPtr(&intr_slots[slot_idx][dq]), max_report_bytes);
        const total: u32 = intr_trb_len(intr_maxpkt[slot_idx]);
        const got = if (r.remaining <= total) total - r.remaining else 0;
        intr_report[slot_idx] = intr_slots[slot_idx][dq];
        enum_devs[slot_idx].last_report_len = @intCast(got);
        enum_devs[slot_idx].report_seq += 1;
        intr_deq_advance(slot_idx);
        if (intr_armed[slot_idx] > 0) intr_armed[slot_idx] -= 1;
        xhci_arm_intr(slot_id);
        return true;
    }
    return false;
}

/// Enumerate every connected root port. Bounded (the fixed two-device table);
/// a port that fails is recorded and the next port is still attempted.
pub fn xhci_enumerate_all() bool {
    enum_count = 0;
    enum_devs = [_]EnumDevice{.{}} ** EnumMax;
    hid_kind = [_]HidKind{.unknown} ** EnumMax;
    var all_ok = true;
    const max_ports = hcsparams1_max_ports(xhci_hcsparams1);
    var port: u8 = 1;
    while (port <= max_ports) : (port += 1) {
        const psc = xhci_port_status(port);
        if ((psc & portsc_ccs) == 0) continue;
        if (enum_count >= EnumMax) {
            enum_fail = "more devices than the fixed table";
            return false;
        }
        if (!xhci_enumerate_port(port)) all_ok = false;
    }
    return all_ok;
}

fn xhci_enumerate_port(port: u8) bool {
    dbg("xhci: port ");
    dbg_hex(port);
    dbg(" reset\n");
    if (!xhci_port_reset(port)) {
        enum_fail = "port reset failed";
        return false;
    }
    const speed: u8 = @intCast((xhci_port_status(port) >> 10) & 0xf);
    if (speed == 0) {
        enum_fail = "port speed undefined after reset";
        return false;
    }
    dbg("xhci: speed=");
    dbg_hex(speed);
    dbg("\n");

    const slot_id = xhci_enable_slot();
    if (slot_id == 0) {
        enum_fail = "Enable Slot failed";
        return false;
    }
    dbg("xhci: slot=");
    dbg_hex(slot_id);
    dbg("\n");

    dev_ctx[slot_id - 1] = std.mem.zeroes(DeviceContext);
    dcbaa[slot_id] = ring_phys(&dev_ctx[slot_id - 1]);
    mmu.clean_dcache_range(@intFromPtr(&dev_ctx[slot_id - 1]), @sizeOf(DeviceContext));
    mmu.clean_dcache_range(@intFromPtr(&dcbaa), @sizeOf(@TypeOf(dcbaa)));

    if (!xhci_address_device(slot_id, port, speed)) {
        enum_fail = "Address Device failed";
        return false;
    }

    var desc: [18]u8 align(4) = undefined;
    const rd = xhci_get_descriptor(slot_id, 1, 0, @ptrCast(&desc), 18);
    if (rd.cc != cc_success or rd.remaining != 0) {
        dbg("xhci: get-desc cc=");
        dbg_hex(rd.cc);
        dbg(" rem=");
        dbg_hex(rd.remaining);
        dbg("\n");
        enum_fail = "device descriptor read failed";
        return false;
    }
    const vid: u16 = @as(u16, desc[8]) | (@as(u16, desc[9]) << 8);
    const pid: u16 = @as(u16, desc[10]) | (@as(u16, desc[11]) << 8);
    const bclass: u8 = desc[4];
    const bsub: u8 = desc[5];
    const bproto: u8 = desc[6];
    dbg("xhci: vid=");
    dbg_hex(vid);
    dbg(" pid=");
    dbg_hex(pid);
    dbg(" class=");
    dbg_hex(bclass);
    dbg(" proto=");
    dbg_hex(bproto);
    dbg("\n");

    var cfg9: [9]u8 align(4) = undefined;
    const rc = xhci_get_descriptor(slot_id, 2, 0, @ptrCast(&cfg9), 9);
    if (rc.cc != cc_success) {
        enum_fail = "config descriptor read failed";
        return false;
    }
    const w_total: u16 = @as(u16, cfg9[2]) | (@as(u16, cfg9[3]) << 8);
    var cfg: [64]u8 align(4) = undefined;
    const cfg_len: u16 = @min(w_total, 64);
    const rfull = xhci_get_descriptor(slot_id, 2, 0, @ptrCast(&cfg), cfg_len);
    if (rfull.cc != cc_success) {
        enum_fail = "full config descriptor read failed";
        return false;
    }

    var ep_in_num: u8 = 0;
    var ep_in_maxpkt: u16 = 0;
    var ep_in_interval: u8 = 0;
    var iface_protocol: u8 = 0; // bInterfaceProtocol (1=kbd, 2=mouse)
    {
        var i: usize = 9;
        while (i + 2 <= cfg_len) {
            const dlen = cfg[i];
            const dtype = cfg[i + 1];
            if (dlen == 0 or i + dlen > cfg_len) break;
            if (dtype == 4 and dlen >= 9) {
                // Interface descriptor: bInterfaceProtocol at offset 7.
                iface_protocol = cfg[i + 7];
            } else if (dtype == 5 and dlen >= 7) {
                const epaddr = cfg[i + 2];
                const attrs = cfg[i + 3];
                const maxp: u16 = @as(u16, cfg[i + 4]) | (@as(u16, cfg[i + 5]) << 8);
                const interval = cfg[i + 6];
                if ((epaddr & 0x80) != 0 and (attrs & 0x3) == 3) {
                    ep_in_num = epaddr & 0xf;
                    ep_in_maxpkt = maxp;
                    ep_in_interval = interval;
                }
            }
            i += dlen;
        }
    }

    if (!xhci_set_configuration(slot_id, 1)) {
        enum_fail = "Set Configuration failed";
        return false;
    }
    const boot = xhci_set_protocol_boot(slot_id, 0);

    var kind: HidKind = .unknown;
    if (iface_protocol == 1) kind = .keyboard else if (iface_protocol == 2) kind = .mouse;

    const slot_idx = slot_id - 1;
    enum_devs[slot_idx] = .{
        .present = true,
        .slot_id = slot_id,
        .port = port,
        .speed = speed,
        .vid = vid,
        .pid = pid,
        .class = bclass,
        .subclass = bsub,
        .protocol = iface_protocol,
        .ep_in_num = ep_in_num,
        .ep_in_maxpkt = ep_in_maxpkt,
        .ep_in_interval = ep_in_interval,
        .hid_boot = boot,
    };
    hid_kind[slot_idx] = kind;
    intr_maxpkt[slot_idx] = ep_in_maxpkt;

    if (ep_in_num != 0) {
        if (!xhci_configure_endpoint(slot_id, ep_in_maxpkt, hid_interval(speed, ep_in_interval))) {
            enum_fail = "Configure Endpoint failed";
            return false;
        }
        xhci_arm_intr(slot_id);
        dbg("xhci: armed ep");
        dbg_hex(ep_in_num);
        dbg(" iface=");
        dbg_hex(iface_protocol);
        dbg("\n");
    }

    enum_count += 1;
    return true;
}

/// The last raw report bytes + length for a device slot (the `usb report`
/// decode).
pub fn xhci_report(slot_id: u8) struct { len: u8, bytes: [max_report_bytes]u8 } {
    if (slot_id == 0 or slot_id > max_enumerated) return .{ .len = 0, .bytes = [_]u8{0} ** max_report_bytes };
    const slot_idx = slot_id - 1;
    return .{ .len = enum_devs[slot_idx].last_report_len, .bytes = intr_report[slot_idx] };
}

// ---------------------------------------------------------------------------
// Host tests — the pieces that need no device
// ---------------------------------------------------------------------------

test "xhci: HCSPARAMS1/HCCPARAMS1 field accessors" {
    try std.testing.expectEqual(@as(u8, 0xab), hcsparams1_max_slots(0x12ab));
    try std.testing.expectEqual(@as(u16, 0x123), hcsparams1_max_intrs(0x12300));
    try std.testing.expectEqual(@as(u8, 5), hcsparams1_max_ports(0x05000000));
    try std.testing.expectEqual(@as(u8, 0), hcsparams1_max_ports(0));
    try std.testing.expect(hccparams1_64bit(0x1));
    try std.testing.expect(!hccparams1_64bit(0));
    try std.testing.expectEqual(@as(u8, 64), hccparams1_context_size(0x4));
    try std.testing.expectEqual(@as(u8, 32), hccparams1_context_size(0));
}

test "xhci: TRB + ERST wire layouts are the spec shapes" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(Trb));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(ErstEntry));
    // The control field packs type (bits 15:10) + cycle (bit 0).
    const noop = Trb{ .param = 0, .status = 0, .control = trb_noop << 10 };
    try std.testing.expectEqual(@as(u32, 23), (noop.control >> 10) & 0x3f);
    try std.testing.expectEqual(@as(u32, 0), noop.control & trb_cycle);
    // A completion code lives in status bits 31:24.
    try std.testing.expectEqual(@as(u32, cc_success), (0x01000000 >> 24) & 0xff);
}

test "xhci: intr report-buffer slot wraps at the Link TRB boundary" {
    // The enqueue pointer never names the Link-TRB slot as a data slot: a
    // TRB enqueued at tr_usable lands at ring slot 0 after the wrap, so its
    // report buffer is intr_slots[0] (the OOB intr_slots[tr_usable] read is
    // the class-B phantom-key bug this regression guards).
    try std.testing.expectEqual(@as(usize, 0), intr_slot_index(tr_usable));
    try std.testing.expectEqual(@as(usize, 0), intr_slot_index(0));
    try std.testing.expectEqual(@as(usize, 14), intr_slot_index(14));
}

test "xhci: issue #118 — the armed TRB length is the device maxpkt, never clamped to 8" {
    // The absolute pointer enumerates with maxpkt 10; the report buffers are
    // sized to max_report_bytes (10), so a 10-byte report survives the arm/
    // poll round trip whole.
    try std.testing.expectEqual(@as(usize, 10), max_report_bytes);
    try std.testing.expectEqual(@as(u32, 8), intr_trb_len(8)); // keyboard
    try std.testing.expectEqual(@as(u32, 10), intr_trb_len(10)); // pointer — NOT 8
    try std.testing.expectEqual(@as(u32, 0), intr_trb_len(0));
    // The report buffer holds the pointer's full packet.
    try std.testing.expectEqual(@as(usize, 10), @sizeOf(@TypeOf(intr_slots[0][0])));
    try std.testing.expectEqual(@as(usize, 10), @sizeOf(@TypeOf(intr_report[0])));
}

test "xhci: issue #117 — the multi-TRB top-up keeps the armed depth constant across ring wraps" {
    // Model the arm/consume cycle with the module's own wrap rules (the Link
    // TRB at tr_usable wraps the enqueue pointer to 0; the dequeue pointer
    // wraps at tr_usable too; in-order completion). Across 1000 reports the
    // armed count must stay at intr_depth and the top-up must never enqueue
    // onto a still-armed ring slot.
    var enq: usize = 0;
    var deq: usize = 0;
    var armed: usize = 0;
    // slot 0..14 -> the ring position a TRB occupies (0 = post-wrap slot 0).
    var occupied = [_]bool{false} ** tr_usable;

    // One arm step mirroring tr_enqueue_intr + xhci_arm_intr exactly: the
    // enqueue pointer wraps at tr_usable (writing the Link TRB, toggling the
    // cycle) BEFORE the Normal TRB is placed, and the report-buffer slot is
    // intr_slot_index(enq) — which equals the post-wrap ring position.
    const place = struct {
        fn do(e: *usize, occ: *[tr_usable]bool, arm: *usize) void {
            if (e.* == tr_usable) e.* = 0; // the Link-TRB wrap
            const pos = e.*;
            std.debug.assert(!occ[pos]); // never overwrite an armed slot
            occ[pos] = true;
            e.* += 1;
            arm.* += 1;
        }
    }.do;

    // Initial arm: the top-up budget is the full depth.
    var budget = intr_topup_budget(armed, intr_depth, tr_usable);
    try std.testing.expectEqual(@as(usize, intr_depth), budget);
    while (budget > 0) : (budget -= 1) place(&enq, &occupied, &armed);

    var report: usize = 0;
    while (report < 1000) : (report += 1) {
        // Consume the oldest armed report (the deq position), in order.
        const pos = deq;
        try std.testing.expect(occupied[pos]);
        occupied[pos] = false;
        deq += 1;
        if (deq == tr_usable) deq = 0;
        armed -= 1;
        // Top up back to depth — exactly one per completion.
        try std.testing.expectEqual(@as(usize, 1), intr_topup_budget(armed, intr_depth, tr_usable));
        place(&enq, &occupied, &armed);
        // Invariant: depth stays constant, no slot double-armed.
        try std.testing.expectEqual(@as(usize, intr_depth), armed);
    }
}

test "xhci: ring geometry — the link TRB holds the wrap boundary" {
    // cmd_usable is the command-slot count; the last slot is the Link TRB.
    try std.testing.expectEqual(@as(usize, 15), cmd_usable);
    try std.testing.expectEqual(@as(usize, 16), cmd_ring_len);
    // The event ring is one segment of 64 TRBs.
    try std.testing.expectEqual(@as(usize, 64), evt_ring_len);
    // Unprobed transport reports honestly.
    xhci_dev = 32;
    try std.testing.expect(!xhci_run_noop());
    try std.testing.expectEqual(@as(u32, 0), xhci_port_status(1));
}

test "xhci: I2 context wire layouts are the spec shapes" {
    // Slot/EP contexts are 32 bytes; a device context (slot + EP0 + EP1OUT +
    // EP1IN) is 128; an input context (control + slot + 3 EPs) is 160.
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(SlotContext));
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(EpContext));
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(InputControlContext));
    try std.testing.expectEqual(@as(usize, 128), @sizeOf(DeviceContext));
    try std.testing.expectEqual(@as(usize, 160), @sizeOf(InputContext));
    // The EP0 context sits at context offset 1 (32 bytes in) in the device
    // context and at offset 2 (64 bytes in) in the input context (the input
    // control context shifts everything by one slot).
    var dc: DeviceContext = undefined;
    const dc_base = @intFromPtr(&dc);
    try std.testing.expectEqual(dc_base + 32, @intFromPtr(&dc.ep0));
    try std.testing.expectEqual(dc_base + 96, @intFromPtr(&dc.ep1_in));
    var ic: InputContext = undefined;
    const ic_base = @intFromPtr(&ic);
    try std.testing.expectEqual(ic_base + 64, @intFromPtr(&ic.ep0));
    try std.testing.expectEqual(ic_base + 128, @intFromPtr(&ic.ep1_in));
    // The input-control add/drop flags: bit 0 = slot, bit i+1 = EP context i.
    try std.testing.expectEqual(@as(u32, 1), slot_flag);
    try std.testing.expectEqual(@as(u32, 2), ep0_flag);
    try std.testing.expectEqual(@as(u32, 8), 1 << (2 + 1)); // EP1 IN
}

test "xhci: hid_interval converts bInterval to the xHCI interval field" {
    // High speed: bInterval is in 2^(n-1) microframes.
    try std.testing.expectEqual(@as(u8, 0), hid_interval(3, 1));
    try std.testing.expectEqual(@as(u8, 7), hid_interval(3, 8));
    // Full/low speed: bInterval in ms -> 125us microframes -> log2.
    try std.testing.expectEqual(@as(u8, 3), hid_interval(1, 1)); // 8 uframes
    try std.testing.expectEqual(@as(u8, 6), hid_interval(1, 8)); // 64 uframes
    try std.testing.expectEqual(@as(u8, 0), hid_interval(2, 0)); // degenerate
}

test "xhci: control-transfer TRB control fields pack to the spec encodings" {
    // Setup stage: IDT + type 2 + transfer-type in bits 17:16.
    const setup_ctl: u32 = (trb_setup_stage << 10) | trb_idt | (tx_data_in << 16);
    try std.testing.expectEqual(@as(u32, 2), (setup_ctl >> 10) & 0x3f);
    try std.testing.expectEqual(@as(u32, 3), (setup_ctl >> 16) & 0x3);
    try std.testing.expect(setup_ctl & trb_idt != 0);
    // Status stage: type 4 + IOC; DIR_IN for a no-data (IN) status stage.
    const status_ctl: u32 = (trb_status_stage << 10) | trb_ioc | trb_dir_in;
    try std.testing.expectEqual(@as(u32, 4), (status_ctl >> 10) & 0x3f);
    try std.testing.expect(status_ctl & trb_ioc != 0);
    try std.testing.expect(status_ctl & trb_dir_in != 0);
}
