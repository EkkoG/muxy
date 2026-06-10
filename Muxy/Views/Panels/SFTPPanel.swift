import Foundation
import SwiftUI
import UniformTypeIdentifiers
import os

struct SFTPPanel: View {
    nonisolated private static let logger = Logger(subsystem: "app.muxy", category: "SFTPPanel")
    nonisolated private static let remoteDragPayloadPrefix = "muxy-sftp-remote-path:"
    nonisolated private static let remoteDragPayloadTypeIdentifier = "com.muxy.sftp.remote-path"
    @Environment(AppState.self) private var appState
    @Environment(ProjectStore.self) private var projectStore
    @Environment(WorktreeStore.self) private var worktreeStore

    @State private var localPath: String = NSHomeDirectory()
    @State private var remotePath: String = "/"
    @State private var localItems: [SFTPFileItem] = []
    @State private var remoteItems: [SFTPFileItem] = []
    @State private var localLoading = false
    @State private var remoteLoading = false
    @State private var localMessage = ""
    @State private var remoteMessage = ""
    @State private var selectedLocalItemID: String?
    @State private var selectedRemoteItemID: String?
    @State private var isRemoteDropTarget = false
    @State private var isLocalDropTarget = false
    @State private var transferHistory: [SFTPTransferRecord] = []
    private let maxTransferHistoryEntries = 120

    private enum SFTPTransferDirection: String {
        case upload = "Upload"
        case download = "Download"
    }

    private enum SFTPTransferResult: String {
        case success = "Success"
        case blocked = "Blocked"
        case failed = "Failed"
    }

