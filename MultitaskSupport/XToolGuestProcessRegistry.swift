import Foundation

/// Main-actor registry for deterministic guest lifecycle operations. Weak controller
/// references keep the registry from retaining a disconnected scene.
@available(iOS 16.1, *)
@MainActor
final class XToolGuestProcessRegistry {
    static let shared = XToolGuestProcessRegistry()

    private final class Entry {
        weak var controller: AppSceneViewController?
        let dataUUID: String
        let bundlePath: String
        var initializedPID: Int32?
        var initializationError: Error?
        var didExit = false
        var initializationWaiters: [CheckedContinuation<Int32, Error>] = []
        var exitWaiters: [CheckedContinuation<Void, Error>] = []

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
        guard let entry = entries.removeValue(forKey: dataUUID) else { return }
        entry.initializationWaiters.forEach { $0.resume(throwing: XToolDeploymentError.processNotRegistered) }
        entry.exitWaiters.forEach { $0.resume(throwing: XToolDeploymentError.processNotRegistered) }
    }

    func didInitialize(dataUUID: String, pid: Int32, error: Error?) {
        guard let entry = entries[dataUUID] else { return }
        entry.initializedPID = error == nil ? pid : nil
        entry.initializationError = error
        let waiters = entry.initializationWaiters
        entry.initializationWaiters.removeAll()
        if let error {
            waiters.forEach { $0.resume(throwing: error) }
        } else {
            waiters.forEach { $0.resume(returning: pid) }
        }
    }

    func didExit(dataUUID: String) {
        guard let entry = entries[dataUUID] else { return }
        entry.didExit = true
        entry.initializedPID = nil
        let waiters = entry.exitWaiters
        entry.exitWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func waitForInitialization(dataUUID: String, timeoutNanoseconds: UInt64 = 10_000_000_000) async throws -> Int32 {
        guard let entry = entries[dataUUID] else { throw XToolDeploymentError.processNotRegistered }
        if entry.didExit { throw XToolDeploymentError.processNotRegistered }
        if let error = entry.initializationError { throw error }
        if let pid = entry.initializedPID { return pid }
        return try await withThrowingTaskGroup(of: Int32.self) { group in
            group.addTask { [weak self] in
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
                    Task { @MainActor in
                        guard let entry = self?.entries[dataUUID] else {
                            continuation.resume(throwing: XToolDeploymentError.processNotRegistered)
                            return
                        }
                        if let error = entry.initializationError {
                            continuation.resume(throwing: error)
                            return
                        }
                        if entry.didExit {
                            continuation.resume(throwing: XToolDeploymentError.processNotRegistered)
                            return
                        }
                        if let pid = entry.initializedPID {
                            continuation.resume(returning: pid)
                            return
                        }
                        entry.initializationWaiters.append(continuation)
                    }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                throw XToolDeploymentError.launchTimeout
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
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
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    Task { @MainActor in
                        guard let entry = self?.entries[dataUUID] else {
                            continuation.resume(throwing: XToolDeploymentError.processNotRegistered)
                            return
                        }
                        if entry.didExit {
                            continuation.resume()
                            return
                        }
                        entry.exitWaiters.append(continuation)
                    }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                throw XToolDeploymentError.terminateTimeout
            }
            _ = try await group.next()!
            group.cancelAll()
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
final class XToolDevRestartGate {
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

    static func isSuppressed(dataUUID: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return suppressed[dataUUID] != nil
    }
}
