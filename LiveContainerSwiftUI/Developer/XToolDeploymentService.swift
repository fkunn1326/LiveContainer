import Foundation

struct XToolDeploymentFailure: Error {
    let error: Error
    let rolledBack: Bool
}

struct XToolDeploymentOutcome {
    let success: Bool
    let dataUUID: String?
    let pid: Int32?
    let rolledBack: Bool
    let message: String
}

@MainActor
final class XToolDeploymentService {
    static let shared = XToolDeploymentService()

    private let installationService: LCAppInstallationService
    private let managedStore: XToolManagedAppStore
    private let journalStore: XToolDeploymentJournalStore
    private let fileManager = FileManager.default
    private(set) var recoveryRequired = false
    private(set) var isDeploying = false

    init(
        installationService: LCAppInstallationService? = nil,
        managedStore: XToolManagedAppStore = XToolManagedAppStore(),
        journalStore: XToolDeploymentJournalStore = XToolDeploymentJournalStore()
    ) {
        self.installationService = installationService ?? .shared
        self.managedStore = managedStore
        self.journalStore = journalStore
        recoverUnfinishedTransactions()
    }

    func deploy(
        ipaURL: URL,
        payloadSHA256: String,
        metadata: XToolDeployMetadata,
        progress: @escaping @MainActor (XToolDeploymentPhase, Double?, String) -> Void
    ) async throws -> XToolDeploymentOutcome {
        guard #available(iOS 16.1, *) else { throw XToolDeploymentError.unsupportedOS }
        guard !recoveryRequired else { throw XToolDeploymentError.recoveryRequired }
        guard !isDeploying else { throw XToolDeploymentError.swapFailed("another deployment is active") }
        guard metadata.archiveFormat == "ipa", metadata.launchAfterInstall, metadata.preserveDataContainer else {
            throw XToolDeploymentError.invalidArchive("unsupported deployment options")
        }
        guard metadata.bundleIdentifier.isEmpty == false else { throw XToolDeploymentError.bundleIdentifierMismatch }
        guard payloadSHA256.caseInsensitiveCompare(metadata.payloadSHA256) == .orderedSame else {
            throw XToolDeploymentError.checksumMismatch
        }

        isDeploying = true
        defer { isDeploying = false }
        let currentApps = DataManager.shared.model.apps + DataManager.shared.model.hiddenApps
        let matchingApps = currentApps.filter { $0.appInfo.bundleIdentifier() == metadata.bundleIdentifier }
        guard matchingApps.count <= 1 else { throw XToolDeploymentError.existingAppNotManaged }
        let oldModel = matchingApps.first
        let oldRecord = try managedStore.record(for: metadata.bundleIdentifier)
        if oldModel != nil && oldRecord == nil { throw XToolDeploymentError.existingAppNotManaged }
        if let oldRecord, oldModel == nil { throw XToolDeploymentError.managedAppMissing }
        if let oldRecord, let oldModel {
            guard oldRecord.relativeBundlePath == oldModel.appInfo.relativeBundlePath,
                  oldRecord.dataUUID == oldModel.appInfo.dataUUID,
                  let bundlePath = oldModel.appInfo.bundlePath(),
                  fileManager.fileExists(atPath: bundlePath) else {
                throw XToolDeploymentError.managedAppMissing
            }
            let dataContainerURL = oldModel.appInfo.containers.first(where: { $0.folderName == oldRecord.dataUUID })?.containerURL
                ?? (oldModel.appInfo.isShared ? LCPath.lcGroupDataPath : LCPath.dataPath).appendingPathComponent(oldRecord.dataUUID)
            guard fileManager.fileExists(atPath: dataContainerURL.path) else {
                throw XToolDeploymentError.managedAppMissing
            }
        }

        progress(.verifying, nil, "Verifying IPA")
        let finalRoot = oldModel?.appInfo.isShared == true ? LCPath.lcGroupBundlePath : LCPath.bundlePath
        let relativePath = oldModel?.appInfo.relativeBundlePath ?? "\(metadata.bundleIdentifier.sanitizeNonACSII()).app"
        guard Self.isSafeRelativeBundlePath(relativePath) else {
            throw oldModel == nil ? XToolDeploymentError.invalidArchive("invalid bundle path") : XToolDeploymentError.managedAppMissing
        }
        let finalURL = finalRoot.appendingPathComponent(relativePath)
        if oldModel == nil, fileManager.fileExists(atPath: finalURL.path) {
            throw XToolDeploymentError.existingAppNotManaged
        }
        let stagingRoot = finalRoot.appendingPathComponent(".xtool-staging/\(metadata.requestId.uuidString)", isDirectory: true)
        let backupURL = finalRoot.appendingPathComponent(".xtool-backup/\(metadata.requestId.uuidString)/\(relativePath)", isDirectory: true)

        progress(.preparing, nil, "Preparing and signing staged bundle")
        let prepared = try await installationService.prepareIPA(
            at: ipaURL,
            expectedBundleIdentifier: metadata.bundleIdentifier,
            replacementPolicy: oldModel.map { .replacePreservingConfiguration(existing: $0) } ?? .newManagedApp,
            stagingRoot: stagingRoot,
            progress: { fraction in progress(.signing, fraction, "Signing staged bundle") }
        )
        var journal = XToolDeploymentJournal(
            requestId: metadata.requestId,
            bundleIdentifier: metadata.bundleIdentifier,
            dataUUID: oldModel?.appInfo.dataUUID,
            finalBundlePath: finalURL.path,
            stagedBundlePath: prepared.stagingBundleURL.path,
            backupBundlePath: backupURL.path,
            oldBuildId: oldRecord?.currentBuildId,
            newBuildId: metadata.buildId,
            phase: .prepared
        )
        do {
            try journalStore.save(journal)
        } catch {
            try? fileManager.removeItem(at: stagingRoot)
            throw error
        }

        if let dataUUID = oldModel?.appInfo.dataUUID {
            XToolDevRestartGate.begin(dataUUID: dataUUID)
            defer { XToolDevRestartGate.end(dataUUID: dataUUID) }
        }
        var replacementModel: LCAppModel?
        var deploymentDataUUID = oldModel?.appInfo.dataUUID
        do {
            if let oldModel, let dataUUID = oldModel.appInfo.dataUUID,
               oldModel.isAppRunning || XToolGuestProcessRegistry.shared.isRegistered(dataUUID: dataUUID) {
                progress(.terminating, nil, "Terminating guest")
                try await XToolGuestProcessRegistry.shared.terminateAndDestroy(dataUUID: dataUUID)
                journal.phase = .oldProcessStopped
                try journalStore.save(journal)
            }

            progress(.swapping, nil, "Swapping application bundle")
            try fileManager.createDirectory(at: backupURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: finalURL.path) {
                try fileManager.moveItem(at: finalURL, to: backupURL)
                journal.phase = .oldBundleBackedUp
                try journalStore.save(journal)
            }
            try fileManager.moveItem(at: prepared.stagingBundleURL, to: finalURL)
            journal.phase = .swapped
            try journalStore.save(journal)

            let newModel = try installationService.commitPreparedApp(prepared, replacing: oldModel, bundleAlreadyMoved: true)
            replacementModel = newModel
            journal.phase = .launching
            try journalStore.save(journal)
            var dataUUID = oldModel?.appInfo.dataUUID ?? newModel.appInfo.dataUUID ?? {
                let value = UUID().uuidString
                newModel.appInfo.dataUUID = value
                newModel.appInfo.save()
                return value
            }()
            deploymentDataUUID = dataUUID
            progress(.launching, nil, "Launching guest")
            if oldModel == nil {
                try await newModel.runApp(multitask: true)
                dataUUID = newModel.appInfo.dataUUID ?? dataUUID
            } else {
                try await newModel.runApp(multitask: true, containerFolderName: dataUUID)
            }
            let pid = try await XToolGuestProcessRegistry.shared.waitForInitialization(dataUUID: dataUUID)

            let record = XToolManagedAppRecord(
                bundleIdentifier: metadata.bundleIdentifier,
                relativeBundlePath: relativePath,
                dataUUID: dataUUID,
                currentBuildId: metadata.buildId,
                currentPayloadSHA256: metadata.payloadSHA256,
                lastSuccessfulDeployment: Date()
            )
            try managedStore.save(record)
            journal.phase = .committed
            try journalStore.save(journal)
            try? fileManager.removeItem(at: backupURL)
            try? journalStore.remove(journal)
            progress(.completed, 1, "Deployment completed")
            return XToolDeploymentOutcome(success: true, dataUUID: dataUUID, pid: pid, rolledBack: false, message: "Deployment completed")
        } catch {
            let rollbackSucceeded = await rollback(journal: journal, oldModel: oldModel, replacementModel: replacementModel, dataUUID: deploymentDataUUID, progress: progress)
            if rollbackSucceeded {
                if let oldRecord {
                    try? managedStore.save(oldRecord)
                } else {
                    try? managedStore.remove(bundleIdentifier: metadata.bundleIdentifier)
                }
                throw XToolDeploymentFailure(error: error, rolledBack: true)
            }
            throw XToolDeploymentFailure(error: XToolDeploymentError.rollbackFailed(error.localizedDescription), rolledBack: false)
        }
    }

