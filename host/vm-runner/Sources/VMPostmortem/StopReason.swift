// Claim #1278: the host half of the fault/state recorder (the unblock for
// #1261).
//
// VZVirtualMachineDelegate is the only channel through which Virtualization
// narrates WHY a VM stopped — the runner set no delegate at all before this, so
// a dying boot surfaced as the bare `state=3` and an entire investigation
// (#1261) could not falsify anything from the outside.
//
// This module deliberately imports NO Virtualization (the VFWire / VSSH
// precedent): the formatting and the ordering rules are the parts that can be
// wrong, and `Tests/VMRunnerTests/StopReasonTests.swift` pins them with no VM.
// `VMRunnerDelegate` in main.swift is then a two-line adapter over this, and the
// only thing it adds is the VZ selector surface.
//
// Ordering rule, and why it is not simply "first wins": an error OUTRANKS a
// clean power-off. The two callbacks are mutually exclusive in practice, but if
// a guest-powered-off transition ever races a failure, a clean stop recorded
// first would mask the error — and losing the error is precisely the failure
// this recorder exists to prevent. Among errors, the first is kept: the earliest
// one is nearest the cause, and later ones are typically consequences.

import Foundation

public final class StopReasonRecorder {
    /// The line recorded for a clean guest-initiated power-off.
    public static let cleanStop = "guest-powered-off"

    /// The placeholder used when the VM stopped and VZ said nothing about why
    /// (a guest shutdown VZ never narrates). Printed rather than omitted so a
    /// reader can tell "the recorder is wired and reported nothing" apart from
    /// "the recorder was never wired".
    public static let noReason = "<none reported by VZ>"

    private let lock = NSLock()
    private var recorded: String?
    private var sawError = false

    public init() {}

    /// A clean guest-initiated power-off. Recorded only if nothing else has
    /// been: an error is always the more informative verdict.
    public func recordGuestPoweredOff() {
        lock.lock()
        if recorded == nil { recorded = Self.cleanStop }
        lock.unlock()
    }

    /// A failure. Outranks a clean stop (and any later error).
    public func recordError(_ error: Error) {
        let line = Self.describe(error)
        lock.lock()
        if !sawError {
            sawError = true
            recorded = line
        }
        lock.unlock()
    }

    /// The reason the VM stopped, or nil when nothing has been reported.
    public var reason: String? {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    /// The ` reason=…` suffix the runner's verdict lines print. One shape for
    /// both branches (the scripted failure path and the console-exit path), so
    /// a dying boot reads the same however it was launched.
    public func verdictSuffix() -> String {
        if let recorded { return " reason=\(recorded)" }
        return " reason=\(Self.noReason)"
    }

    /// Domain and code are the machine-readable half (VZErrorDomain codes
    /// distinguish a configuration rejection from a vCPU failure); the
    /// description is the half a human needs; userInfo usually carries the
    /// underlying one. Sorted so the line is stable across runs.
    public static func describe(_ error: Error) -> String {
        let ns = error as NSError
        var line = "domain=\(ns.domain) code=\(ns.code) desc=\(ns.localizedDescription)"
        if !ns.userInfo.isEmpty {
            let nested = ns.userInfo
                .map { "\($0.key)=\($0.value)" }
                .sorted()
                .joined(separator: " ")
            line += " userInfo={\(nested)}"
        }
        return line
    }
}
