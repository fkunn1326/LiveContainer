import Foundation

enum LCReplacementPolicy {
    case newManagedApp
    case replacePreservingConfiguration(existing: LCAppModel)
}

enum LCInstallationChoice {
    case new(relativeBundlePath: String)
    case replace(LCAppModel)
}

struct LCPreparedApp {
    let requestId: UUID
    let stagingBundleURL: URL
    let appInfo: LCAppInfo
    let expectedBundleIdentifier: String
    let preservedDataUUID: String?
}

/// UI-independent installation boundary shared by the file picker and XTool deploys.
/// The service owns archive preparation, app-info creation, signing, and configuration
/// copying; views only decide how to present errors and replacement choices.
@MainActor
final class LCAppInstallationService {
    static let shared = LCAppInstallationService()

    private let archiveService = XToolArchiveService()

    func prepareIPA(
        at ipaURL: URL,
        expectedBundleIdentifier: String? = nil,
        replacementPolicy: LCReplacementPolicy,
        stagingRoot: URL? = nil,
        progress: @escaping @MainActor (Double?) -> Void = { _ in }
    ) async throws -> LCPreparedApp {
        let requestId = UUID()
        let expected = expectedBundleIdentifier ?? ""
        let stagingURL = stagingRoot ?? LCPath.bundlePath.appendingPathComponent(".xtool-staging/\(requestId.uuidString)", isDirectory: true)
        var keepStaging = false
        defer {
            if !keepStaging { try? FileManager.default.removeItem(at: stagingURL) }
        }
        progress(nil)
        let prepared = try await archiveService.prepare(
            ipaURL: ipaURL,
            expectedBundleIdentifier: expected.isEmpty ? nil : expected,
            stagingRoot: stagingURL
        )
        progress(1)
        guard let appInfo = LCAppInfo(bundlePath: prepared.appURL.path) else {
            throw XToolDeploymentError.invalidArchive("Info.plist could not be loaded")
        }
        appInfo.relativeBundlePath = prepared.appURL.lastPathComponent
        switch replacementPolicy {
        case .newManagedApp:
            appInfo.relativeBundlePath = "\(prepared.bundleIdentifier.sanitizeNonACSII()).app"
            appInfo.dataUUID = nil
            appInfo.containerInfo = nil
            appInfo.spoofSDKVersion = true
        case .replacePreservingConfiguration(let existing):
            copyConfiguration(from: existing.appInfo, to: appInfo)
        }
        appInfo.installationDate = Date()
        try await sign(appInfo: appInfo, progress: progress)
        keepStaging = true
        return LCPreparedApp(
            requestId: requestId,
            stagingBundleURL: prepared.appURL,
            appInfo: appInfo,
            expectedBundleIdentifier: prepared.bundleIdentifier,
            preservedDataUUID: appInfo.dataUUID
        )
    }

    func commitPreparedApp(_ prepared: LCPreparedApp, replacing existing: LCAppModel? = nil, bundleAlreadyMoved: Bool = false) throws -> LCAppModel {
        let fileManager = FileManager.default
        let relativePath = existing?.appInfo.relativeBundlePath ?? prepared.appInfo.relativeBundlePath ?? "\(prepared.expectedBundleIdentifier).app"
        let finalRoot = (existing?.appInfo.isShared == true ? LCPath.lcGroupBundlePath : LCPath.bundlePath)
        let finalURL = finalRoot.appendingPathComponent(relativePath)
        try fileManager.createDirectory(at: finalRoot, withIntermediateDirectories: true)
        if bundleAlreadyMoved {
            guard fileManager.fileExists(atPath: finalURL.path) else {
                throw XToolDeploymentError.swapFailed("staged bundle is missing after swap")
            }
        } else {
            if fileManager.fileExists(atPath: finalURL.path) { try fileManager.removeItem(at: finalURL) }
            try fileManager.moveItem(at: prepared.stagingBundleURL, to: finalURL)
        }
        prepared.appInfo.setBundlePath(finalURL.path)
        prepared.appInfo.relativeBundlePath = relativePath
        prepared.appInfo.save()
        let model = LCAppModel(appInfo: prepared.appInfo)
        if let existing {
            model.delegate = existing.delegate
            DataManager.shared.model.apps.removeAll { $0 === existing }
            DataManager.shared.model.hiddenApps.removeAll { $0 === existing }
            if existing.uiIsHidden { DataManager.shared.model.hiddenApps.append(model) }
            else { DataManager.shared.model.apps.append(model) }
        } else {
            DataManager.shared.model.apps.append(model)
        }
        return model
    }