    func relaunchManagedApp(bundleIdentifier: String) async throws -> Int32 {
        guard #available(iOS 16.1, *) else { throw XToolDeploymentError.unsupportedOS }
        guard !recoveryRequired else { throw XToolDeploymentError.recoveryRequired }
        let record = try managedStore.record(for: bundleIdentifier)
        guard let record else { throw XToolDeploymentError.managedAppMissing }
        let apps = (DataManager.shared.model.apps + DataManager.shared.model.hiddenApps).filter {
            $0.appInfo.bundleIdentifier() == bundleIdentifier
        }
        guard apps.count == 1, let app = apps.first else {
            throw XToolDeploymentError.managedAppMissing
        }
        let dataUUID = app.appInfo.dataUUID ?? record.dataUUID
        XToolDevRestartGate.begin(dataUUID: dataUUID)
        defer { XToolDevRestartGate.end(dataUUID: dataUUID) }
        if app.isAppRunning || XToolGuestProcessRegistry.shared.isRegistered(dataUUID: dataUUID) {
            try await XToolGuestProcessRegistry.shared.terminateAndDestroy(dataUUID: dataUUID)
        }
        try await app.runApp(multitask: true, containerFolderName: dataUUID)
        return try await XToolGuestProcessRegistry.shared.waitForInitialization(dataUUID: dataUUID)
    }

