import Foundation
import Network
import Combine

enum XToolServerState: String {
    case stopped = "Stopped"
    case listening = "Listening"
    case connected = "Connected"
    case deploying = "Deploying"
    case error = "Error"
}

@MainActor
final class XToolDevServer: ObservableObject {
    static let shared = XToolDevServer()

    @Published private(set) var state: XToolServerState = .stopped
    @Published private(set) var lastError: String?
    @Published private(set) var connectedClient: String?
    @Published private(set) var currentRequestId: UUID?
    @Published private(set) var currentPhase: XToolDeploymentPhase?
    @Published private(set) var currentProgress: Double?
    @Published private(set) var recoveryRequired = false
    @Published private(set) var managedBundleIdentifier: String?
    @Published private(set) var managedAppName: String?
    @Published private(set) var currentBuildId: UUID?
    @Published private(set) var lastSuccessfulDeployment: Date?

    let port: UInt16
    private let queue = DispatchQueue(label: "org.xtool.XToolRunner.dev-server")
    private let deploymentService: XToolDeploymentService
    private var listener: NWListener?
    private var activeConnection: XToolDevConnection?
    private var stopRequested = false

    init(port: UInt16 = XToolProtocol.defaultPort, deploymentService: XToolDeploymentService? = nil) {
        self.port = port
        let deploymentService = deploymentService ?? .shared
        self.deploymentService = deploymentService
        self.recoveryRequired = deploymentService.recoveryRequired
    }

    func start() throws {
        guard listener == nil else { return }
        stopRequested = false
        let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    self.state = .listening
                    self.lastError = nil
                case .failed(let error):
                    self.state = .error
                    self.lastError = error.localizedDescription
                    self.listener?.cancel()
                    self.listener = nil
                default: break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor [weak self] in
                self?.accept(connection)
            }
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        if state == .deploying {
            stopRequested = true
            return
        }
        activeConnection?.cancel()
        activeConnection = nil
        stopRequested = false
        state = .stopped
        connectedClient = nil
        currentRequestId = nil
        currentPhase = nil
        currentProgress = nil
    }

    func retryRecovery() {
        deploymentService.recoverUnfinishedTransactions()
        recoveryRequired = deploymentService.recoveryRequired
    }

    func report(error: Error) {
        state = .error
        lastError = error.localizedDescription
    }

    func relaunchManagedApp() async {
        guard let bundleIdentifier = managedBundleIdentifier else {
            report(error: XToolDeploymentError.managedAppMissing)
            return
        }
        do {
            let pid = try await deploymentService.relaunchManagedApp(bundleIdentifier: bundleIdentifier)
            currentPhase = .completed
            currentProgress = 1
            lastError = nil
            print("XTool Runner relaunched \(bundleIdentifier) (pid \(pid))")
        } catch {
            report(error: error)
        }
    }

    private func accept(_ nwConnection: NWConnection) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.activeConnection == nil else {
                nwConnection.cancel()
                return
            }
            let temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("xtool-runner-\(UUID().uuidString)", isDirectory: true)
            let connection = XToolDevConnection(
                connection: nwConnection,
                temporaryDirectory: temporaryDirectory,
                onClient: { [weak self] name in
                    Task { @MainActor in
                        self?.connectedClient = name
                        self?.state = .connected
                    }
                },
                onProgress: { [weak self] metadata in
                    Task { @MainActor in
                        self?.currentRequestId = metadata.requestId
                        self?.currentPhase = metadata.phase
                        self?.currentProgress = metadata.fraction
                        self?.state = .deploying
                    }
                },
                onDeployment: { [weak self] connection, frame, received in
                    Task { @MainActor in
                        await self?.handleDeployment(connection: connection, frame: frame, received: received)
                    }
                },
                onError: { [weak self] message in
                    Task { @MainActor in
                        self?.lastError = message
                    }
                },
                onClosed: { [weak self] connection in
                    Task { @MainActor in
                        guard self?.activeConnection === connection else { return }
                        self?.activeConnection = nil
                        self?.connectedClient = nil
                        if self?.listener != nil { self?.state = .listening }
                    }
                }
            )
            self.activeConnection = connection
            connection.start()
        }
    }

    private func handleDeployment(connection: XToolDevConnection, frame: XToolFrame, received: XToolFrameReceiver.ReceivedFrame) async {
        defer {
            connection.finishDeployment()
            if stopRequested {
                stopRequested = false
                activeConnection?.cancel()
                activeConnection = nil
                state = .stopped
            }
        }
        guard let payloadURL = received.payloadURL, let payloadSHA256 = received.payloadSHA256 else {
            connection.sendError(code: "invalid_archive", message: "DEPLOY payload was empty", requestId: nil, rolledBack: false)
            return
        }
        do {
            let metadata = try frame.decodedMetadata(XToolDeployMetadata.self)
            currentRequestId = metadata.requestId
            currentPhase = .receiving
            state = .deploying
            let outcome = try await deploymentService.deploy(ipaURL: payloadURL, payloadSHA256: payloadSHA256, metadata: metadata) { [weak self] phase, fraction, message in
                self?.currentPhase = phase
                self?.currentProgress = fraction
                connection.sendProgress(requestId: metadata.requestId, phase: phase, fraction: fraction, message: message)
            }
            managedBundleIdentifier = metadata.bundleIdentifier
            managedAppName = metadata.displayName
            currentBuildId = metadata.buildId
            lastSuccessfulDeployment = Date()
            lastError = nil
            connection.sendResult(requestId: metadata.requestId, metadata: XToolResultMetadata(requestId: metadata.requestId, success: outcome.success, bundleIdentifier: metadata.bundleIdentifier, buildId: metadata.buildId, dataUUID: outcome.dataUUID, pid: outcome.pid, rolledBack: outcome.rolledBack, message: outcome.message))
            try? FileManager.default.removeItem(at: payloadURL)
            state = listener == nil ? .stopped : (activeConnection === connection ? .connected : .listening)
        } catch let failure as XToolDeploymentFailure {
            lastError = failure.error.localizedDescription
            recoveryRequired = deploymentService.recoveryRequired
            let code = (failure.error as? XToolDeploymentError)?.code ?? (failure.rolledBack ? "deployment_failed" : "rollback_failed")
            connection.sendError(code: code, message: failure.error.localizedDescription, requestId: (try? frame.decodedMetadata(XToolDeployMetadata.self).requestId), rolledBack: failure.rolledBack)
            try? FileManager.default.removeItem(at: payloadURL)
            state = listener == nil ? .stopped : (activeConnection === connection ? .connected : .listening)
        } catch is DecodingError {
            lastError = "DEPLOY metadata is invalid"
            connection.sendError(code: "invalid_frame", message: "DEPLOY metadata is invalid", requestId: nil, rolledBack: false)
            try? FileManager.default.removeItem(at: payloadURL)
            state = listener == nil ? .stopped : (activeConnection === connection ? .connected : .listening)
        } catch let error as XToolDeploymentError {
            lastError = error.localizedDescription
            recoveryRequired = deploymentService.recoveryRequired
            connection.sendError(code: error.code, message: error.localizedDescription, requestId: (try? frame.decodedMetadata(XToolDeployMetadata.self).requestId), rolledBack: false)
            try? FileManager.default.removeItem(at: payloadURL)
            state = listener == nil ? .stopped : (activeConnection === connection ? .connected : .listening)
        } catch {
            lastError = error.localizedDescription
            recoveryRequired = deploymentService.recoveryRequired
            connection.sendError(code: "internal_error", message: error.localizedDescription, requestId: (try? frame.decodedMetadata(XToolDeployMetadata.self).requestId), rolledBack: false)
            try? FileManager.default.removeItem(at: payloadURL)
            state = listener == nil ? .stopped : (activeConnection === connection ? .connected : .listening)
        }
    }
}

