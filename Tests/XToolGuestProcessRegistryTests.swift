// Standalone lifecycle tests. Compile with XToolGuestProcessRegistry.swift,
// omitting its @objc annotations on Linux. UI collaborators are stubbed below.
import Foundation

@MainActor
final class AppSceneViewController: NSObject {
    var onTerminate: () -> Void = {}
    func terminate() { onTerminate() }
}

enum XToolDeploymentError: Error {
    case processNotRegistered, launchTimeout, terminateTimeout, windowCleanupFailed
}

@MainActor
enum MultitaskManager {
    static func isUsing(container: String) -> Bool { false }
}

@MainActor
enum MultitaskWindowManager {
    static func removeAppWindow(dataUUID: String) {}
}

@main
enum RegistryTests {
    @MainActor
    static func main() async throws {
        let registry = XToolGuestProcessRegistry()
        let controller = AppSceneViewController()
        let pending = Task { try await registry.waitForInitialization(dataUUID: "delayed") }
        try await Task.sleep(nanoseconds: 10_000_000)
        registry.register(controller: controller, dataUUID: "delayed", bundlePath: "Test.app")
        registry.didInitialize(dataUUID: "delayed", pid: 123, error: nil)
        let pid = try await pending.value
        precondition(pid == 123)

        do {
            _ = try await registry.waitForInitialization(dataUUID: "missing", timeoutNanoseconds: 1_000_000)
            fatalError("Missing guest must time out")
        } catch XToolDeploymentError.launchTimeout {}

        registry.register(controller: controller, dataUUID: "uninitialized", bundlePath: "Test.app")
        do {
            _ = try await registry.waitForInitialization(dataUUID: "uninitialized", timeoutNanoseconds: 1_000_000)
            fatalError("Uninitialized guest must time out")
        } catch XToolDeploymentError.launchTimeout {}

        let cancelled = Task { try await registry.waitForInitialization(dataUUID: "cancelled") }
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            fatalError("Cancelled wait must throw")
        } catch is CancellationError {}

        registry.didInitialize(dataUUID: "uninitialized", pid: 0, error: XToolDeploymentError.windowCleanupFailed)
        do {
            _ = try await registry.waitForInitialization(dataUUID: "uninitialized")
            fatalError("Initialization errors must propagate")
        } catch XToolDeploymentError.windowCleanupFailed {}

        do {
            try await registry.terminateAndDestroy(dataUUID: "delayed", timeoutNanoseconds: 1_000_000)
            fatalError("Termination without exit must time out")
        } catch XToolDeploymentError.terminateTimeout {}
        precondition(!XToolDevRestartGate.isSuppressed(dataUUID: "delayed"))

        controller.onTerminate = { registry.didExit(dataUUID: "delayed") }
        try await registry.terminateAndDestroy(dataUUID: "delayed")
        precondition(!registry.isRegistered(dataUUID: "delayed"))
        precondition(!XToolDevRestartGate.isSuppressed(dataUUID: "delayed"))
        print("PASS: delayed registration, launch/termination timeouts, cancellation, errors and cleanup")
    }
}