    func recoverUnfinishedTransactions() {
        recoveryRequired = false
        do {
            for journal in try journalStore.unfinished() {
                let finalURL = URL(fileURLWithPath: journal.finalBundlePath)
                let stagedURL = URL(fileURLWithPath: journal.stagedBundlePath)
                let backupURL = URL(fileURLWithPath: journal.backupBundlePath)
                let finalExists = fileManager.fileExists(atPath: finalURL.path)
                let backupExists = fileManager.fileExists(atPath: backupURL.path)
                let stagedExists = fileManager.fileExists(atPath: stagedURL.path)

                if journal.phase == .committed {
                    guard finalExists else {
                        recoveryRequired = true
                        continue
                    }
                    if backupExists { try? fileManager.removeItem(at: backupURL) }
                    if stagedExists { try? fileManager.removeItem(at: stagedURL) }
                    try journalStore.remove(journal)
                    continue
                }

                if backupExists {
                    if finalExists {
                        let quarantine = backupURL.deletingLastPathComponent().appendingPathComponent("quarantine-\(journal.newBuildId.uuidString).app")
                        if fileManager.fileExists(atPath: quarantine.path) { try? fileManager.removeItem(at: quarantine) }
                        try fileManager.moveItem(at: finalURL, to: quarantine)
                    }
                    try fileManager.createDirectory(at: finalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fileManager.moveItem(at: backupURL, to: finalURL)
                } else if finalExists {
                    switch journal.phase {
                    case .prepared, .oldProcessStopped:
                        break
                    case .oldBundleBackedUp, .swapped, .launching, .rollingBack:
                        recoveryRequired = true
                        continue
                    case .committed:
                        break
                    }
                } else if stagedExists, journal.phase == .prepared {
                    try fileManager.removeItem(at: stagedURL)
                } else {
                    recoveryRequired = true
                    continue
                }

                if fileManager.fileExists(atPath: stagedURL.path) { try? fileManager.removeItem(at: stagedURL) }
                try journalStore.remove(journal)
            }
        } catch {
            recoveryRequired = true
        }
    }

    private func rollback(
        journal: XToolDeploymentJournal,
        oldModel: LCAppModel?,
        replacementModel: LCAppModel?,
        dataUUID: String?,
        progress: @escaping @MainActor (XToolDeploymentPhase, Double?, String) -> Void
    ) async -> Bool {
        guard #available(iOS 16.1, *) else { return false }
        progress(.rollingBack, nil, "Rolling back to last known good bundle")
        do {
            let shouldStopGuest: Bool
            switch journal.phase {
            case .swapped, .launching, .rollingBack, .committed:
                shouldStopGuest = true
            case .prepared, .oldProcessStopped, .oldBundleBackedUp:
                shouldStopGuest = false
            }
            if shouldStopGuest, let dataUUID {
                try? await XToolGuestProcessRegistry.shared.terminateAndDestroy(dataUUID: dataUUID)
            }
            let finalURL = URL(fileURLWithPath: journal.finalBundlePath)
            let backupURL = URL(fileURLWithPath: journal.backupBundlePath)

            if let replacementModel {
                DataManager.shared.model.apps.removeAll { $0 === replacementModel }
                DataManager.shared.model.hiddenApps.removeAll { $0 === replacementModel }
            }

            let backupExists = fileManager.fileExists(atPath: backupURL.path)
            let swapMayHaveCompleted = backupExists || {
                switch journal.phase {
                case .swapped, .launching, .rollingBack, .committed: return true
                case .prepared, .oldProcessStopped, .oldBundleBackedUp: return false
                }
            }()
            if swapMayHaveCompleted, fileManager.fileExists(atPath: finalURL.path) {
                let quarantine = backupURL.deletingLastPathComponent().appendingPathComponent("quarantine-\(journal.newBuildId.uuidString).app")
                try fileManager.createDirectory(at: quarantine.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fileManager.fileExists(atPath: quarantine.path) { try fileManager.removeItem(at: quarantine) }
                try fileManager.moveItem(at: finalURL, to: quarantine)
            }
            if backupExists {
                try fileManager.createDirectory(at: finalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.moveItem(at: backupURL, to: finalURL)
            }
            if let oldModel {
                oldModel.appInfo.setBundlePath(finalURL.path)
                oldModel.appInfo.save()
                if !DataManager.shared.model.apps.contains(where: { $0 === oldModel }) && !DataManager.shared.model.hiddenApps.contains(where: { $0 === oldModel }) {
                    if oldModel.uiIsHidden { DataManager.shared.model.hiddenApps.append(oldModel) }
                    else { DataManager.shared.model.apps.append(oldModel) }
                }
                if let dataUUID {
                    try await oldModel.runApp(multitask: true, containerFolderName: dataUUID)
                    _ = try await XToolGuestProcessRegistry.shared.waitForInitialization(dataUUID: dataUUID)
                }
            }
            var committedJournal = journal
            committedJournal.phase = .committed
            try journalStore.save(committedJournal)
            try? journalStore.remove(committedJournal)
            return true
        } catch {
            recoveryRequired = true
            return false
        }
    }

    private static func isSafeRelativeBundlePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), URL(fileURLWithPath: path).pathExtension == "app" else { return false }
        let components = path.split(separator: "/")
        guard !components.isEmpty, !components.contains(where: { $0 == "." || $0 == ".." }) else { return false }
        return !components.contains(where: { $0.contains("\\") })
    }
}
