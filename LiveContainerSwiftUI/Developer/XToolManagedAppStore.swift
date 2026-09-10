import Foundation
import CryptoKit

struct XToolManagedAppRecord: Codable {
    var bundleIdentifier: String
    var relativeBundlePath: String
    var dataUUID: String
    var currentBuildId: UUID
    var currentPayloadSHA256: String
    var lastSuccessfulDeployment: Date
}

final class XToolManagedAppStore {
    private let fileManager = FileManager.default
    private let root: URL

    init(root: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("XToolRunner/ManagedApps", isDirectory: true)) {
        self.root = root
    }

    func record(for bundleIdentifier: String) throws -> XToolManagedAppRecord? {
        let url = recordURL(for: bundleIdentifier)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        do {
            let record = try JSONDecoder().decode(XToolManagedAppRecord.self, from: Data(contentsOf: url))
            guard record.bundleIdentifier == bundleIdentifier else {
                throw XToolDeploymentError.managedAppRecordCorrupt
            }
            return record
        } catch {
            throw XToolDeploymentError.managedAppRecordCorrupt
        }
    }

    func save(_ record: XToolManagedAppRecord) throws {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(record)
        let target = recordURL(for: record.bundleIdentifier)
        try data.write(to: target, options: .atomic)
    }

    func remove(bundleIdentifier: String) throws {
        let url = recordURL(for: bundleIdentifier)
        if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
    }

    private func recordURL(for bundleIdentifier: String) -> URL {
        let digest = SHA256.hash(data: Data(bundleIdentifier.utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent("\(digest).json")
    }
}

enum XToolJournalPhase: String, Codable {
    case prepared
    case oldProcessStopped
    case oldBundleBackedUp
    case swapped
    case launching
    case committed
    case rollingBack
}

struct XToolDeploymentJournal: Codable {
    var requestId: UUID
    var bundleIdentifier: String
    var dataUUID: String?
    var finalBundlePath: String
    var stagedBundlePath: String
    var backupBundlePath: String
    var oldBuildId: UUID?
    var newBuildId: UUID
    var phase: XToolJournalPhase
}

final class XToolDeploymentJournalStore {
    private let fileManager = FileManager.default
    private let root: URL

    init(root: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("XToolRunner/Transactions", isDirectory: true)) {
        self.root = root
    }

    func save(_ journal: XToolDeploymentJournal) throws {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("\(journal.requestId.uuidString).json")
        try JSONEncoder().encode(journal).write(to: target, options: .atomic)
    }

    func remove(_ journal: XToolDeploymentJournal) throws {
        let url = root.appendingPathComponent("\(journal.requestId.uuidString).json")
        if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
    }

    func unfinished() throws -> [XToolDeploymentJournal] {
        guard let urls = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        return urls.compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(XToolDeploymentJournal.self, from: data)
        }
    }
}

enum XToolDeploymentError: Error, LocalizedError, Sendable {
    case archiveTooLarge
    case invalidArchive(String)
    case unsafeArchiveEntry
    case missingAppBundle
    case multipleAppBundles
    case missingInfoPlist
    case bundleIdentifierMismatch
    case unsupportedArchitecture
    case existingAppNotManaged
    case managedAppRecordCorrupt
    case managedAppMissing
    case checksumMismatch
    case signingFailed(String)
    case processNotRegistered
    case terminateTimeout
    case windowCleanupFailed
    case swapFailed(String)
    case modelUpdateFailed(String)
    case launchFailed(String)
    case launchTimeout
    case rollbackFailed(String)
    case recoveryRequired
    case unsupportedOS

    var errorDescription: String? {
        switch self {
        case .archiveTooLarge: "IPA exceeds the configured size limit"
        case .invalidArchive(let message): "Invalid IPA: \(message)"
        case .unsafeArchiveEntry: "IPA contains an unsafe archive entry"
        case .missingAppBundle: "Payload does not contain an app bundle"
        case .multipleAppBundles: "Payload contains multiple app bundles"
        case .missingInfoPlist: "App bundle has no Info.plist"
        case .bundleIdentifierMismatch: "Bundle identifier does not match deployment metadata"
        case .unsupportedArchitecture: "App does not contain an arm64 executable"
        case .existingAppNotManaged: "An app with this bundle identifier is not managed by XTool Runner"
        case .managedAppRecordCorrupt: "Managed app record is corrupt"
        case .managedAppMissing: "Managed app bundle or data container is missing"
        case .checksumMismatch: "Payload SHA-256 does not match deployment metadata"
        case .signingFailed(let message): "Signing failed: \(message)"
        case .processNotRegistered: "Guest process is not registered"
        case .terminateTimeout: "Guest process did not terminate before timeout"
        case .windowCleanupFailed: "Guest window cleanup failed"
        case .swapFailed(let message): "Bundle swap failed: \(message)"
        case .modelUpdateFailed(let message): "LiveContainer model update failed: \(message)"
        case .launchFailed(let message): "Guest launch failed: \(message)"
        case .launchTimeout: "Guest launch timed out"
        case .rollbackFailed(let message): "Rollback failed: \(message)"
        case .recoveryRequired: "Runner recovery is required before deployment"
        case .unsupportedOS: "XTool Runner requires iOS 16.1 or newer"
        }
    }

    var code: String {
        switch self {
        case .archiveTooLarge: "payload_too_large"
        case .invalidArchive: "invalid_archive"
        case .unsafeArchiveEntry: "unsafe_archive_entry"
        case .missingAppBundle: "missing_app_bundle"
        case .multipleAppBundles: "multiple_app_bundles"
        case .missingInfoPlist: "missing_info_plist"
        case .bundleIdentifierMismatch: "bundle_id_mismatch"
        case .unsupportedArchitecture: "unsupported_architecture"
        case .existingAppNotManaged: "existing_app_not_managed"
        case .managedAppRecordCorrupt: "managed_app_record_corrupt"
        case .managedAppMissing: "managed_app_missing"
        case .checksumMismatch: "checksum_mismatch"
        case .signingFailed: "signing_failed"
        case .processNotRegistered: "process_not_registered"
        case .terminateTimeout: "terminate_timeout"
        case .windowCleanupFailed: "window_cleanup_failed"
        case .swapFailed: "swap_failed"
        case .modelUpdateFailed: "model_update_failed"
        case .launchFailed: "launch_failed"
        case .launchTimeout: "launch_timeout"
        case .rollbackFailed: "rollback_failed"
        case .recoveryRequired: "recovery_required"
        case .unsupportedOS: "unsupported_os"
        }
    }
}
