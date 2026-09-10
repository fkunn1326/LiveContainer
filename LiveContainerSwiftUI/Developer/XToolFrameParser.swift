import Foundation
import CryptoKit

enum XToolFrameCodec {
    static func prefix(for frame: XToolFrame, payloadLength: UInt64, sessionKey: Data? = nil) throws -> Data {
        guard frame.metadata.count <= XToolProtocol.maximumMetadataLength else { throw XToolProtocolError.metadataTooLarge }
        guard payloadLength <= XToolProtocol.maximumPayloadLength else { throw XToolProtocolError.payloadTooLarge }
        guard payloadLength == 0 || frame.isAuthenticated else { throw XToolProtocolError.unauthorized }
        guard frame.flags & ~UInt8(1) == 0 else { throw XToolProtocolError.invalidFrame("unknown flags") }
        guard (try? JSONSerialization.jsonObject(with: frame.metadata)) != nil else { throw XToolProtocolError.invalidFrame("metadata is not JSON") }
        var header = XToolProtocol.magic
        header.appendBigEndian(XToolProtocol.version)
        header.append(frame.kind.rawValue)
        header.append(frame.flags)
        header.appendBigEndian(frame.sequence)
        header.appendBigEndian(UInt32(frame.metadata.count))
        header.appendBigEndian(payloadLength)
        var result = header
        result.append(frame.metadata)
        if frame.isAuthenticated {
            guard let sessionKey else { throw XToolProtocolError.unauthorized }
            result.append(XToolCrypto.hmac(key: sessionKey, data: header + frame.metadata))
        }
        return result
    }

    static func encode(_ frame: XToolFrame, sessionKey: Data? = nil) throws -> Data {
        var result = try prefix(for: frame, payloadLength: UInt64(frame.payload.count), sessionKey: sessionKey)
        result.append(frame.payload)
        return result
    }
}

/// Receives arbitrary Network.framework chunks and writes payload bytes directly to a
/// temporary file. Control frames are retained in memory; deploy payloads never are.
final class XToolFrameReceiver {
    struct ReceivedFrame {
        let frame: XToolFrame
        let payloadURL: URL?
        let payloadSHA256: String?
    }

    private var buffer = Data()
    private var sessionKey: Data?
    private var lastAuthenticatedSequence: UInt64 = 0
    private let temporaryDirectory: URL
    private var payloadHandle: FileHandle?
    private var payloadHasher: SHA256?
    private var currentFrame: XToolFrame?
    private var remainingPayload: UInt64 = 0
    private var payloadURL: URL?

    init(temporaryDirectory: URL) { self.temporaryDirectory = temporaryDirectory }

    func setSessionKey(_ key: Data?) {
        sessionKey = key
        lastAuthenticatedSequence = 0
    }

    func append(_ data: Data) throws -> [ReceivedFrame] {
        buffer.append(data)
        var result: [ReceivedFrame] = []
        while true {
            if currentFrame == nil {
                guard buffer.count >= XToolProtocol.fixedHeaderLength else { break }
                try beginFrame()
            }
            guard let frame = currentFrame else { break }
            if remainingPayload > 0 {
                let count = min(UInt64(buffer.count), remainingPayload)
                let chunk = Data(buffer.prefix(Int(count)))
                buffer.removeFirst(Int(count))
                try payloadHandle?.write(contentsOf: chunk)
                payloadHasher?.update(data: chunk)
                remainingPayload -= count
                if remainingPayload > 0 { continue }
            }
            try payloadHandle?.close()
            payloadHandle = nil
            let digest: String?
            if var hasher = payloadHasher {
                digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            } else {
                digest = nil
            }
            result.append(ReceivedFrame(frame: frame, payloadURL: payloadURL, payloadSHA256: digest))
            currentFrame = nil
            payloadHasher = nil
            payloadURL = nil
        }
        return result
    }

