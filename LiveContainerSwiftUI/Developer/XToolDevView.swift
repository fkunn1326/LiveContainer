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
                valueRow("Server", model.server.state.rawValue)
                valueRow("Address", "\(localAddress()):\(model.server.port)")
                Button("Copy Address") {
                    model.copy("\(localAddress()):\(model.server.port)", message: "Address copied")
                }
                if let client = model.server.connectedClient {
                    valueRow("Client", client)
                }
                if let name = model.server.managedAppName,
                   let bundleIdentifier = model.server.managedBundleIdentifier {
                    valueRow("Managed App", "\(name) (\(bundleIdentifier))")
                }
                if let buildId = model.server.currentBuildId {
                    valueRow("Build", buildId.uuidString)
                }
                if let lastSuccess = model.server.lastSuccessfulDeployment {
                    valueRow("Last Success", lastSuccess.formatted(date: .abbreviated, time: .standard))
                }
                if let requestId = model.server.currentRequestId {
                    valueRow("Request", requestId.uuidString)
                }
                if let phase = model.server.currentPhase {
                    valueRow("Phase", phase.rawValue)
                }
                if let progress = model.server.currentProgress {
                    ProgressView(value: progress)
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

    private func valueRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }

    private func localAddress() -> String {
        var candidates: [(priority: Int, address: String)] = []
        var address: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&address) == 0, let first = address else { return "127.0.0.1" }
        defer { freeifaddrs(address) }
        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let item = current {
            let flags = Int32(item.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, let sa = item.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else {
                current = item.pointee.ifa_next
                continue
            }
            let interface = String(cString: item.pointee.ifa_name)
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            let priority: Int
            if interface == "en0" {
                priority = 0
            } else if interface.hasPrefix("en") {
                priority = 1
            } else if interface.hasPrefix("bridge") {
                priority = 2
            } else if interface.hasPrefix("pdp_ip") {
                priority = 3
            } else if interface.hasPrefix("utun") {
                priority = 4
            } else {
                priority = 5
            }
            candidates.append((priority, String(cString: host)))
            current = item.pointee.ifa_next
        }
        return candidates.min { $0.priority < $1.priority }?.address ?? "127.0.0.1"
    }
}