private final class XToolDevConnection {
    private enum HandshakeState { case waitingForHello, ready }

    let connection: NWConnection
    private let queue = DispatchQueue(label: "org.xtool.XToolRunner.dev-connection")
    private let temporaryDirectory: URL
    private let onClient: (String) -> Void
    private let onProgress: (XToolProgressMetadata) -> Void
    private let onDeployment: (XToolDevConnection, XToolFrame, XToolFrameReceiver.ReceivedFrame) -> Void
    private let onError: (String) -> Void
    private let onClosed: (XToolDevConnection) -> Void
    private var receiver: XToolFrameReceiver
    private var handshake: HandshakeState = .waitingForHello
    private var isClosed = false
    private var deploymentInProgress = false
    private var lastBuildSequence: UInt64 = 0
    private var requestIDs = Set<UUID>()

    init(connection: NWConnection, temporaryDirectory: URL, onClient: @escaping (String) -> Void, onProgress: @escaping (XToolProgressMetadata) -> Void, onDeployment: @escaping (XToolDevConnection, XToolFrame, XToolFrameReceiver.ReceivedFrame) -> Void, onError: @escaping (String) -> Void, onClosed: @escaping (XToolDevConnection) -> Void) {
        self.connection = connection
        self.temporaryDirectory = temporaryDirectory
        self.onClient = onClient
        self.onProgress = onProgress
        self.onDeployment = onDeployment
        self.onError = onError
        self.onClosed = onClosed
        self.receiver = XToolFrameReceiver(temporaryDirectory: temporaryDirectory)
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .failed(let error) = state {
                self.onError("Connection failed: \(error.localizedDescription)")
                self.close()
            }
            if case .cancelled = state { self.close() }
        }
        connection.start(queue: queue)
        receiveNext()
    }

    func cancel() { connection.cancel() }

    func sendProgress(requestId: UUID, phase: XToolDeploymentPhase, fraction: Double?, message: String) {
        let metadata = XToolProgressMetadata(requestId: requestId, phase: phase, fraction: fraction, message: message)
        send(kind: .progress, metadata: metadata)
        onProgress(metadata)
    }

    func sendResult(requestId: UUID, metadata: XToolResultMetadata) {
        send(kind: .result, metadata: metadata)
    }

    func sendError(code: String, message: String, requestId: UUID?, rolledBack: Bool, closeAfterSend: Bool = false) {
        send(kind: .error, metadata: XToolErrorMetadata(requestId: requestId, code: code, message: message, recoverable: true, rolledBack: rolledBack), allowWhenClosed: closeAfterSend, closeAfterSend: closeAfterSend)
    }

    func finishDeployment() {
        queue.async {
            self.deploymentInProgress = false
            self.receiver.cleanup()
            try? FileManager.default.removeItem(at: self.temporaryDirectory)
        }
    }

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                do {
                    for received in try self.receiver.append(data) { self.handle(received) }
                } catch let frameError {
                    self.onError("Protocol error: \(frameError.localizedDescription)")
                    self.sendError(code: protocolErrorCode(frameError), message: frameError.localizedDescription, requestId: nil, rolledBack: false, closeAfterSend: true)
                    return
                }
            }
            if let error {
                self.onError("Receive failed: \(error.localizedDescription)")
                self.close()
            } else if isComplete {
                self.close()
            }
            else { self.receiveNext() }
        }
    }

    private func handle(_ received: XToolFrameReceiver.ReceivedFrame) {
        let frame = received.frame
        switch handshake {
        case .waitingForHello:
            guard frame.kind == .hello else { sendError(code: "invalid_frame", message: "HELLO required", requestId: nil, rolledBack: false, closeAfterSend: true); return }
            do {
                let hello = try frame.decodedMetadata(XToolHello.self)
                handshake = .ready
                onClient(hello.clientName + "/" + hello.clientVersion)
                send(kind: .ready, metadata: XToolReady(sessionId: UUID(), capabilities: ["deploy", "fast-restart"], protocolVersion: XToolProtocol.version))
            } catch {
                sendError(code: "invalid_frame", message: error.localizedDescription, requestId: nil, rolledBack: false, closeAfterSend: true)
            }
        case .ready:
            switch frame.kind {
            case .deploy:
                guard !deploymentInProgress else { sendError(code: "server_busy", message: "Another deployment is active", requestId: nil, rolledBack: false); return }
                guard let metadata = try? frame.decodedMetadata(XToolDeployMetadata.self) else {
                    sendError(code: "invalid_frame", message: "DEPLOY metadata is invalid", requestId: nil, rolledBack: false)
                    return
                }
                guard metadata.buildSequence > lastBuildSequence, requestIDs.insert(metadata.requestId).inserted else {
                    sendError(code: "sequence_replayed", message: "DEPLOY request or build sequence was replayed", requestId: metadata.requestId, rolledBack: false)
                    return
                }
                lastBuildSequence = metadata.buildSequence
                deploymentInProgress = true
                onDeployment(self, frame, received)
            case .ping:
                send(kind: .pong, metadata: EmptyMetadata())
            default:
                break
            }
        }
    }

    private func send<T: Encodable>(kind: XToolMessageKind, metadata: T, allowWhenClosed: Bool = false, closeAfterSend: Bool = false) {
        queue.async { [weak self] in
            guard let self, !self.isClosed || allowWhenClosed else { return }
            do {
                let frame = try XToolFrame(kind: kind, metadata: metadata)
                let bytes = try XToolFrameCodec.encode(frame)
                self.connection.send(content: bytes, completion: .contentProcessed { [weak self] error in
                    if let error {
                        self?.onError("Send failed: \(error.localizedDescription)")
                    }
                    if closeAfterSend { self?.close() }
                })
            } catch {
                self.onError("Send failed: \(error.localizedDescription)")
                self.close()
            }
        }
    }

    private func close() {
        guard !isClosed else { return }
        isClosed = true
        connection.cancel()
        if !deploymentInProgress {
            receiver.cleanup()
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        onClosed(self)
    }
}

private struct EmptyMetadata: Encodable {}

private func protocolErrorCode(_ error: Error) -> String {
    guard let error = error as? XToolProtocolError else { return "internal_error" }
    switch error {
    case .invalidMagic, .invalidFrame: return "invalid_frame"
    case .unsupportedVersion: return "unsupported_protocol"
    case .metadataTooLarge: return "metadata_too_large"
    case .payloadTooLarge: return "payload_too_large"
    case .checksumMismatch: return "checksum_mismatch"
    }
}
