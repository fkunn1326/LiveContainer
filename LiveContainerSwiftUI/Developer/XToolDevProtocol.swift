import Foundation
import CryptoKit

enum XToolProtocol {
    static let version: UInt16 = 1
    static let magic = Data("XTLR".utf8)
    static let fixedHeaderLength = 28
    static let authenticationCodeLength = 32
    static let defaultPort: UInt16 = 24_642
    static let maximumMetadataLength = 64 * 1024
    static let maximumPayloadLength: UInt64 = 512 * 1024 * 1024
    static let maximumExpandedLength: UInt64 = 1_500 * 1024 * 1024
    static let maximumFileCount: UInt64 = 100_000
}

enum XToolMessageKind: UInt8 {
    case hello = 0x01
    case challenge = 0x02
    case authenticate = 0x03
    case ready = 0x04
    case deploy = 0x10
    case ping = 0x11
    case progress = 0x80
    case result = 0x81
    case error = 0x82
    case pong = 0x83
}

struct XToolFrame {
    let kind: XToolMessageKind
    let flags: UInt8
    let sequence: UInt64
    let metadata: Data
    let payload: Data

    var isAuthenticated: Bool { flags & 1 == 1 }

    init(kind: XToolMessageKind, flags: UInt8 = 0, sequence: UInt64 = 0, metadata: Data = Data(), payload: Data = Data()) {
        self.kind = kind
        self.flags = flags
        self.sequence = sequence
        self.metadata = metadata
        self.payload = payload
    }

    init<T: Encodable>(kind: XToolMessageKind, flags: UInt8 = 0, sequence: UInt64 = 0, metadata: T, payload: Data = Data()) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        self.init(kind: kind, flags: flags, sequence: sequence, metadata: try encoder.encode(metadata), payload: payload)
    }

    func decodedMetadata<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: metadata)
    }
}

struct XToolHello: Codable {
    let clientName: String
    let clientVersion: String
    let clientNonce: String
}

struct XToolChallenge: Codable {
    let runnerName: String
    let runnerVersion: String
    let serverNonce: String
    let maxPayloadBytes: UInt64
}

struct XToolAuthenticate: Codable {
    let proof: String
}

struct XToolReady: Codable {
    let sessionId: UUID
    let capabilities: [String]
    let protocolVersion: UInt16
}

struct XToolDeployMetadata: Codable {
    let requestId: UUID
    let buildId: UUID
    let buildSequence: UInt64
    let bundleIdentifier: String
    let displayName: String
    let configuration: String
    let archiveFormat: String
    let payloadSHA256: String
    let launchAfterInstall: Bool
    let preserveDataContainer: Bool
}

enum XToolDeploymentPhase: String, Codable {
    case receiving
    case verifying
    case extracting
    case preparing
    case signing
    case terminating
    case swapping
    case launching
    case committing
    case rollingBack = "rolling-back"
    case completed
}

struct XToolProgressMetadata: Codable {
    let requestId: UUID
    let phase: XToolDeploymentPhase
    let fraction: Double?
    let message: String
}

struct XToolResultMetadata: Codable {
    let requestId: UUID
    let success: Bool
    let bundleIdentifier: String
    let buildId: UUID
    let dataUUID: String?
    let pid: Int32?
    let rolledBack: Bool
    let message: String
}

struct XToolErrorMetadata: Codable {
    let requestId: UUID?
    let code: String
    let message: String
    let recoverable: Bool
    let rolledBack: Bool
}

enum XToolProtocolError: Error, LocalizedError {
    case invalidMagic
    case unsupportedVersion
    case invalidFrame(String)
    case metadataTooLarge
    case payloadTooLarge
    case unauthorized
    case sequenceReplayed
    case checksumMismatch
    case unsafeArchiveEntry

    var errorDescription: String? {
        switch self {
        case .invalidMagic: "Invalid XTLR frame magic"
        case .unsupportedVersion: "Unsupported XTLR protocol version"
        case .invalidFrame(let message): "Invalid XTLR frame: \(message)"
        case .metadataTooLarge: "Metadata exceeds 64 KiB"
        case .payloadTooLarge: "Payload exceeds 512 MiB"
        case .unauthorized: "Runner authentication failed"
        case .sequenceReplayed: "Frame sequence number was replayed"
        case .checksumMismatch: "Payload checksum mismatch"
        case .unsafeArchiveEntry: "Archive contains an unsafe path"
        }
    }
}

enum XToolCrypto {
    static func randomBytes(count: Int) -> Data {
        var data = Data(count: count)
        for index in 0..<count { data[index] = UInt8.random(in: .min ... .max) }
        return data
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func decodeBase64URL(_ value: String) -> Data? {
        var value = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        value += String(repeating: "=", count: (4 - value.count % 4) % 4)
        return Data(base64Encoded: value)
    }

    static func hmac(key: Data, data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    static func sessionKey(token: Data, clientNonce: Data, serverNonce: Data) -> Data {
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: token),
            salt: clientNonce + serverNonce,
            info: Data("XTLR-SESSION-V1".utf8),
            outputByteCount: 32
        )
        return key.withUnsafeBytes { Data($0) }
    }

    static func proof(token: Data, clientNonce: Data, serverNonce: Data) -> Data {
        hmac(key: token, data: Data("XTLR-AUTH-V1".utf8) + clientNonce + serverNonce)
    }

    static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var result: UInt8 = 0
        for (a, b) in zip(lhs, rhs) { result |= a ^ b }
        return result == 0
    }
}

private extension Data {
    static func + (lhs: Data, rhs: Data) -> Data {
        var value = lhs
        value.append(rhs)
        return value
    }

    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        var value = value.bigEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }

    func readBigEndian<T: FixedWidthInteger>(_ type: T.Type, offset: Int) -> T {
        var value: T = 0
        for byte in self[offset..<(offset + MemoryLayout<T>.size)] { value = (value << 8) | T(byte) }
        return value
    }
}