    private struct SFTPTransferRecord: Identifiable, Hashable {
        let id = UUID()
        let direction: SFTPTransferDirection
        let source: String
        let destination: String
        let result: SFTPTransferResult
        let message: String
        let timestamp: Date
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().overlay(MuxyTheme.border)
            HStack(spacing: 0) {
                fileList(
                    title: "Local",
                    path: localPath,
                    items: localItems,
                    loading: localLoading,
                    message: localMessage,
                    selectedID: selectedLocalItemID,
                    showUpButton: hasLocalParent(localPath),
                    onUp: { navigateLocalParent() },
                    onSelect: selectLocalItem,
                    onOpen: openLocalItem,
                    onDrop: { providers in
                        downloadDroppedToLocal(providers)
                    },
                    isDropTarget: $isLocalDropTarget,
                    dragProvider: { item in
                        NSItemProvider(
                            item: URL(fileURLWithPath: item.absolutePath) as NSURL,
                            typeIdentifier: UTType.fileURL.identifier
                        )
                    },
                    onUpload: { item in
                        Task { await uploadItem(item, overwrite: false) }
                    },
                    onUploadOverwrite: { item in
                        Task { await uploadItem(item, overwrite: true) }
                    }
                )

                Rectangle()
                    .fill(MuxyTheme.border)
                    .frame(width: 1)

                fileList(
                    title: "Remote",
                    path: remotePath,
                    items: remoteItems,
                    loading: remoteLoading,
                    message: remoteMessage,
                    selectedID: selectedRemoteItemID,
                    showUpButton: remotePath != "/",
                    onUp: { navigateRemoteParent() },
                    onSelect: selectRemoteItem,
                    onOpen: openRemoteItem,
                    onDrop: { providers in
                        uploadDropped(providers)
                    },
                    isDropTarget: $isRemoteDropTarget,
                    dragProvider: { item in
                        remoteDragProvider(for: item)
                    },
                    onDownload: { item in
                        Task { await downloadItem(item, overwrite: false) }
                    },
                    onDownloadOverwrite: { item in
                        Task { await downloadItem(item, overwrite: true) }
                    }
                )
            }
            Divider().overlay(MuxyTheme.border)
            transferHistorySection
        }
        .onAppear { syncContext() }
        .onChange(of: appState.activeProjectID) { _, _ in syncContext() }
        .onChange(of: localPath) { _, _ in
            selectedLocalItemID = nil
            refreshLocal()
        }
        .onChange(of: remotePath) { _, _ in
            selectedRemoteItemID = nil
            Task { await refreshRemote() }
        }
    }

    private var toolbar: some View {
        HStack(spacing: UIMetrics.spacing2) {
            Group {
                Text("Local")
                    .font(.system(size: UIMetrics.fontFootnote, weight: .medium))
                    .foregroundStyle(MuxyTheme.fgMuted)
                    .frame(width: UIMetrics.scaled(54), alignment: .leading)

                Text(localPath)
                    .font(.system(size: UIMetrics.fontFootnote))
                    .foregroundStyle(MuxyTheme.fg)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider().overlay(MuxyTheme.border)

            Group {
                Text("Remote")
                    .font(.system(size: UIMetrics.fontFootnote, weight: .medium))
                    .foregroundStyle(MuxyTheme.fgMuted)
                    .frame(width: UIMetrics.scaled(54), alignment: .leading)

                Text(remotePath)
                    .font(.system(size: UIMetrics.fontFootnote))
                    .foregroundStyle(MuxyTheme.fg)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer(minLength: UIMetrics.spacing2)
            iconButton(symbol: "arrow.clockwise", label: "Refresh", action: { refreshBoth() })
            iconButton(
                symbol: "arrow.up.to.line.compact",
                label: "Upload",
                action: { Task { await uploadSelected() } },
                isDisabled: selectedLocalItem?.isDirectory ?? true || remoteConfiguration == nil
            )
            iconButton(
                symbol: "arrow.down.to.line.compact",
                label: "Download",
                action: { Task { await downloadSelected() } },
                isDisabled: remoteConfiguration == nil || selectedRemoteItem?.isDirectory ?? true
            )
        }
        .padding(.horizontal, UIMetrics.spacing4)
        .frame(height: UIMetrics.scaled(36))
    }

    private func syncContext() {
        Self.logger.info("syncContext start localPath=\(self.localPath, privacy: .public) remotePath=\(self.remotePath, privacy: .public)")
        let nextLocalPath = normalizedLocalPath(localRootPath())
        if localPath != nextLocalPath {
            Self.logger.debug("syncContext reset localPath from=\(self.localPath, privacy: .public) to=\(nextLocalPath, privacy: .public)")
            localPath = nextLocalPath
        }
        refreshLocal()
        let nextRemotePath = normalizedRemotePath(remoteRootPath())
        if remotePath != nextRemotePath {
            Self.logger.debug("syncContext reset remotePath from=\(self.remotePath, privacy: .public) to=\(nextRemotePath, privacy: .public)")
            remotePath = nextRemotePath
        }
        Task {
            Self.logger.debug("syncContext trigger refreshRemote")
            await refreshRemote()
        }
    }

    private func refreshBoth() {
        Self.logger.info("refreshBoth start")
        refreshLocal()
        Task { await refreshRemote() }
    }

    private func refreshLocal() {
        Self.logger.debug("refreshLocal start path=\(localPath, privacy: .public)")
        localLoading = true
        localMessage = ""
        defer {
            localLoading = false
            if localItems.isEmpty {
                localMessage = localMessage.isEmpty ? "Directory is empty" : localMessage
            }
            Self.logger.debug("refreshLocal done path=\(localPath, privacy: .public) count=\(localItems.count, privacy: .public) message=\(localMessage, privacy: .public)")
        }
        let target = normalizedLocalPath(localPath)
        Self.logger.debug("refreshLocal normalized=\(target, privacy: .public)")
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: target, isDirectory: &isDirectory) else {
            localItems = []
            localMessage = "Directory does not exist"
            Self.logger.error("refreshLocal path missing path=\(target, privacy: .public)")
            return
        }
        guard isDirectory.boolValue else {
            localItems = []
            localMessage = "Not a directory"
            Self.logger.error("refreshLocal path not directory path=\(target, privacy: .public)")
            return
        }
        localItems = SFTPService.shared.localEntries(at: target)
    }

    private func refreshRemote() async {
        guard let configuration = remoteConfiguration else {
            remoteItems = []
            remoteMessage = "No remote configuration found"
            remoteLoading = false
            Self.logger.warning("refreshRemote skipped: no remote configuration")
            return
        }
        Self.logger.debug("refreshRemote start path=\(remotePath, privacy: .public) host=\(configuration.host, privacy: .public)")
        remoteLoading = true
        remoteMessage = ""
        defer { remoteLoading = false }
        do {
            remoteItems = try await SFTPService.shared.listRemoteDirectory(
                configuration: configuration,
                path: remotePath
            )
            Self.logger.debug("refreshRemote done path=\(remotePath, privacy: .public) count=\(remoteItems.count, privacy: .public)")
        } catch {
            remoteItems = []
            remoteMessage = error.localizedDescription
            Self.logger.error("refreshRemote failed path=\(remotePath, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
    }

    private func selectLocalItem(_ item: SFTPFileItem) {
        selectedLocalItemID = item.id
    }

    private func selectRemoteItem(_ item: SFTPFileItem) {
        selectedRemoteItemID = item.id
    }

    private func openLocalItem(_ item: SFTPFileItem) {
        if item.isDirectory {
            localPath = item.absolutePath
        }
    }

    private func openRemoteItem(_ item: SFTPFileItem) {
        if item.isDirectory {
            remotePath = item.absolutePath
        }
    }

    private func navigateLocalParent() {
        let parent = URL(fileURLWithPath: localPath).deletingLastPathComponent().path
        if parent != localPath {
            localPath = parent
        }
    }

    private func navigateRemoteParent() {
        let normalized = normalizedRemotePath(remotePath)
        if normalized == "/" { return }
        remotePath = normalizedRemotePath(URL(fileURLWithPath: normalized).deletingLastPathComponent().path)
    }

    private func uploadSelected() async {
        guard let source = selectedLocalItem, remoteConfiguration != nil else { return }
        Self.logger.info("uploadSelected name=\(source.name, privacy: .public) remotePath=\(remotePath, privacy: .public)")
        if source.isDirectory { return }
        await uploadItem(source, overwrite: true)
    }

    private func uploadItem(_ item: SFTPFileItem, overwrite: Bool) async {
        Self.logger.info("uploadItem start item=\(item.absolutePath, privacy: .public) overwrite=\(String(overwrite), privacy: .public)")
        guard let config = remoteConfiguration else {
            Self.logger.error("uploadItem failed no remote config item=\(item.absolutePath, privacy: .public)")
            remoteMessage = "No remote configuration found"
            addTransferRecord(
                direction: .upload,
                source: item.absolutePath,
                destination: joinRemotePath(base: remotePath, child: item.name),
                result: .failed,
                message: "No remote configuration found"
            )
            return
        }
        if item.isDirectory { return }
        let sourcePath = URL(fileURLWithPath: item.absolutePath).standardized.path
        guard FileManager.default.fileExists(atPath: sourcePath) else {
            Self.logger.error("uploadItem source missing path=\(sourcePath, privacy: .public)")
            remoteMessage = "Upload source file not found"
            addTransferRecord(
                direction: .upload,
                source: sourcePath,
                destination: joinRemotePath(base: remotePath, child: item.name),
                result: .failed,
                message: "Upload source file not found"
            )
            return
        }
        let destination = joinRemotePath(base: remotePath, child: item.name)
        if !overwrite {
            do {
                Self.logger.debug("uploadItem checking remote exists destination=\(destination, privacy: .public)")
                if try await remoteFileExists(at: destination, configuration: config) {
                    Self.logger.notice("uploadItem blocked existing remote file destination=\(destination, privacy: .public)")
                    remoteMessage = "Remote file already exists. Use Upload Overwrite."
                addTransferRecord(
                    direction: .upload,
                    source: sourcePath,
                    destination: destination,
                    result: .blocked,
                    message: "Remote file already exists"
                )
                return
                }
            } catch {
                Self.logger.error("uploadItem remote exists check failed destination=\(destination, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                remoteMessage = error.localizedDescription
                addTransferRecord(
                    direction: .upload,
                    source: sourcePath,
                    destination: destination,
                    result: .failed,
                    message: error.localizedDescription
                )
                return
            }
        }
        do {
            Self.logger.debug("uploadItem uploading source=\(sourcePath, privacy: .public) destination=\(destination, privacy: .public)")
            remoteMessage = ""
            try await SFTPService.shared.upload(
                configuration: config,
                localPath: sourcePath,
                remotePath: destination
            )
            await refreshRemote()
            Self.logger.info("uploadItem success source=\(sourcePath, privacy: .public) destination=\(destination, privacy: .public)")
            addTransferRecord(
                direction: .upload,
                source: sourcePath,
                destination: destination,
                result: .success,
                message: overwrite ? "Upload Overwrite" : "Upload"
            )
        } catch {
            remoteMessage = error.localizedDescription
            Self.logger.error("uploadItem failed source=\(sourcePath, privacy: .public) destination=\(destination, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            addTransferRecord(
                direction: .upload,
                source: sourcePath,
                destination: destination,
                result: .failed,
                message: error.localizedDescription
            )
        }
    }

    private func remoteDragProvider(for item: SFTPFileItem) -> NSItemProvider {
        guard !item.isDirectory else {
            return NSItemProvider()
        }
        let provider = NSItemProvider()
        provider.suggestedName = item.name
        let configuration = remoteConfiguration
        let destination = remoteDragCachePath(for: item)
        Self.logger.debug("remoteDragProvider create item=\(item.absolutePath, privacy: .public) cachePath=\(destination.path, privacy: .public)")
        provider.registerFileRepresentation(
            forTypeIdentifier: UTType.fileURL.identifier,
            visibility: .all
        ) { completion in
            Self.logger.debug("remoteDragProvider provide start item=\(item.absolutePath, privacy: .public) cachePath=\(destination.path, privacy: .public)")
            Task {
                guard let config = configuration else {
                    Self.logger.error("remoteDragProvider no config item=\(item.absolutePath, privacy: .public)")
                    completion(nil, false, SFTPServiceError.noRemoteConfig)
                    return
                }
                do {
                    try FileManager.default.createDirectory(
                        at: destination.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    if FileManager.default.fileExists(atPath: destination.path) {
                        try FileManager.default.removeItem(at: destination)
                    }
                    Self.logger.debug("remoteDragProvider download remote before copy item=\(item.absolutePath, privacy: .public) to=\(destination.path, privacy: .public)")
                    try await SFTPService.shared.download(
                        configuration: config,
                        remotePath: item.absolutePath,
                        localPath: destination.path
                    )
                    Self.logger.info("remoteDragProvider success item=\(item.absolutePath, privacy: .public) cachePath=\(destination.path, privacy: .public)")
                    completion(destination, true, nil)
                } catch {
                    Self.logger.error("remoteDragProvider failed item=\(item.absolutePath, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                    completion(nil, false, error)
                }
            }
            return nil
        }
        provider.registerDataRepresentation(forTypeIdentifier: Self.remoteDragPayloadTypeIdentifier, visibility: .all) { completion in
            completion(Self.remoteDragPayload(for: item.absolutePath).data(using: .utf8), nil)
            return nil
        }
        provider.registerDataRepresentation(forTypeIdentifier: UTType.plainText.identifier, visibility: .all) { completion in
            completion(Self.remoteDragPayload(for: item.absolutePath).data(using: .utf8), nil)
            return nil
        }
        return provider
    }

    nonisolated private static func remoteDragPayload(for remotePath: String) -> String {
        "\(remoteDragPayloadPrefix)\(remotePath)"
    }

    nonisolated private func remoteDragPath(from plainText: String) -> String? {
        let text = plainText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix(Self.remoteDragPayloadPrefix) else {
            return nil
        }
        let remotePath = text.dropFirst(Self.remoteDragPayloadPrefix.count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return remotePath.isEmpty ? nil : String(remotePath)
    }

    nonisolated private func remoteDragCachePath(for item: SFTPFileItem) -> URL {
        let cacheDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Muxy")
            .appendingPathComponent("SFTPPanel")
            .appendingPathComponent("remote-drag")
        let cacheNamespace = item.id.replacingOccurrences(of: "/", with: "_")
        return cacheDirectory
            .appendingPathComponent(cacheNamespace)
            .appendingPathComponent(item.name)
    }

    private func downloadSelected() async {
        guard let config = remoteConfiguration else {
            localMessage = "No remote configuration found"
            return
        }
        guard let item = selectedRemoteItem else {
            localMessage = "No remote file selected"
            return
        }
        if item.isDirectory { return }
        Self.logger.info("downloadSelected start item=\(item.absolutePath, privacy: .public) localPath=\(localPath, privacy: .public)")
        await downloadItem(item, overwrite: true, configuration: config)
    }

    private func downloadItem(_ item: SFTPFileItem, overwrite: Bool) async {
        await downloadItem(item, overwrite: overwrite, configuration: remoteConfiguration)
    }

    private func downloadItem(_ item: SFTPFileItem, overwrite: Bool, configuration: NativeSSHConnectionConfiguration?) async {
        guard let configuration = configuration else {
            localMessage = "No remote configuration found"
            Self.logger.error("downloadItem failed no remote config item=\(item.absolutePath, privacy: .public)")
            addTransferRecord(
                direction: .download,
                source: item.absolutePath,
                destination: URL(fileURLWithPath: localPath).appendingPathComponent(item.name).path,
                result: .failed,
                message: "No remote configuration found"
            )
            return
        }
        let destination = URL(fileURLWithPath: localPath).appendingPathComponent(item.name).path
        Self.logger.debug("downloadItem start item=\(item.absolutePath, privacy: .public) destination=\(destination, privacy: .public) overwrite=\(String(overwrite), privacy: .public)")
        do {
            if !overwrite && FileManager.default.fileExists(atPath: destination) {
                localMessage = "Local file already exists. Use Download Overwrite."
                Self.logger.warning("downloadItem blocked local exists destination=\(destination, privacy: .public)")
                addTransferRecord(
                    direction: .download,
                    source: item.absolutePath,
                    destination: destination,
                    result: .blocked,
                    message: "Local file already exists"
                )
                return
            }
            localMessage = ""
            Self.logger.debug("downloadItem executing sftp download item=\(item.absolutePath, privacy: .public)")
            try await SFTPService.shared.download(
                configuration: configuration,
                remotePath: item.absolutePath,
                localPath: destination
            )
            refreshLocal()
            Self.logger.info("downloadItem success item=\(item.absolutePath, privacy: .public) destination=\(destination, privacy: .public)")
            addTransferRecord(
                direction: .download,
                source: item.absolutePath,
                destination: destination,
                result: .success,
                message: overwrite ? "Download Overwrite" : "Download"
            )
        } catch {
            Self.logger.error("downloadItem failed item=\(item.absolutePath, privacy: .public) destination=\(destination, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            localMessage = error.localizedDescription
            addTransferRecord(
                direction: .download,
                source: item.absolutePath,
                destination: destination,
                result: .failed,
                message: error.localizedDescription
            )
        }
    }

    private func remoteFileExists(at path: String, configuration: NativeSSHConnectionConfiguration) async throws -> Bool {
        let normalized = normalizedRemotePath(path)
        guard let components = remotePathComponents(for: normalized) else {
            Self.logger.warning("remoteFileExists invalid path path=\(path, privacy: .public)")
            return false
        }
        let parent = normalizedRemotePath(components.directory)
        let name = components.name
        Self.logger.debug("remoteFileExists normalized=\(normalized, privacy: .public) parent=\(parent, privacy: .public) name=\(name, privacy: .public)")
        let entries = try await SFTPService.shared.listRemoteDirectory(
            configuration: configuration,
            path: parent
        )
        return entries.contains(where: { $0.name == name })
    }

    private func remotePathComponents(for path: String) -> (directory: String, name: String)? {
        let normalized = normalizedRemotePath(path)
        if normalized == "/" || normalized.isEmpty {
            return nil
        }
        guard let slash = normalized.lastIndex(of: "/") else {
            return ("/", normalized)
        }
        let name = String(normalized[normalized.index(after: slash)...])
        let directoryPrefix = String(normalized[..<slash])
        let directory = directoryPrefix.isEmpty ? "/" : directoryPrefix
        return (directory, name)
    }

    private func uploadDropped(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        Self.logger.debug("uploadDropped count=\(providers.count, privacy: .public)")
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                accepted = true
                let currentLocalPath = localPath
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    guard let url = Self.droppedURL(from: item) else {
                        Task { @MainActor in
                            addTransferRecord(
                                direction: .upload,
                                source: "<unsupported>",
                                destination: joinRemotePath(base: remotePath, child: "<unknown>"),
                                result: .failed,
                                message: "Drop source is not a valid file URL"
                            )
                        }
                        Self.logger.warning("uploadDropped unresolved fileURL item for path=\(currentLocalPath, privacy: .public)")
                        return
                    }
                    Self.logger.debug("uploadDropped resolved fileURL url=\(url.standardized.path, privacy: .public)")
                    Task { @MainActor in
                        await uploadDroppedFile(url)
                    }
                }
                continue
            }

            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                accepted = true
                let currentLocalPath = localPath
                provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
                    guard let url = Self.droppedURL(from: item) else {
                        Task { @MainActor in
                            addTransferRecord(
                                direction: .upload,
                                source: "<unsupported>",
                                destination: joinRemotePath(base: remotePath, child: "<unknown>"),
                                result: .failed,
                                message: "Drop source is not a valid file URL"
                            )
                        }
                        Self.logger.warning("uploadDropped unresolved url item for path=\(currentLocalPath, privacy: .public)")
                        return
                    }
                    Self.logger.debug("uploadDropped resolved URL item=\(url.standardized.path, privacy: .public)")
                    Task { @MainActor in
                        await uploadDroppedFile(url)
                    }
                }
                continue
            }

            if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                accepted = true
                provider.loadDataRepresentation(forTypeIdentifier: UTType.plainText.identifier) { data, _ in
                    guard let data,
                          let string = String(data: data, encoding: .utf8)?
                          .trimmingCharacters(in: .whitespacesAndNewlines),
                          !string.isEmpty
                    else {
                        return
                    }
                    let url = URL(string: string) ?? URL(fileURLWithPath: string)
                    guard url.isFileURL else {
                        Task { @MainActor in
                            addTransferRecord(
                                direction: .upload,
                                source: string,
                                destination: joinRemotePath(base: remotePath, child: "<unknown>"),
                                result: .failed,
                                message: "Drop source is not a file URL"
                            )
                        }
                        Self.logger.warning("uploadDropped plainText not fileURL value=\(string, privacy: .public)")
                        return
                    }
                    Self.logger.debug("uploadDropped resolved plainText url=\(url.standardized.path, privacy: .public)")
                    Task { @MainActor in
                        await uploadDroppedFile(url)
                    }
                }
            }
        }
        if !accepted {
            Self.logger.warning("uploadDropped no supported representation count=\(providers.count, privacy: .public)")
        }
        return accepted
    }

    private func downloadDroppedToLocal(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        Self.logger.debug("downloadDroppedToLocal count=\(providers.count, privacy: .public)")
        for provider in providers {
            final class SendableItemProvider: @unchecked Sendable {
                let provider: NSItemProvider

                init(_ provider: NSItemProvider) {
                    self.provider = provider
                }
            }

            final class DropResolutionGate: @unchecked Sendable {
                private let lock = NSLock()
                private var remoteHandled = false
                private var localFileHandled = false
                private var remotePayloadHandled = false
                private var pendingRemotePayloadChecks = 0

                func resetRemotePayloadChecks(count: Int) {
                    lock.lock()
                    pendingRemotePayloadChecks = count
                    remotePayloadHandled = false
                    lock.unlock()
                }

                func markRemoteHandled() -> Bool {
                    lock.lock()
                    defer { lock.unlock() }
                    if remoteHandled || localFileHandled {
                        return false
                    }
                    remoteHandled = true
                    return true
                }

                func markLocalFileHandled() -> Bool {
                    lock.lock()
                    defer { lock.unlock() }
                    if remoteHandled || localFileHandled {
                        return false
                    }
                    localFileHandled = true
                    return true
                }

                func markRemotePayloadHandled() -> Bool {
                    lock.lock()
                    defer { lock.unlock() }
                    if remotePayloadHandled || remoteHandled || localFileHandled {
                        return false
                    }
                    remotePayloadHandled = true
                    return true
                }

                func finishRemotePayloadCheck() -> Bool {
                    lock.lock()
                    defer { lock.unlock() }
                    if remotePayloadHandled {
                        return false
                    }
                    pendingRemotePayloadChecks -= 1
                    return pendingRemotePayloadChecks <= 0
                }
            }

            let sendableProvider = SendableItemProvider(provider)
            let resolutionGate = DropResolutionGate()

            @Sendable func copyLocalFile(_ sourceURL: URL, preferredName: String?, from sourceDescription: String) {
                if !resolutionGate.markLocalFileHandled() {
                    return
                }
                if self.isLikelyPlaceholderFileURL(sourceURL) {
                    Self.logger.warning("downloadDroppedToLocal blocked placeholder source from copyLocalFile=\(sourceURL.standardized.path, privacy: .public)")
                    requestRemotePayloadDownload(preferredName: preferredName) {
                        Task { @MainActor in
                            self.addTransferRecord(
                                direction: .download,
                                source: sourceDescription,
                                destination: URL(fileURLWithPath: localPath).appendingPathComponent(sourceDescription).path,
                                result: .failed,
                                message: "Drop source is not a valid local file"
                            )
                        }
                    }
                    return
                }
                do {
                    let destination = try self.copyDroppedFileToCurrentLocalDirectory(
                        sourceURL,
                        preferredName: preferredName
                    )
                    Task { @MainActor in
                        self.localMessage = ""
                        self.refreshLocal()
                        self.selectedLocalItemID = destination.path
                        self.addTransferRecord(
                            direction: .download,
                            source: sourceDescription,
                            destination: destination.path,
                            result: .success,
                            message: "Drag Download"
                        )
                    }
                    Self.logger.info("downloadDroppedToLocal copy success source=\(sourceURL.standardized.path, privacy: .public) destination=\(destination.path, privacy: .public)")
                } catch {
                    Self.logger.error("downloadDroppedToLocal copy failed source=\(sourceURL.standardized.path, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                    Task { @MainActor in
                        self.localMessage = error.localizedDescription
                        self.addTransferRecord(
                            direction: .download,
                            source: sourceDescription,
                            destination: URL(fileURLWithPath: localPath).appendingPathComponent(sourceDescription).path,
                            result: .failed,
                            message: error.localizedDescription
                        )
                    }
                }
            }

            let remotePayloadTypeIdentifiers = [
                Self.remoteDragPayloadTypeIdentifier,
                UTType.plainText.identifier,
                UTType.utf8PlainText.identifier,
                UTType.utf16PlainText.identifier,
                UTType.text.identifier
            ]

            @Sendable func requestRemotePayloadDownload(
                preferredName: String?,
                fallback: @MainActor @escaping @Sendable () -> Void
            ) {
                let payloadTypes = remotePayloadTypeIdentifiers
                Self.logger.debug("requestRemotePayloadDownload start remotePayloadTypes=\(payloadTypes.count, privacy: .public) path=\(localPath, privacy: .public)")
                if payloadTypes.isEmpty {
                    Task { @MainActor in
                        fallback()
                    }
                    return
                }
                resolutionGate.resetRemotePayloadChecks(count: payloadTypes.count)
                @Sendable func finishRemoteChecks() {
                    if resolutionGate.finishRemotePayloadCheck() {
                        Task { @MainActor in
                            fallback()
                        }
                    }
                }
                for payloadType in payloadTypes {
                    sendableProvider.provider.loadDataRepresentation(forTypeIdentifier: payloadType) { data, _ in
                        guard let data,
                              let string = String(data: data, encoding: .utf8)?
                                  .trimmingCharacters(in: .whitespacesAndNewlines),
                              !string.isEmpty
                        else {
                            Self.logger.debug("requestRemotePayloadDownload parse empty payload for type=\(payloadType, privacy: .public)")
                            finishRemoteChecks()
                            return
                        }
                        guard let remotePath = self.remoteDragPath(from: string) else {
                            Self.logger.debug("requestRemotePayloadDownload parsed unsupported payload type=\(payloadType, privacy: .public) value=\(string, privacy: .public)")
                            finishRemoteChecks()
                            return
                        }
                        Self.logger.debug("requestRemotePayloadDownload matched remote path=\(remotePath, privacy: .public) type=\(payloadType, privacy: .public)")
                        if !resolutionGate.markRemotePayloadHandled() {
                            return
                        }
                        if !resolutionGate.markRemoteHandled() {
                            return
                        }
                        Task { @MainActor in
                            await self.downloadDroppedRemotePath(
                                remotePath,
                                preferredName: preferredName
                            )
                        }
                    }
                }
            }

            func startLocalDownload() {
                if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                    let currentLocalPath = localPath
                    let preferredName = provider.suggestedName
                    provider.loadFileRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { [currentLocalPath, preferredName] fileURL, error in
                        if let fileURL, self.isLikelyPlaceholderFileURL(fileURL) {
                            Self.logger.warning("downloadDroppedToLocal placeholder fileURL via loadFileRepresentation=\(fileURL.standardized.path, privacy: .public)")
                            requestRemotePayloadDownload(preferredName: preferredName) {
                                Task { @MainActor in
                                    addTransferRecord(
                                        direction: .download,
                                        source: fileURL.path,
                                        destination: currentLocalPath,
                                        result: .failed,
                                        message: "Drop source is not a valid local file"
                                    )
                                }
                            }
                            return
                        }
                        if let fileURL, self.canUseDroppedLocalFile(fileURL) {
                            Self.logger.debug("downloadDroppedToLocal resolved fileURL via loadFileRepresentation=\(fileURL.standardized.path, privacy: .public)")
                            copyLocalFile(fileURL, preferredName: preferredName, from: fileURL.lastPathComponent)
                            return
                        }
                        let message = error?.localizedDescription ?? "No downloadable local file returned"
                        if let fileURL {
                            Self.logger.warning("downloadDroppedToLocal invalid fileURL via loadFileRepresentation path=\(fileURL.standardized.path, privacy: .public) error=\(message, privacy: .public)")
                        } else {
                            Self.logger.warning("downloadDroppedToLocal loadFileRepresentation failed fileURL error=\(message, privacy: .public)")
                        }
                        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                            guard let url = Self.droppedURL(from: item) else {
                                Self.logger.warning("downloadDroppedToLocal unresolved fileURL item for path=\(currentLocalPath, privacy: .public)")
                                requestRemotePayloadDownload(preferredName: preferredName) {
                                    Task { @MainActor in
                                        addTransferRecord(
                                            direction: .download,
                                            source: "<unsupported>",
                                            destination: currentLocalPath,
                                            result: .failed,
                                            message: "Drop source is not a valid file URL"
                                        )
                                    }
                                }
                                return
                            }
                            guard self.canUseDroppedLocalFile(url) else {
                                Self.logger.warning("downloadDroppedToLocal invalid loadItem fileURL path=\(url.standardized.path, privacy: .public)")
                                requestRemotePayloadDownload(preferredName: preferredName) {
                                    Task { @MainActor in
                                        addTransferRecord(
                                            direction: .download,
                                            source: url.path,
                                            destination: currentLocalPath,
                                            result: .failed,
                                            message: "Drop source is not a valid local file"
                                        )
                                    }
                                }
                                return
                            }
                            Self.logger.debug("downloadDroppedToLocal resolved fileURL via loadItem=\(url.standardized.path, privacy: .public)")
                            copyLocalFile(url, preferredName: preferredName, from: url.lastPathComponent)
                        }
                    }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                    let currentLocalPath = localPath
                    let preferredName = provider.suggestedName
                    provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
                        guard let url = Self.droppedURL(from: item) else {
                            Task { @MainActor in
                                addTransferRecord(
                                    direction: .download,
                                    source: "<unsupported>",
                                    destination: currentLocalPath,
                                    result: .failed,
                                    message: "Drop source is not a valid file URL"
                                )
                            }
                            Self.logger.warning("downloadDroppedToLocal unresolved URL item for path=\(currentLocalPath, privacy: .public)")
                            return
                        }
                        guard self.canUseDroppedLocalFile(url) else {
                            Self.logger.warning("downloadDroppedToLocal invalid URL item path=\(url.standardized.path, privacy: .public)")
                            requestRemotePayloadDownload(preferredName: preferredName) {
                                Task { @MainActor in
                                    addTransferRecord(
                                        direction: .download,
                                        source: url.path,
                                        destination: currentLocalPath,
                                        result: .failed,
                                        message: "Drop source is not a valid local file"
                                    )
                                }
                            }
                            return
                        }
                        Self.logger.debug("downloadDroppedToLocal resolved URL item=\(url.standardized.path, privacy: .public)")
                        Task { await self.downloadDroppedFileToLocal(url, preferredName: preferredName) }
                    }
                }
            }

            let hasRemotePayloadType = provider.registeredTypeIdentifiers.contains(Self.remoteDragPayloadTypeIdentifier)
            let hasRemoteTextPayload = remotePayloadTypeIdentifiers.contains(where: provider.hasItemConformingToTypeIdentifier)
            let hasLocalPayload = provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
                || provider.hasItemConformingToTypeIdentifier(UTType.url.identifier)
            let shouldAttemptRemotePayload = hasRemotePayloadType || hasRemoteTextPayload || hasLocalPayload
            if shouldAttemptRemotePayload {
                accepted = true
                let preferredName = provider.suggestedName
                requestRemotePayloadDownload(preferredName: preferredName) {
                    startLocalDownload()
                }
                continue
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                accepted = true
                startLocalDownload()
                continue
            }

            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                accepted = true
                startLocalDownload()
                continue
            }
        }
        if !accepted {
            Self.logger.warning("downloadDroppedToLocal no supported representation count=\(providers.count, privacy: .public)")
            addTransferRecord(
                direction: .download,
                source: "Unavailable source",
                destination: localPath,
                result: .failed,
                message: "Drop target does not provide a file URL"
            )
        }
        return accepted
    }

    private func downloadDroppedRemotePath(_ remotePath: String, preferredName: String? = nil) async {
        let destinationName = preferredName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let remoteFilename = URL(fileURLWithPath: remotePath).lastPathComponent
        let targetName = destinationName?.isEmpty == false ? destinationName! : remoteFilename
        guard let configuration = remoteConfiguration else {
            localMessage = "No remote configuration found"
            addTransferRecord(
                direction: .download,
                source: remotePath,
                destination: URL(fileURLWithPath: localPath).appendingPathComponent(targetName ?? "download").path,
                result: .failed,
                message: "No remote configuration found"
            )
            Self.logger.error("downloadDroppedRemotePath failed no remote config path=\(remotePath, privacy: .public)")
            return
        }
        let targetDirectory = URL(fileURLWithPath: localPath).standardizedFileURL
        let destination = localDestinationURL(in: targetDirectory, fileName: targetName ?? "download", overwriteExisting: true)
        Self.logger.info("downloadDroppedRemotePath start remotePath=\(remotePath, privacy: .public) destination=\(destination.path, privacy: .public)")
        do {
            try await SFTPService.shared.download(
                configuration: configuration,
                remotePath: remotePath,
                localPath: destination.path
            )
            localMessage = ""
            refreshLocal()
            addTransferRecord(
                direction: .download,
                source: remotePath,
                destination: destination.path,
                result: .success,
                message: "Drag Download"
            )
            selectedLocalItemID = destination.path
            Self.logger.info("downloadDroppedRemotePath success remotePath=\(remotePath, privacy: .public) destination=\(destination.path, privacy: .public)")
        } catch {
            localMessage = error.localizedDescription
            Self.logger.error("downloadDroppedRemotePath failed remotePath=\(remotePath, privacy: .public) destination=\(destination.path, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            addTransferRecord(
                direction: .download,
                source: remotePath,
                destination: destination.path,
                result: .failed,
                message: error.localizedDescription
            )
        }
    }

    private func isLikelyPlaceholderFileURL(_ url: URL) -> Bool {
        let lastComponent = url.lastPathComponent
        if lastComponent == "file URL" || lastComponent == "file" {
            return true
        }
        return url.path.contains(".com.apple.Foundation.NSItemProvider.")
    }

    private func canUseDroppedLocalFile(_ url: URL) -> Bool {
        guard url.isFileURL, !isLikelyPlaceholderFileURL(url) else {
            return false
        }
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return false
        }
        return true
    }

    nonisolated private static func droppedURL(from item: NSSecureCoding?) -> URL? {
        Self.logger.debug("droppedURL parse start itemClass=\(String(describing: type(of: item)), privacy: .public)")
        if let url = item as? URL { return url.standardized }
        if let url = item as? NSURL { return url.absoluteURL?.standardized }
        if let data = item as? Data {
            if let bookmarkURL = Self.urlFromSecurityScopedBookmark(data) {
                Self.logger.debug("droppedURL parse data bookmark URL=\(bookmarkURL.absoluteString, privacy: .public)")
                return bookmarkURL
            }
            if let unarchived = Self.urlFromUnarchivedData(data) {
                Self.logger.debug("droppedURL parse data unarchived URL=\(unarchived.absoluteString, privacy: .public)")
                return unarchived
            }

            let utf8String = String(data: data, encoding: .utf8)
            let utf16String = String(data: data, encoding: .utf16)
            let utf32String = String(data: data, encoding: .utf32)
            let trimmed = [utf8String, utf16String, utf32String]
                .compactMap { string in
                    string?.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                .first { !$0.isEmpty }

            guard let trimmed else {
                if let fallback = String(data: data, encoding: .isoLatin1)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !fallback.isEmpty {
                    Self.logger.warning("droppedURL parse data unsupported encoding fallback dataLength=\(data.count, privacy: .public)")
                    Self.logger.debug("droppedURL parse data fallback text=\(fallback, privacy: .public)")
                    if let directURL = URL(string: fallback), directURL.isFileURL {
                        return directURL.standardized
                    }
                    if fallback.hasPrefix("file://") || fallback.hasPrefix("/") {
                        return URL(fileURLWithPath: fallback).standardized
                    }
                }
                Self.logger.warning("droppedURL parse data not path-like dataLength=\(data.count, privacy: .public)")
                return nil
            }
            if let directURL = URL(string: trimmed), directURL.isFileURL {
                Self.logger.debug("droppedURL parse data direct URL=\(trimmed, privacy: .public)")
                return directURL.standardized
            }
            if trimmed.hasPrefix("file://"), let directURL = URL(string: trimmed) {
                Self.logger.debug("droppedURL parse data file scheme=\(trimmed, privacy: .public)")
                return directURL.standardized
            }
            if trimmed.hasPrefix("/") {
                let pathURL = URL(fileURLWithPath: trimmed).standardized
                if FileManager.default.fileExists(atPath: pathURL.path) {
                    Self.logger.debug("droppedURL parse data path text=\(trimmed, privacy: .public)")
                    return pathURL
                }
            }
            if trimmed.hasPrefix("~") {
                Self.logger.debug("droppedURL parse data tilde path not resolved locally trimmed=\(trimmed, privacy: .public)")
                return nil
            }
            if let dataURL = URL(dataRepresentation: data, relativeTo: nil), dataURL.isFileURL {
                Self.logger.debug("droppedURL parse data URL fallback dataLength=\(data.count, privacy: .public)")
                return dataURL.standardized
            }
            Self.logger.warning("droppedURL parse data not path-like dataLength=\(data.count, privacy: .public)")
            return nil
        }
        if let string = item as? NSString { return URL(fileURLWithPath: string as String).standardized }
        if let string = item as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            Self.logger.debug("droppedURL parse string=\(trimmed, privacy: .public)")
            return URL(string: trimmed) ?? URL(fileURLWithPath: trimmed)
        }
        Self.logger.warning("droppedURL parse unsupported item type")
        return nil
    }

    nonisolated private static func urlFromSecurityScopedBookmark(_ data: Data) -> URL? {
        var isStale = false
        let options: [URL.BookmarkResolutionOptions] = [[], [.withSecurityScope]]
        for option in options {
            if let bookmarkURL = try? URL(
                resolvingBookmarkData: data,
                options: option,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                return bookmarkURL.standardized
            }
        }
        return nil
    }

    nonisolated private static func urlFromUnarchivedData(_ data: Data) -> URL? {
        let url = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSURL.self, from: data)
        return url?.absoluteURL?.standardized
    }

    private func uploadDroppedFile(_ url: URL) async {
        let sourceURL = url.standardized
        let destination = joinRemotePath(base: remotePath, child: sourceURL.lastPathComponent)
        Self.logger.info("uploadDroppedFile start source=\(sourceURL.path, privacy: .public) destination=\(destination, privacy: .public)")
        guard let configuration = remoteConfiguration else {
            remoteMessage = "No remote configuration found"
            addTransferRecord(
                direction: .upload,
                source: sourceURL.path,
                destination: destination,
                result: .failed,
                message: "No remote configuration found"
            )
            return
        }
        do {
            let info = try sourceURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory ?? false
            if info {
                remoteMessage = "Cannot upload a directory"
                Self.logger.warning("uploadDroppedFile blocked directory source=\(sourceURL.path, privacy: .public)")
                addTransferRecord(
                    direction: .upload,
                    source: sourceURL.path,
                    destination: destination,
                    result: .failed,
                    message: "Cannot upload a directory"
                )
                return
            }
            guard FileManager.default.fileExists(atPath: sourceURL.path) else {
                remoteMessage = "Upload source file not found"
                Self.logger.error("uploadDroppedFile source missing source=\(sourceURL.path, privacy: .public)")
                addTransferRecord(
                    direction: .upload,
                    source: sourceURL.path,
                    destination: destination,
                    result: .failed,
                    message: "Upload source file not found"
                )
                return
            }
            Self.logger.debug("uploadDroppedFile uploading now source=\(sourceURL.path, privacy: .public)")
            try await SFTPService.shared.upload(
                configuration: configuration,
                localPath: sourceURL.path,
                remotePath: destination
            )
            await refreshRemote()
            Self.logger.info("uploadDroppedFile success source=\(sourceURL.path, privacy: .public) destination=\(destination, privacy: .public)")
            addTransferRecord(
                direction: .upload,
                source: sourceURL.path,
                destination: destination,
                result: .success,
                message: "Drag Upload"
            )
        } catch {
            remoteMessage = error.localizedDescription
            Self.logger.error("uploadDroppedFile failed source=\(sourceURL.path, privacy: .public) destination=\(destination, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            addTransferRecord(
                direction: .upload,
                source: sourceURL.path,
                destination: destination,
                result: .failed,
                message: error.localizedDescription
            )
        }
    }

    private func downloadDroppedFileToLocal(_ url: URL, preferredName: String? = nil) async {
        let sourceURL = url.standardized
        let destinationName = preferredName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let actualPreferredName = destinationName?.isEmpty == false ? destinationName : sourceURL.lastPathComponent
        Self.logger.info("downloadDroppedFileToLocal start source=\(sourceURL.path, privacy: .public) targetDir=\(localPath, privacy: .public)")
        do {
            let localURL = try copyDroppedFileToCurrentLocalDirectory(
                sourceURL,
                preferredName: actualPreferredName
            )
            DispatchQueue.main.async {
                localMessage = ""
                refreshLocal()
                selectedLocalItemID = localURL.path
            }
            Self.logger.info("downloadDroppedFileToLocal success source=\(sourceURL.path, privacy: .public) destination=\(localURL.path, privacy: .public)")
            addTransferRecord(
                direction: .download,
                source: sourceURL.lastPathComponent,
                destination: localURL.path,
                result: .success,
                message: "Drag Download"
            )
        } catch {
            DispatchQueue.main.async {
                localMessage = error.localizedDescription
            }
            Self.logger.error("downloadDroppedFileToLocal failed source=\(sourceURL.path, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            addTransferRecord(
                direction: .download,
                source: sourceURL.path,
                destination: URL(fileURLWithPath: localPath).appendingPathComponent(sourceURL.lastPathComponent).path,
                result: .failed,
                message: error.localizedDescription
            )
        }
    }

    private func copyDroppedFileToCurrentLocalDirectory(_ source: URL, preferredName: String? = nil) throws -> URL {
        Self.logger.debug("copyDroppedFileToCurrentLocalDirectory source=\(source.path, privacy: .public) preferredName=\(preferredName ?? "", privacy: .public) targetDir=\(localPath, privacy: .public)")
        guard source.isFileURL else {
            throw NSError(domain: "SFTPPanel", code: 3, userInfo: [NSLocalizedDescriptionKey: "Dropped item is not a file URL"])
        }
        let targetDirectory = URL(fileURLWithPath: localPath).standardizedFileURL
        let destination = localDestinationURL(
            in: targetDirectory,
            fileName: preferredName?.isEmpty == false ? preferredName! : source.lastPathComponent,
            overwriteExisting: true
        )
        Self.logger.debug("copyDroppedFile destination candidate=\(destination.path, privacy: .public)")
        var isDirectory = ObjCBool(false)
        if FileManager.default.fileExists(atPath: destination.path) {
            if FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                Self.logger.error("copyDroppedFile target is directory destination=\(destination.path, privacy: .public)")
                throw NSError(domain: "SFTPPanel", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot overwrite directory"])
            }
            Self.logger.debug("copyDroppedFile remove existing file destination=\(destination.path, privacy: .public)")
            try FileManager.default.removeItem(at: destination)
        }
        let info = try source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory ?? false
        if info {
            Self.logger.warning("copyDroppedFile source is directory source=\(source.path, privacy: .public)")
            throw NSError(domain: "SFTPPanel", code: 2, userInfo: [NSLocalizedDescriptionKey: "Directory drag not supported"])
        }
        Self.logger.debug("copyDroppedFile copy start source=\(source.path, privacy: .public) destination=\(destination.path, privacy: .public)")
        try FileManager.default.copyItem(at: source, to: destination)
        Self.logger.info("copyDroppedFile success source=\(source.path, privacy: .public) destination=\(destination.path, privacy: .public)")
        return destination
    }

    private func copyDroppedDataToCurrentLocalDirectory(_ data: Data, preferredName: String? = nil) throws -> URL {
        let fileName = preferredName?.isEmpty == false ? preferredName! : "download"
        let targetDirectory = URL(fileURLWithPath: localPath).standardizedFileURL
        let destination = localDestinationURL(in: targetDirectory, fileName: fileName, overwriteExisting: true)
        Self.logger.debug("copyDroppedDataToCurrentLocalDirectory destination=\(destination.path, privacy: .public) size=\(data.count, privacy: .public)")
        var isDirectory = ObjCBool(false)
        if FileManager.default.fileExists(atPath: destination.path) {
            if FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                Self.logger.error("copyDroppedData target is directory destination=\(destination.path, privacy: .public)")
                throw NSError(domain: "SFTPPanel", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot overwrite directory"])
            }
            Self.logger.debug("copyDroppedData remove existing file destination=\(destination.path, privacy: .public)")
            try FileManager.default.removeItem(at: destination)
        }
        try data.write(to: destination, options: .atomic)
        Self.logger.info("copyDroppedDataToCurrentLocalDirectory success destination=\(destination.path, privacy: .public)")
        return destination
    }

    private func downloadDroppedDataToLocal(_ data: Data, preferredName: String?) async {
        Self.logger.info("downloadDroppedDataToLocal start size=\(data.count, privacy: .public) targetDir=\(localPath, privacy: .public)")
        do {
            let localURL = try copyDroppedDataToCurrentLocalDirectory(
                data,
                preferredName: preferredName
            )
            DispatchQueue.main.async {
                localMessage = ""
                refreshLocal()
                selectedLocalItemID = localURL.path
            }
            Self.logger.info("downloadDroppedDataToLocal success destination=\(localURL.path, privacy: .public)")
            addTransferRecord(
                direction: .download,
                source: preferredName ?? "clipboard",
                destination: localURL.path,
                result: .success,
                message: "Drag Download"
            )
        } catch {
            DispatchQueue.main.async {
                localMessage = error.localizedDescription
            }
            Self.logger.error("downloadDroppedDataToLocal failed targetDir=\(localPath, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            addTransferRecord(
                direction: .download,
                source: preferredName ?? "clipboard",
                destination: URL(fileURLWithPath: localPath).appendingPathComponent(preferredName ?? "download").path,
                result: .failed,
                message: error.localizedDescription
            )
        }
    }

    private func localDestinationURL(in directory: URL, fileName: String, overwriteExisting: Bool = false) -> URL {
        let sanitizedFileName = fileName.isEmpty ? "download" : fileName
        let candidate = directory.appendingPathComponent(sanitizedFileName)
        if overwriteExisting || !FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }

        let base = candidate.deletingPathExtension()
        let ext = candidate.pathExtension
        var index = 1
        while true {
            let indexedName = ext.isEmpty ? "\(base.lastPathComponent)-\(index)" : "\(base.lastPathComponent)-\(index).\(ext)"
            let indexedURL = directory.appendingPathComponent(indexedName)
            if !FileManager.default.fileExists(atPath: indexedURL.path) {
                return indexedURL
            }
            index += 1
        }
    }

    private func localRootPath() -> String {
        guard let project = activeProject,
              let key = appState.activeWorktreeKey(for: project.id),
              let worktree = worktreeStore.worktree(projectID: project.id, worktreeID: key.worktreeID)
        else {
            return existingDirectoryOrHome(activeProject?.path ?? NSHomeDirectory())
        }
        return existingDirectoryOrHome(worktree.path)
    }

    private func existingDirectoryOrHome(_ path: String) -> String {
        var isDirectory = ObjCBool(false)
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
            return path
        }
        return NSHomeDirectory()
    }

    private func hasLocalParent(_ path: String) -> Bool {
        normalizedLocalPath(path) != "/"
    }

    private func normalizedLocalPath(_ path: String) -> String {
        let normalized = URL(fileURLWithPath: path.isEmpty ? "/" : path).standardized.path
        return normalized.isEmpty ? "/" : normalized
    }

    private func remoteRootPath() -> String {
        remoteConfiguration?.remotePath ?? "/"
    }

    private func fileList(
        title: String,
        path: String,
        items: [SFTPFileItem],
        loading: Bool,
        message: String,
        selectedID: String?,
        showUpButton: Bool,
        onUp: @escaping () -> Void,
        onSelect: @escaping (SFTPFileItem) -> Void,
        onOpen: @escaping (SFTPFileItem) -> Void,
        onDrop: (([NSItemProvider]) -> Bool)? = nil,
        isDropTarget: Binding<Bool>? = nil,
        dragProvider: ((SFTPFileItem) -> NSItemProvider)? = nil,
        onUpload: ((SFTPFileItem) -> Void)? = nil,
        onUploadOverwrite: ((SFTPFileItem) -> Void)? = nil,
        onDownload: ((SFTPFileItem) -> Void)? = nil,
        onDownloadOverwrite: ((SFTPFileItem) -> Void)? = nil
    ) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: UIMetrics.spacing2) {
                Text(title)
                    .font(.system(size: UIMetrics.fontBody, weight: .medium))
                Spacer()
                if loading {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, UIMetrics.spacing3)
            .padding(.vertical, UIMetrics.spacing2)

            Divider().overlay(MuxyTheme.border)

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    if showUpButton {
                        fileRow(
                            item: SFTPFileItem(
                                name: "..",
                                absolutePath: "",
                                isDirectory: true,
                                size: 0,
                                modified: nil
                            ),
                            isSelected: false,
                            onSelect: onUp,
                            onOpen: onUp
                        )
                    }
                    ForEach(items) { item in
                        let selected = item.id == selectedID
                        fileRow(
                            item: item,
                            isSelected: selected,
                            onSelect: { onSelect(item) },
                            onOpen: { onOpen(item) },
                            onDragProvider: dragProvider?(item),
                            onUpload: onUpload,
                            onUploadOverwrite: onUploadOverwrite,
                            onDownload: onDownload,
                            onDownloadOverwrite: onDownloadOverwrite
                        )
                    }
                    if items.isEmpty && !loading {
                        Text(message.isEmpty ? "Empty directory" : message)
                            .foregroundStyle(MuxyTheme.fgMuted)
                            .font(.system(size: UIMetrics.fontFootnote))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, UIMetrics.spacing3)
                            .padding(.vertical, UIMetrics.spacing4)
                    }
                }
                .padding(.vertical, UIMetrics.spacing1)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity)
        .onDrop(
            of: [UTType.fileURL, UTType.url, UTType.plainText, UTType.text],
            isTargeted: isDropTarget,
            perform: { providers in onDrop?(providers) ?? false }
        )
    }

    private func fileRow(
        item: SFTPFileItem,
        isSelected: Bool,
        onSelect: @escaping () -> Void,
        onOpen: @escaping () -> Void,
        onDragProvider: NSItemProvider? = nil,
        onUpload: ((SFTPFileItem) -> Void)? = nil,
        onUploadOverwrite: ((SFTPFileItem) -> Void)? = nil,
        onDownload: ((SFTPFileItem) -> Void)? = nil,
        onDownloadOverwrite: ((SFTPFileItem) -> Void)? = nil
    ) -> some View {
        HStack(spacing: UIMetrics.spacing3) {
            Image(systemName: item.isDirectory ? "folder" : "doc")
                .font(.system(size: 11))
                .foregroundStyle(item.isDirectory ? MuxyTheme.accent : MuxyTheme.fgMuted)
                .frame(width: UIMetrics.iconMD)
            VStack(alignment: .leading, spacing: UIMetrics.spacing1) {
                HStack(spacing: UIMetrics.spacing2) {
                    Text(item.name)
                        .font(.system(size: UIMetrics.fontFootnote, weight: .medium))
                        .foregroundStyle(MuxyTheme.fg)
                        .lineLimit(1)
                    Spacer(minLength: UIMetrics.spacing1)
                    if !item.isDirectory {
                        Text(fileSizeLabel(item.size))
                            .font(.system(size: UIMetrics.fontCaption))
                            .foregroundStyle(MuxyTheme.fgMuted)
                    }
                }
            Text(item.modified.map { dateFormatter.string(from: $0) } ?? "")
                    .font(.system(size: UIMetrics.fontCaption))
                    .foregroundStyle(MuxyTheme.fgMuted)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, UIMetrics.spacing3)
        .padding(.vertical, UIMetrics.spacing2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? MuxyTheme.accentSoft : .clear)
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .onTapGesture(count: 2) { onOpen() }
        .onDrag {
            onDragProvider ?? NSItemProvider()
        }
        .contextMenu {
            if !item.isDirectory {
                if let action = onUpload {
                    Button("上传") {
                        action(item)
                    }
                }
                if let action = onUploadOverwrite {
                    Button("上传覆盖") {
                        action(item)
                    }
                }
                if let action = onDownload {
                    Button("下载") {
                        action(item)
                    }
                }
                if let action = onDownloadOverwrite {
                    Button("下载覆盖") {
                        action(item)
                    }
                }
            }
        }
    }

    private func iconButton(symbol: String, label: String, action: @escaping () -> Void, isDisabled: Bool = false) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(MuxyTheme.fgMuted)
                .frame(width: UIMetrics.iconMD, height: UIMetrics.iconMD)
                .help(label)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .help(label)
    }

    private var transferHistorySection: some View {
        VStack(spacing: 0) {
            HStack(spacing: UIMetrics.spacing2) {
                Text("Transfer History")
                    .font(.system(size: UIMetrics.fontFootnote, weight: .semibold))
                    .foregroundStyle(MuxyTheme.fgMuted)
                Spacer()
                Button("Clear") {
                    transferHistory.removeAll()
                }
                .buttonStyle(.plain)
                .font(.system(size: UIMetrics.fontCaption, weight: .medium))
                .foregroundStyle(MuxyTheme.fgMuted)
                .disabled(transferHistory.isEmpty)
            }
            .padding(.horizontal, UIMetrics.spacing3)
            .padding(.vertical, UIMetrics.spacing2)

            Divider().overlay(MuxyTheme.border)

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    ForEach(transferHistory) { record in
                        transferHistoryRow(record)
                    }
                    if transferHistory.isEmpty {
                        Text("No transfer yet")
                            .foregroundStyle(MuxyTheme.fgMuted)
                            .font(.system(size: UIMetrics.fontCaption))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, UIMetrics.spacing3)
                            .padding(.vertical, UIMetrics.spacing3)
                    }
                }
                .padding(.vertical, UIMetrics.spacing1)
            }
            .frame(minHeight: UIMetrics.scaled(190))
        }
        .frame(maxWidth: .infinity)
    }

    private func transferHistoryRow(_ record: SFTPTransferRecord) -> some View {
        HStack(spacing: UIMetrics.spacing3) {
            Image(systemName: transferHistoryIcon(for: record))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(transferHistoryColor(for: record))
                .frame(width: UIMetrics.iconMD)
            VStack(alignment: .leading, spacing: UIMetrics.spacing1) {
                HStack(spacing: UIMetrics.spacing2) {
                    Text("\(record.direction.rawValue) · \(record.result.rawValue)")
                        .font(.system(size: UIMetrics.fontCaption))
                        .foregroundStyle(MuxyTheme.fg)
                    Spacer(minLength: UIMetrics.spacing1)
                    Text(transferHistoryDateFormatter.string(from: record.timestamp))
                        .font(.system(size: UIMetrics.fontCaption))
                        .foregroundStyle(MuxyTheme.fgMuted)
                }
                Text("\(record.source) -> \(record.destination)")
                    .font(.system(size: UIMetrics.fontCaption))
                    .foregroundStyle(MuxyTheme.fgMuted)
                    .lineLimit(1)
                if !record.message.isEmpty {
                    Text(record.message)
                        .font(.system(size: UIMetrics.fontCaption))
                        .foregroundStyle(MuxyTheme.fgMuted)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, UIMetrics.spacing3)
        .padding(.vertical, UIMetrics.spacing2)
    }

    private var selectedLocalItem: SFTPFileItem? {
        localItems.first(where: { $0.id == selectedLocalItemID })
    }

    private var selectedRemoteItem: SFTPFileItem? {
        remoteItems.first(where: { $0.id == selectedRemoteItemID })
    }

    private var activeProject: Project? {
        guard let activeID = appState.activeProjectID else { return nil }
        return projectStore.projects.first(where: { $0.id == activeID })
    }

    private var remoteConfiguration: NativeSSHConnectionConfiguration? {
        guard let projectID = appState.activeProjectID,
              let tab = appState.activeTab(for: projectID),
              let pane = tab.content.pane,
              let config = pane.nativeSSHConfiguration
        else { return nil }
        return config
    }

    private func fileSizeLabel(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    private func normalizedRemotePath(_ path: String) -> String {
        var normalized = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty { return "/" }
        while normalized.count > 1 && normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }

    private func joinRemotePath(base: String, child: String) -> String {
        if base == "/" { return "/\(child)" }
        if base.hasSuffix("/") { return "\(base)\(child)" }
        return "\(base)/\(child)"
    }

    private var dateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }

    private var transferHistoryDateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }

    private func transferHistoryIcon(for record: SFTPTransferRecord) -> String {
        if record.result == .failed {
            return "xmark.octagon.fill"
        }
        if record.result == .blocked {
            return "exclamationmark.triangle.fill"
        }
        return record.direction == .upload ? "arrow.up.to.line.compact" : "arrow.down.to.line.compact"
    }

    private func transferHistoryColor(for record: SFTPTransferRecord) -> Color {
        switch record.result {
        case .success:
            return record.direction == .upload ? MuxyTheme.accent : MuxyTheme.accentSoft
        case .blocked:
            return MuxyTheme.warning
        case .failed:
            return MuxyTheme.warning
        }
    }

    private func addTransferRecord(
        direction: SFTPTransferDirection,
        source: String,
        destination: String,
        result: SFTPTransferResult,
        message: String
    ) {
        Self.logger.debug("addTransferRecord direction=\(String(describing: direction), privacy: .public) result=\(String(describing: result), privacy: .public) source=\(source, privacy: .public) destination=\(destination, privacy: .public) message=\(message, privacy: .public)")
        let record = SFTPTransferRecord(
            direction: direction,
            source: source,
            destination: destination,
            result: result,
            message: message,
            timestamp: Date()
        )
        transferHistory.insert(record, at: 0)
        if transferHistory.count > maxTransferHistoryEntries {
            transferHistory.removeLast(transferHistory.count - maxTransferHistoryEntries)
        }
    }

}
