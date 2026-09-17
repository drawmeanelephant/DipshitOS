import Darwin
import Foundation
import Virtualization

final class VZRestoreProbe {
    private let vm: VZVirtualMachine
    private let queue: DispatchQueue
    private let serialURL: URL
    private let input: FileHandle
    private let deadline: Date
    private let marker = "VZSR-" + UUID().uuidString
    private let stateURL: URL
    private var phase = "boot"
    private var serialOffset = 0

    init(vm: VZVirtualMachine, queue: DispatchQueue, serialURL: URL, input: FileHandle, timeout: TimeInterval) {
        self.vm = vm
        self.queue = queue
        self.serialURL = serialURL
        self.input = input
        deadline = Date().addingTimeInterval(timeout)
        stateURL = serialURL.deletingLastPathComponent().appendingPathComponent("vz-state-\(UUID().uuidString).vzsave")
    }

    func start() {
        print("VZ-RESTORE: standalone RAM clipboard probe; state file \(stateURL.path)")
        poll()
    }

    private func abort(_ message: String) -> Never {
        FileHandle.standardError.write(Data("ERROR: VZ-RESTORE: \(phase): \(message); no snapshot or reboot fallback.\n".utf8))
        exit(1)
    }

    private func checked(_ error: Error?, _ operation: String, state: VZVirtualMachine.State) {
        if let error { abort("\(operation): \(error as NSError)") }
        guard vm.state == state else { abort("\(operation): unexpected state=\(vm.state.rawValue)") }
        print("VZ-RESTORE: \(operation) completed state=\(vm.state.rawValue)")
    }

    private func send(_ commands: String) {
        do { try input.write(contentsOf: Data(commands.utf8)) }
        catch { abort("serial input: \(error)") }
    }

    private func poll() {
        guard Date() < deadline else { abort("deadline exceeded") }
        guard vm.state == .running else { abort("unexpected VM state=\(vm.state.rawValue)") }
        let data: Data
        do { data = try Data(contentsOf: serialURL) }
        catch { abort("serial read: \(error)") }
        guard data.count >= serialOffset else { abort("serial log shrank") }
        let text = String(decoding: data.dropFirst(serialOffset), as: UTF8.self)
        let markerLine = "clip: \(marker)"
        let hasMarker = text.components(separatedBy: "\n").contains(markerLine)
        if phase == "boot", text.contains("kernel terminal state") {
            phase = "before-save"
            send("clip \(marker)\nclip\n")
        } else if phase == "before-save", hasMarker {
            print("VZ-RESTORE: before-save guest marker=\(marker)")
            saveAndRestore()
            return
        } else if phase == "after-restore", hasMarker {
            print("VZ-RESTORE: after-restore guest marker=\(marker) serial-offset=\(serialOffset)")
            phase = "final-stop"
            vm.stop { error in
                self.checked(error, "final stop", state: .stopped)
                do { try FileManager.default.removeItem(at: self.stateURL) }
                catch { self.abort("saved-state cleanup: \(error)") }
                print("VZ-RESTORE: PASS CPU/memory/device restore; fresh serial query recovered RAM marker")
                exit(0)
            }
            return
        }
        queue.asyncAfter(deadline: .now() + 0.5) { self.poll() }
    }

    private func saveAndRestore() {
#if arch(arm64)
        phase = "pause"
        vm.pause { result in
            if case .failure(let error) = result { self.abort("pause: \(error as NSError)") }
            self.checked(nil, "pause", state: .paused)
            self.phase = "save"
            self.vm.saveMachineStateTo(url: self.stateURL) { error in
                self.checked(error, "saveMachineStateTo", state: .paused)
                self.phase = "stop"
                self.vm.stop { error in
                    self.checked(error, "stop", state: .stopped)
                    self.phase = "restore"
                    self.vm.restoreMachineStateFrom(url: self.stateURL) { error in
                        self.checked(error, "restoreMachineStateFrom", state: .paused)
                        do { self.serialOffset = try Data(contentsOf: self.serialURL).count }
                        catch { self.abort("post-restore serial boundary: \(error)") }
                        self.phase = "resume"
                        self.vm.resume { result in
                            if case .failure(let error) = result { self.abort("resume: \(error as NSError)") }
                            self.checked(nil, "resume", state: .running)
                            self.phase = "after-restore"
                            self.send("clip\n")
                            self.poll()
                        }
                    }
                }
            }
        }
#else
        abort("arm64 required")
#endif
    }
}
