import SwiftUI
import Network
#if canImport(Darwin)
import Darwin
#endif

struct XToolDevView: View {
    @StateObject private var model = XToolDevViewModel()

    var body: some View {
        Form {
            Section("XTool Runner") {
                LabeledContent("Server", value: model.server.state.rawValue)
                LabeledContent("Address", value: "\(localAddress()):\(model.server.port)")
                Button("Copy Address") {
                    model.copy("\(localAddress()):\(model.server.port)", message: "Address copied")
                }
                if let client = model.server.connectedClient {
                    LabeledContent("Client", value: client)
                }
                if let name = model.server.managedAppName,
                   let bundleIdentifier = model.server.managedBundleIdentifier {
                    LabeledContent("Managed App", value: "\(name) (\(bundleIdentifier))")
                }
                if let buildId = model.server.currentBuildId {
                    LabeledContent("Build", value: buildId.uuidString)
                }
                if let lastSuccess = model.server.lastSuccessfulDeployment {
                    LabeledContent("Last Success", value: lastSuccess.formatted(date: .abbreviated, time: .standard))
                }
                if let requestId = model.server.currentRequestId {
                    LabeledContent("Request", value: requestId.uuidString)
                }
                if let phase = model.server.currentPhase {
                    LabeledContent("Phase", value: phase.rawValue)
                }
                if let progress = model.server.currentProgress {
                    ProgressView(value: progress)
                }
            }

            Section("Pairing") {
                HStack {
                    Text(model.tokenVisible ? model.token : maskedToken(model.token))
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                    Spacer()
                    Button(model.tokenVisible ? "Hide" : "Show") { model.tokenVisible.toggle() }
                    Button("Copy") { model.copy(model.token, message: "Token copied") }
                }
                Button("Regenerate Token", role: .destructive) {
                    model.regenerateToken()
                }
            }

            Section {
                Button(model.server.state == .stopped ? "Start Server" : "Stop Server") {
                    if model.server.state == .stopped { model.start() } else { model.server.stop() }
                }
                if model.server.recoveryRequired {
                    Text("Recovery is required before a deployment can start.")
                        .foregroundStyle(.red)
                    Button("Retry Recovery") { model.server.retryRecovery() }
                }
                Button("Relaunch Managed App") { model.relaunchManagedApp() }
                    .disabled(model.server.managedBundleIdentifier == nil)
            }

            if let error = model.server.lastError {
                Section("Last Error") {
                    Text(error).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                    Button("Copy Error") { model.copy(error, message: "Error copied") }
                }
            }
            if let copied = model.copiedMessage { Text(copied).foregroundStyle(.secondary) }
        }
        .navigationTitle("Developer")
    }

    private func maskedToken(_ token: String) -> String {
        guard token.count > 8 else { return "••••••••" }
        return String(token.prefix(4)) + "••••••••" + String(token.suffix(4))
    }

    private func localAddress() -> String {
        var result = "127.0.0.1"
        var address: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&address) == 0, let first = address else { return result }
        defer { freeifaddrs(address) }
        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let item = current {
            let flags = Int32(item.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, let sa = item.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else {
                current = item.pointee.ifa_next
                continue
            }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            result = String(cString: host)
            break
        }
        return result
    }
}
