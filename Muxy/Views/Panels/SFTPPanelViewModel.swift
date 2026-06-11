import Foundation
import SwiftUI
import os

@MainActor
@Observable
final class SFTPPanelViewModel {
    nonisolated private static let logger = Logger(subsystem: "app.muxy", category: "SFTPPanelViewModel")

    nonisolated private static let remoteDragPayloadPrefix = "muxy-sftp-remote-path:"
    nonisolated static let remoteDragPayloadTypeIdentifier = "com.muxy.sftp.remote-path"

    private(set) var localPath: String = NSHomeDirectory()
    private(set) var remotePath: String = "/"
    private(set) var localItems: [RemoteFileBrowserItem] = []
    private(set) var remoteItems: [RemoteFileBrowserItem] = []
    private(set) var localLoading = false
    private(set) var remoteLoading = false
    private(set) var localMessage = ""
    private(set) var remoteMessage = ""
    private(set) var selectedLocalItemID: String?
    private(set) var selectedRemoteItemID: String?
    private(set) var remoteConfiguration: SSHConnectionConfiguration?
    let transferHistoryStore = SFTPPanelTransferHistory()
    private let transferService: RemoteFileTransfering

    init(transferService: RemoteFileTransfering = RemoteFileTransferFacade.shared) {
        self.transferService = transferService
    }

    func syncContext(
        localRootPath: String,
        remoteRootPath: String,
        configuration: SSHConnectionConfiguration?
    ) {
        remoteConfiguration = configuration
        let nextLocalPath = normalizedLocalPath(localRootPath)
        if localPath != nextLocalPath {
            localPath = nextLocalPath
            selectedLocalItemID = nil
        }
        refreshLocal()
        let nextRemotePath = normalizedRemotePath(remoteRootPath)
        if remotePath != nextRemotePath {
            remotePath = nextRemotePath
            selectedRemoteItemID = nil
        }
        Task { await refreshRemote() }
    }

    func refreshBoth() {
        refreshLocal()
        Task { await refreshRemote() }
    }

