import Foundation
import SwiftUI
import Combine

@MainActor
final class XToolDevViewModel: ObservableObject {
    let server: XToolDevServer
    @Published var tokenVisible = false
    @Published var copiedMessage: String?
    private var serverObservation: AnyCancellable?

    init(server: XToolDevServer? = nil) {
        let server = server ?? XToolDevServer()
        self.server = server
        serverObservation = server.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
    }

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
