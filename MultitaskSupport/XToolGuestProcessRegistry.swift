import Foundation

/// Main-actor registry for deterministic guest lifecycle operations. Weak controller
/// references keep the registry from retaining a disconnected scene.
@available(iOS 16.1, *)
@MainActor
final class XToolGuestProcessRegistry: NSObject {
    @objc static let shared = XToolGuestProcessRegistry()

    private final class Entry {
        weak var controller: AppSceneViewController?
        let dataUUID: String
        let bundlePath: String
        var initializedPID: Int32?
        var initializationError: Error?
        var didExit = false

        init(controller: AppSceneViewController, dataUUID: String, bundlePath: String) {
            self.controller = controller
            self.dataUUID = dataUUID
            self.bundlePath = bundlePath
        }
    }

    private var entries: [String: Entry] = [:]

    func isRegistered(dataUUID: String) -> Bool {
        entries[dataUUID] != nil
    }

    @objc(registerWithController:dataUUID:bundlePath:)
    func register(controller: AppSceneViewController, dataUUID: String, bundlePath: String) {
        if let entry = entries[dataUUID] {
            if entry.controller !== controller {
                entry.initializedPID = nil
                entry.initializationError = nil
                entry.didExit = false
                entry.controller = controller
            }
            return
        }
        entries[dataUUID] = Entry(controller: controller, dataUUID: dataUUID, bundlePath: bundlePath)
    }

    func unregister(dataUUID: String) {
        entries.removeValue(forKey: dataUUID)
    }

    @objc(didInitializeWithDataUUID:pid:error:)
    func didInitialize(dataUUID: String, pid: Int32, error: Error?) {
        guard let entry = entries[dataUUID] else { return }
        entry.initializedPID = error == nil ? pid : nil
        entry.initializationError = error
    }

    @objc(didExitWithDataUUID:)
    func didExit(dataUUID: String) {
        guard let entry = entries[dataUUID] else { return }
        entry.didExit = true
        entry.initializedPID = nil
    }

    func waitForInitialization(dataUUID: String, timeoutNanoseconds: UInt64 = 10_000_000_000) async throws -> Int32 {
        let start = DispatchTime.now().uptimeNanoseconds
        while true {
            try Task.checkCancellation()
            if let entry = entries[dataUUID] {
                if let error = entry.initializationError { throw error }
                if entry.didExit { throw XToolDeploymentError.processNotRegistered }
                if let pid = entry.initializedPID { return pid }
            }
            if DispatchTime.now().uptimeNanoseconds - start >= timeoutNanoseconds {
                throw XToolDeploymentError.launchTimeout
            }
            // Scene creation and registration can complete after the launch request.
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    func terminateAndDestroy(dataUUID: String, timeoutNanoseconds: UInt64 = 5_000_000_000) async throws {
        guard let entry = entries[dataUUID] else {
            throw XToolDeploymentError.processNotRegistered
        }
        XToolDevRestartGate.begin(dataUUID: dataUUID)
        defer { XToolDevRestartGate.end(dataUUID: dataUUID) }
        if entry.didExit {
            try await waitForContainerRelease(dataUUID: dataUUID, timeoutNanoseconds: timeoutNanoseconds)
            MultitaskWindowManager.removeAppWindow(dataUUID: dataUUID)
            entries.removeValue(forKey: dataUUID)
            return
        }
        guard let controller = entry.controller else {
            throw XToolDeploymentError.processNotRegistered
        }
        controller.terminate()
        let start = DispatchTime.now().uptimeNanoseconds
        while !entry.didExit {
            if DispatchTime.now().uptimeNanoseconds - start >= timeoutNanoseconds {
                throw XToolDeploymentError.terminateTimeout
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try await waitForContainerRelease(dataUUID: dataUUID, timeoutNanoseconds: timeoutNanoseconds)
        MultitaskWindowManager.removeAppWindow(dataUUID: dataUUID)
        entries.removeValue(forKey: dataUUID)
    }

    private func waitForContainerRelease(dataUUID: String, timeoutNanoseconds: UInt64) async throws {
        let start = DispatchTime.now().uptimeNanoseconds
        while MultitaskManager.isUsing(container: dataUUID) {
            if DispatchTime.now().uptimeNanoseconds - start >= timeoutNanoseconds {
                throw XToolDeploymentError.windowCleanupFailed
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}

/// This gate is intentionally lock-based because relaunch callbacks can originate on
/// UIKit or a detached task. It has no references to UI objects.
final class XToolDevRestartGate: NSObject {
    private nonisolated(unsafe) static var suppressed: [String: Int] = [:]
    private static let lock = NSLock()

    static func begin(dataUUID: String) {
        lock.lock(); defer { lock.unlock() }
        suppressed[dataUUID, default: 0] += 1
    }

    static func end(dataUUID: String) {
        lock.lock(); defer { lock.unlock() }
        guard let count = suppressed[dataUUID] else { return }
        if count <= 1 { suppressed.removeValue(forKey: dataUUID) }
        else { suppressed[dataUUID] = count - 1 }
    }

    @objc(isSuppressedWithDataUUID:)
    static func isSuppressed(dataUUID: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return suppressed[dataUUID] != nil
    }
}