    func refreshLocal() {
        localLoading = true
        localMessage = ""
        defer {
            localLoading = false
            if localItems.isEmpty {
                localMessage = localMessage.isEmpty ? "Directory is empty" : localMessage
            }
            Self.logger.debug("refreshLocal done path=\(self.localPath, privacy: .public) count=\(self.localItems.count, privacy: .public) message=\(self.localMessage, privacy: .public)")
        }

        let target = normalizedLocalPath(localPath)
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: target, isDirectory: &isDirectory) else {
            localItems = []
            localMessage = "Directory does not exist"
            return
        }
        guard isDirectory.boolValue else {
            localItems = []
            localMessage = "Not a directory"
            return
        }
        localItems = transferService.localEntries(at: target)
    }

    func refreshRemote() async {
        guard let configuration = remoteConfiguration else {
            remoteItems = []
            remoteMessage = "No remote configuration found"
            remoteLoading = false
            return
        }
        remoteLoading = true
        remoteMessage = ""
        defer { remoteLoading = false }
        do {
            remoteItems = try await transferService.listRemoteDirectory(
                configuration: configuration,
                path: remotePath
            )
        } catch {
            remoteItems = []
            remoteMessage = error.localizedDescription
        }
    }

    func selectLocalItem(_ item: RemoteFileBrowserItem) {
        selectedLocalItemID = item.id
    }

    func selectRemoteItem(_ item: RemoteFileBrowserItem) {
        selectedRemoteItemID = item.id
    }

    func openLocalItem(_ item: RemoteFileBrowserItem) {
        if item.isDirectory {
            selectedLocalItemID = nil
            localPath = item.absolutePath
        }
    }

    func openRemoteItem(_ item: RemoteFileBrowserItem) {
        if item.isDirectory {
            selectedRemoteItemID = nil
            remotePath = item.absolutePath
        }
    }

    func navigateLocalParent() {
        let parent = URL(fileURLWithPath: localPath).deletingLastPathComponent().path
        if parent != localPath {
            selectedLocalItemID = nil
            localPath = parent
        }
    }

    func navigateRemoteParent() {
        let normalized = normalizedRemotePath(remotePath)
        if normalized == "/" { return }
        selectedRemoteItemID = nil
        remotePath = normalizedRemotePath(URL(fileURLWithPath: normalized).deletingLastPathComponent().path)
    }

    func clearLocalSelection() {
        selectedLocalItemID = nil
    }

    func clearRemoteSelection() {
        selectedRemoteItemID = nil
    }

    func uploadSelected() async {
        guard let source = selectedLocalItem, remoteConfiguration != nil else { return }
        if source.isDirectory { return }
        await uploadItem(source, overwrite: true)
    }

    func uploadItem(_ item: RemoteFileBrowserItem, overwrite: Bool) async {
        guard let config = remoteConfiguration else {
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
                if try await remoteFileExists(at: destination, configuration: config) {
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
            remoteMessage = ""
            try await transferService.upload(
                configuration: config,
                localPath: sourcePath,
                remotePath: destination
            )
            await refreshRemote()
            addTransferRecord(
                direction: .upload,
                source: sourcePath,
                destination: destination,
                result: .success,
                message: overwrite ? "Upload Overwrite" : "Upload"
            )
        } catch {
            remoteMessage = error.localizedDescription
            addTransferRecord(
                direction: .upload,
                source: sourcePath,
                destination: destination,
                result: .failed,
                message: error.localizedDescription
            )
        }
    }

    func downloadSelected() async {
        guard let config = remoteConfiguration else {
            localMessage = "No remote configuration found"
            return
        }
        guard let item = selectedRemoteItem else {
            localMessage = "No remote file selected"
            return
        }
        if item.isDirectory { return }
        await downloadItem(item, overwrite: true, configuration: config)
    }

    func downloadItem(_ item: RemoteFileBrowserItem, overwrite: Bool) async {
        await downloadItem(item, overwrite: overwrite, configuration: remoteConfiguration)
    }

    private func downloadItem(_ item: RemoteFileBrowserItem, overwrite: Bool, configuration: SSHConnectionConfiguration?) async {
        guard let configuration else {
            localMessage = "No remote configuration found"
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
        do {
            if !overwrite && FileManager.default.fileExists(atPath: destination) {
                localMessage = "Local file already exists. Use Download Overwrite."
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
            try await transferService.download(
                configuration: configuration,
                remotePath: item.absolutePath,
                localPath: destination
            )
            refreshLocal()
            addTransferRecord(
                direction: .download,
                source: item.absolutePath,
                destination: destination,
                result: .success,
                message: overwrite ? "Download Overwrite" : "Download"
            )
        } catch {
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

    private func remoteFileExists(
        at path: String,
        configuration: SSHConnectionConfiguration
    ) async throws -> Bool {
        let normalized = normalizedRemotePath(path)
        guard let components = remotePathComponents(for: normalized) else { return false }
        let parent = normalizedRemotePath(components.directory)
        let name = components.name
        let entries = try await transferService.listRemoteDirectory(
            configuration: configuration,
            path: parent
        )
        return entries.contains(where: { $0.name == name })
    }

    private func remotePathComponents(for path: String) -> (directory: String, name: String)? {
        let normalized = normalizedRemotePath(path)
        if normalized == "/" || normalized.isEmpty { return nil }
        guard let slash = normalized.lastIndex(of: "/") else { return ("/", normalized) }
        let name = String(normalized[normalized.index(after: slash)...])
        let directoryPrefix = String(normalized[..<slash])
        let directory = directoryPrefix.isEmpty ? "/" : directoryPrefix
        return (directory, name)
    }

    func localDestinationURL(in directory: URL, fileName: String, overwriteExisting: Bool = false) -> URL {
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

    func hasLocalParent(_ path: String) -> Bool {
        normalizedLocalPath(path) != "/"
    }

    func normalizedLocalPath(_ path: String) -> String {
        let normalized = URL(fileURLWithPath: path.isEmpty ? "/" : path).standardized.path
        return normalized.isEmpty ? "/" : normalized
    }

    func normalizedRemotePath(_ path: String) -> String {
        var normalized = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty { return "/" }
        while normalized.count > 1 && normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }

    var selectedLocalItem: RemoteFileBrowserItem? {
        localItems.first(where: { $0.id == selectedLocalItemID })
    }

    var selectedRemoteItem: RemoteFileBrowserItem? {
        remoteItems.first(where: { $0.id == selectedRemoteItemID })
    }

    private func joinRemotePath(base: String, child: String) -> String {
        if base == "/" { return "/\(child)" }
        if base.hasSuffix("/") { return "\(base)\(child)" }
        return "\(base)/\(child)"
    }

    private func addTransferRecord(
        direction: SFTPTransferDirection,
        source: String,
        destination: String,
        result: SFTPTransferResult,
        message: String
    ) {
        transferHistoryStore.append(
            direction: direction,
            source: source,
            destination: destination,
            result: result,
            message: message
        )
    }
}
