import Foundation
import SwiftUI

@MainActor
final class XToolDevViewModel: ObservableObject {
    let server: XToolDevServer
    @Published var tokenVisible = false
    @Published var copiedMessage: String?

    init(server: XToolDevServer? = nil) { self.server = server ?? XToolDevServer() }

    var token: String { server.pairingToken ?? "Unavailable" }

    func copy(_ value: String, message: String) {
        UIPasteboard.general.string = value
        copiedMessage = message
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            copiedMessage = nil
        }
    }

    func start() {
        do { try server.start() }
        catch { server.report(error: error) }
    }

    func regenerateToken() {
        do {
            _ = try server.regenerateToken()
            tokenVisible = false
        } catch {
            server.report(error: error)
        }
    }

    func relaunchManagedApp() {
        Task { await server.relaunchManagedApp() }
    }
}
