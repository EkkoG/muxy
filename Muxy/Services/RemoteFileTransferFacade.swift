import Foundation
import MuxySSH

protocol RemoteFileTransfering: Sendable {
    func localEntries(at path: String) -> [RemoteFileBrowserItem]
    func listRemoteDirectory(
        configuration: SSHConnectionConfiguration,
        path: String
    ) async throws -> [RemoteFileBrowserItem]
    func download(
        configuration: SSHConnectionConfiguration,
        remotePath: String,
        localPath: String
    ) async throws
    func upload(
        configuration: SSHConnectionConfiguration,
        localPath: String,
        remotePath: String
    ) async throws
}

final class RemoteFileTransferFacade: RemoteFileTransfering, @unchecked Sendable {
    static let shared = RemoteFileTransferFacade()

    private let service: RemoteFileTransferService

    init(service: RemoteFileTransferService = .shared) {
        self.service = service
    }

    func localEntries(at path: String) -> [RemoteFileBrowserItem] {
        service.localEntries(at: path).map(Self.map)
    }

    func listRemoteDirectory(
        configuration: SSHConnectionConfiguration,
        path: String
    ) async throws -> [RemoteFileBrowserItem] {
        try await service.listRemoteDirectory(configuration: configuration, path: path).map(Self.map)
    }

    func download(
        configuration: SSHConnectionConfiguration,
        remotePath: String,
        localPath: String
    ) async throws {
        try await service.download(
            configuration: configuration,
            remotePath: remotePath,
            localPath: localPath
        )
    }

    func upload(
        configuration: SSHConnectionConfiguration,
        localPath: String,
        remotePath: String
    ) async throws {
        try await service.upload(
            configuration: configuration,
            localPath: localPath,
            remotePath: remotePath
        )
    }

    private static func map(_ item: RemoteFileTransferItem) -> RemoteFileBrowserItem {
        RemoteFileBrowserItem(
            id: item.id,
            name: item.name,
            absolutePath: item.absolutePath,
            isDirectory: item.isDirectory,
            size: item.size,
            modified: item.modified
        )
    }
}