    func cleanup() {
        try? payloadHandle?.close()
        payloadHandle = nil
        if let payloadURL { try? FileManager.default.removeItem(at: payloadURL) }
    }

    private func beginFrame() throws {
        guard buffer.prefix(4) == XToolProtocol.magic else { throw XToolProtocolError.invalidMagic }
        let version = buffer.readBigEndian(UInt16.self, offset: 4)
        guard version == XToolProtocol.version else { throw XToolProtocolError.unsupportedVersion }
        guard let kind = XToolMessageKind(rawValue: buffer[6]) else { throw XToolProtocolError.invalidFrame("unknown message kind") }
        let flags = buffer[7]
        guard flags & ~UInt8(1) == 0 else { throw XToolProtocolError.invalidFrame("unknown flags") }
        let sequence = buffer.readBigEndian(UInt64.self, offset: 8)
        let metadataLength = Int(buffer.readBigEndian(UInt32.self, offset: 16))
        let payloadLength = buffer.readBigEndian(UInt64.self, offset: 20)
        guard metadataLength <= XToolProtocol.maximumMetadataLength else { throw XToolProtocolError.metadataTooLarge }
        guard payloadLength <= XToolProtocol.maximumPayloadLength else { throw XToolProtocolError.payloadTooLarge }
        guard payloadLength == 0 || flags & 1 == 1 else { throw XToolProtocolError.unauthorized }
        guard payloadLength == 0 || kind == .deploy else { throw XToolProtocolError.invalidFrame("only DEPLOY may carry a payload") }
        let authLength = flags & 1 == 1 ? XToolProtocol.authenticationCodeLength : 0
        let prefixLength = XToolProtocol.fixedHeaderLength + metadataLength + authLength
        guard buffer.count >= prefixLength else { return }
        let header = Data(buffer.prefix(XToolProtocol.fixedHeaderLength))
        let metadataStart = XToolProtocol.fixedHeaderLength
        let metadataEnd = metadataStart + metadataLength
        let metadata = Data(buffer[metadataStart..<metadataEnd])
        guard (try? JSONSerialization.jsonObject(with: metadata)) != nil else { throw XToolProtocolError.invalidFrame("metadata is not JSON") }
        if kind == .deploy {
            guard let deploy = try? JSONDecoder().decode(XToolDeployMetadata.self, from: metadata),
                  deploy.archiveFormat == "ipa",
                  deploy.launchAfterInstall,
                  deploy.preserveDataContainer,
                  !deploy.bundleIdentifier.isEmpty else {
                throw XToolProtocolError.invalidFrame("DEPLOY metadata is invalid")
            }
        }
        if flags & 1 == 1 {
            guard let sessionKey else { throw XToolProtocolError.unauthorized }
            let codeStart = metadataEnd
            let codeEnd = codeStart + XToolProtocol.authenticationCodeLength
            let actual = Data(buffer[codeStart..<codeEnd])
            let expected = XToolCrypto.hmac(key: sessionKey, data: header + metadata)
            guard XToolCrypto.constantTimeEqual(actual, expected) else { throw XToolProtocolError.unauthorized }
            guard sequence > lastAuthenticatedSequence else { throw XToolProtocolError.sequenceReplayed }
            lastAuthenticatedSequence = sequence
        }
        buffer.removeFirst(prefixLength)
        let frame = XToolFrame(kind: kind, flags: flags, sequence: sequence, metadata: metadata)
        currentFrame = frame
        remainingPayload = payloadLength
        if payloadLength > 0 {
            let url = temporaryDirectory.appendingPathComponent("payload-\(UUID().uuidString).ipa")
            try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path, contents: nil)
            payloadHandle = try FileHandle(forWritingTo: url)
            payloadHasher = SHA256()
            payloadURL = url
        }
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
        for byte in self[offset..<(offset + MemoryLayout<T>.size)] {
            value = (value << 8) | T(byte)
        }
        return value
    }
}