    func installFromIPAForUI(
        at ipaURL: URL,
        choose: @escaping @MainActor ([LCAppModel], String) async -> LCInstallationChoice?
    ) async throws -> LCAppModel {
        let requestId = UUID()
        let stagingRoot = LCPath.bundlePath.appendingPathComponent(".xtool-staging/\(requestId.uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: stagingRoot) }
        let preparedBundle = try await archiveService.prepare(ipaURL: ipaURL, expectedBundleIdentifier: nil, stagingRoot: stagingRoot)
        guard let appInfo = LCAppInfo(bundlePath: preparedBundle.appURL.path) else {
            throw XToolDeploymentError.invalidArchive("Info.plist could not be loaded")
        }
        let candidates = (DataManager.shared.model.apps + DataManager.shared.model.hiddenApps).filter { $0.appInfo.bundleIdentifier() == preparedBundle.bundleIdentifier }
        let preferredName = "\(preparedBundle.bundleIdentifier.sanitizeNonACSII()).app"
        guard let choice = try await choose(candidates, preferredName) else {
            try? FileManager.default.removeItem(at: stagingRoot)
            throw CancellationError()
        }
        let existing: LCAppModel?
        switch choice {
        case .new(let relativePath):
            existing = nil
            appInfo.relativeBundlePath = relativePath
            appInfo.dataUUID = nil
            appInfo.containerInfo = nil
            appInfo.spoofSDKVersion = true
        case .replace(let model):
            existing = model
            copyConfiguration(from: model.appInfo, to: appInfo)
        }
        try await sign(appInfo: appInfo, progress: { _ in })
        appInfo.installationDate = Date()
        let prepared = LCPreparedApp(requestId: requestId, stagingBundleURL: preparedBundle.appURL, appInfo: appInfo, expectedBundleIdentifier: preparedBundle.bundleIdentifier, preservedDataUUID: appInfo.dataUUID)
        return try commitPreparedApp(prepared, replacing: existing)
    }

    func copyConfiguration(from old: LCAppInfo, to new: LCAppInfo) {
        new.autoSaveDisabled = true
        new.isLocked = old.isLocked
        new.isHidden = old.isHidden
        new.isJITNeeded = old.isJITNeeded
        new.isShared = old.isShared
        new.spoofSDKVersion = old.spoofSDKVersion
        new.doSymlinkInbox = old.doSymlinkInbox
        new.containerInfo = old.containerInfo
        new.tweakFolder = old.tweakFolder
        new.selectedLanguage = old.selectedLanguage
        new.dataUUID = old.dataUUID
        new.selected32BitEmulator = old.selected32BitEmulator
        new.is32bit = old.is32bit
        new.orientationLock = old.orientationLock
        new.dontInjectTweakLoader = old.dontInjectTweakLoader
        new.hideLiveContainer = old.hideLiveContainer
        new.dontLoadTweakLoader = old.dontLoadTweakLoader
        new.doUseLCBundleId = old.doUseLCBundleId
        new.fixFilePickerNew = old.fixFilePickerNew
        new.fixLocalNotification = old.fixLocalNotification
        new.lastLaunched = old.lastLaunched
        new.jitLaunchScriptJs = old.jitLaunchScriptJs
        new.multitaskSpecified = old.multitaskSpecified
        new.classicMode = old.classicMode
        new.dontSign = old.dontSign
        new.remark = old.remark
        new.autoSaveDisabled = false
    }

    private func sign(appInfo: LCAppInfo, progress: @escaping @MainActor (Double?) -> Void) async throws {
        if appInfo.dontSign || LCUtils.appGroupUserDefault.bool(forKey: "LCDontSignApp") {
            appInfo.save()
            return
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            appInfo.patchExecAndSignIfNeed(completionHandler: { success, error in
                if success { continuation.resume() }
                else { continuation.resume(throwing: XToolDeploymentError.signingFailed(error ?? "unknown signing error")) }
            }, progressHandler: { signingProgress in
                Task { @MainActor in
                    progress(signingProgress?.fractionCompleted)
                }
            }, forceSign: false)
        }
    }
}

struct XToolPreparedBundle: Sendable {
    let appURL: URL
    let bundleIdentifier: String
    let displayName: String
    let executableURL: URL
}

actor XToolArchiveService {
    func prepare(
        ipaURL: URL,
        expectedBundleIdentifier: String?,
        stagingRoot: URL
    ) throws -> XToolPreparedBundle {
        let fileManager = FileManager.default
        let archiveSize = try UInt64(ipaURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        guard archiveSize <= XToolProtocol.maximumPayloadLength else { throw XToolDeploymentError.archiveTooLarge }
        var validationError: NSString?
        let validationStatus = validateIPAArchive(ipaURL.path, XToolProtocol.maximumExpandedLength, XToolProtocol.maximumFileCount, &validationError)
        guard validationStatus == 0 else {
            if validationStatus == 2 || validationStatus == 3 { throw XToolDeploymentError.unsafeArchiveEntry }
            if validationStatus == 5 { throw XToolDeploymentError.archiveTooLarge }
            throw XToolDeploymentError.invalidArchive(validationError as String? ?? "archive validation failed")
        }
        try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        let extractionProgress = Progress(totalUnitCount: 100)
        guard extract(ipaURL.path, stagingRoot.path, extractionProgress) == 0 else {
            throw XToolDeploymentError.invalidArchive("archive extraction failed")
        }
        let payloadRoot = stagingRoot.appendingPathComponent("Payload", isDirectory: true)
        var payloadIsDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: payloadRoot.path, isDirectory: &payloadIsDirectory), payloadIsDirectory.boolValue else {
            throw XToolDeploymentError.missingAppBundle
        }
        let apps = try fileManager.contentsOfDirectory(at: payloadRoot, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: []).filter { url in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            return url.pathExtension == "app" && values?.isDirectory == true && values?.isSymbolicLink != true
        }
        guard !apps.isEmpty else { throw XToolDeploymentError.missingAppBundle }
        guard apps.count == 1, let appURL = apps.first else { throw XToolDeploymentError.multipleAppBundles }
        let infoURL = appURL.appendingPathComponent("Info.plist")
        guard let infoData = try? Data(contentsOf: infoURL),
              let infoObject = try? PropertyListSerialization.propertyList(from: infoData, options: [], format: nil),
              let info = infoObject as? [String: Any] else { throw XToolDeploymentError.missingInfoPlist }
        guard let bundleIdentifier = info["CFBundleIdentifier"] as? String, !bundleIdentifier.isEmpty else {
            throw XToolDeploymentError.invalidArchive("missing CFBundleIdentifier")
        }
        if let expectedBundleIdentifier, expectedBundleIdentifier != bundleIdentifier {
            throw XToolDeploymentError.bundleIdentifierMismatch
        }
        guard let executable = info["CFBundleExecutable"] as? String,
              !executable.isEmpty,
              !executable.hasPrefix("/"),
              !executable.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            throw XToolDeploymentError.invalidArchive("missing CFBundleExecutable")
        }
        let executableURL = appURL.appendingPathComponent(executable)
        guard executableURL.standardizedFileURL.path.hasPrefix(appURL.standardizedFileURL.path + "/") else {
            throw XToolDeploymentError.invalidArchive("main executable path escapes app bundle")
        }
        guard fileManager.fileExists(atPath: executableURL.path) else {
            throw XToolDeploymentError.invalidArchive("main executable is missing")
        }
        guard Self.containsArm64MachO(executableURL) else { throw XToolDeploymentError.unsupportedArchitecture }
        let displayName = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? appURL.deletingPathExtension().lastPathComponent
        return XToolPreparedBundle(appURL: appURL, bundleIdentifier: bundleIdentifier, displayName: displayName, executableURL: executableURL)
    }

    private static func containsArm64MachO(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]), data.count >= 4 else { return false }
        let magic = data.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let arm64CPU: UInt32 = 0x0100_000c
        switch magic {
        case 0xfeedfacf:
            return data.count >= 8 && readUInt32(data, offset: 4, littleEndian: false) == arm64CPU
        case 0xcffaedfe:
            return data.count >= 8 && readUInt32(data, offset: 4, littleEndian: true) == arm64CPU
        case 0xcafebabe, 0xbebafeca:
            let littleEndian = magic == 0xbebafeca
            let count = Int(readUInt32(data, offset: 4, littleEndian: littleEndian))
            guard count > 0, count <= 256, data.count >= 8 + count * 20 else { return false }
            for index in 0..<count {
                let offset = 8 + index * 20
                if readUInt32(data, offset: offset, littleEndian: littleEndian) == arm64CPU { return true }
            }
            return false
        default:
            return false
        }
    }

    private static func readUInt32(_ data: Data, offset: Int, littleEndian: Bool) -> UInt32 {
        let bytes = data[offset..<(offset + 4)]
        if littleEndian {
            return bytes.enumerated().reduce(UInt32(0)) { $0 | (UInt32($1.element) << (UInt32($1.offset) * 8)) }
        }
        return bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
}
