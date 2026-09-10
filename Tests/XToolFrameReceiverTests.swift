// Standalone regression test (macOS):
// swiftc LiveContainerSwiftUI/Developer/XToolDevProtocol.swift \
//   LiveContainerSwiftUI/Developer/XToolFrameParser.swift \
//   Tests/XToolFrameReceiverTests.swift -o /tmp/xtool-frame-tests
// /tmp/xtool-frame-tests
import Foundation

@main
enum XToolFrameReceiverTests {
    static func main() throws {
        let payload = Data(repeating: 0x61, count: 200_000)
        let hello = try XToolFrame(kind: .hello, metadata: XToolHello(clientName: "test", clientVersion: "test"))
        let deploy = try XToolFrame(kind: .deploy, sequence: 1, metadata: XToolDeployMetadata(
            requestId: UUID(), buildId: UUID(), buildSequence: 1,
            bundleIdentifier: "test.app", displayName: "Test", configuration: "debug",
            archiveFormat: "ipa", payloadSHA256: "test", launchAfterInstall: true,
            preserveDataContainer: true
        ), payload: payload)
        let ping = XToolFrame(kind: .ping, metadata: Data("{}".utf8))
        let helloBytes = try XToolFrameCodec.encode(hello)
        let prefix = try XToolFrameCodec.prefix(for: deploy, payloadLength: UInt64(payload.count))
        let pingBytes = try XToolFrameCodec.encode(ping)
        var bytes = helloBytes
        bytes.append(prefix)
        bytes.append(payload)
        bytes.append(pingBytes)

        // Coalesced frames retain a nonzero Data.startIndex after consuming HELLO.
        try check(chunks: [bytes], payload: payload)
        // Header-only delivery must return instead of spinning on an empty buffer.
        try check(chunks: [helloBytes, prefix, Data(), payload, pingBytes], payload: payload)
        // Split headers, metadata and payload across arbitrary TCP reads.
        for size in [1, 28, 4096, 65536] {
            let chunks = stride(from: 0, to: bytes.count, by: size).map {
                Data(bytes[$0..<min($0 + size, bytes.count)])
            }
            try check(chunks: chunks, payload: payload)
        }
        print("PASS: receiver handles coalesced frames, empty reads and fragmented IPA uploads")
    }

    private static func check(chunks: [Data], payload: Data) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let receiver = XToolFrameReceiver(temporaryDirectory: directory)
        defer {
            receiver.cleanup()
            try? FileManager.default.removeItem(at: directory)
        }
        var frames: [XToolFrameReceiver.ReceivedFrame] = []
        for chunk in chunks { frames.append(contentsOf: try receiver.append(chunk)) }
        precondition(frames.map { $0.frame.kind } == [.hello, .deploy, .ping])
        let uploaded = try Data(contentsOf: frames[1].payloadURL!)
        precondition(uploaded == payload)
        precondition(frames[1].payloadSHA256 == "2287d207f24a941ff3b56c04c8a25ad56b63e3023207b3bb5b4ac0c9869d74be")
    }
}
