import Foundation
import os

private let logger = Logger(subsystem: "app.muxy", category: "RemoteHostStore")

enum RemoteHostStoreError: LocalizedError {
    case unsupportedImportFormat

    var errorDescription: String? {
        switch self {
        case .unsupportedImportFormat:
            return "The imported file format is unsupported."
        }
    }
}

@MainActor
@Observable
final class RemoteHostStore {
    static let shared = RemoteHostStore()

    private(set) var hosts: [RemoteHost] = []
    private let persistence: CodableFileStore<[RemoteHost]>
    private let sshConfigDiscoverer: SSHConfigHostDiscovering

    private static var storageURL: URL {
        MuxyFileStorage.appSupportDirectory().appendingPathComponent("remote-hosts.json")
    }

    init(sshConfigDiscoverer: SSHConfigHostDiscovering = DefaultSSHConfigHostDiscoverer()) {
        self.sshConfigDiscoverer = sshConfigDiscoverer
        persistence = CodableFileStore(fileURL: Self.storageURL, options: .prettySorted)
        load()
    }

    init(storageURL: URL, sshConfigDiscoverer: SSHConfigHostDiscovering = DefaultSSHConfigHostDiscoverer()) {
        self.sshConfigDiscoverer = sshConfigDiscoverer
        self.persistence = CodableFileStore(fileURL: storageURL, options: .prettySorted)
        load()
    }

    private func load() {
        do {
            hosts = try persistence.load() ?? []
        } catch {
            logger.error("Failed to load remote hosts: \(error)")
            hosts = []
        }
    }

    private func save() {
        do {
            let configDir = Self.storageURL.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: configDir.path) {
                try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
            }
            try persistence.save(hosts)
        } catch {
            logger.error("Failed to save remote hosts: \(error)")
        }
    }

    func add(_ host: RemoteHost) {
        guard !contains(host.connectionIdentity) else { return }
        hosts.append(host)
        save()
    }

    func update(_ host: RemoteHost) {
        guard let index = hosts.firstIndex(where: { $0.id == host.id }) else { return }
        var updated = host
        updated.updatedAt = Date()
        hosts[index] = updated
        save()
    }

    func remove(id: UUID) {
        hosts.removeAll { $0.id == id }
        save()
    }

    func find(byID id: UUID) -> RemoteHost? {
        hosts.first { $0.id == id }
    }

    func find(by identity: RemoteConnectionIdentity) -> RemoteHost? {
        hosts.first { $0.connectionIdentity == identity }
    }

    func importFromSSHConfig() -> [RemoteHost] {
        let parsed = discoverSSHConfigHosts()
        let hosts = parsed.map {
            RemoteHost(
                name: $0.name,
                host: $0.hostName,
                port: $0.port,
                user: $0.user ?? NSUserName(),
                identityFile: $0.identityFile
            )
        }
        return importHosts(hosts)
    }

    func discoverSSHConfigHosts() -> [DiscoveredSSHConfigHost] {
        sshConfigDiscoverer.discoverHosts(configPath: nil)
    }

    func exportData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(hosts)
    }

    func export(to url: URL) throws {
        let data = try exportData()
        try data.write(to: url, options: .atomic)
    }

    func importFromJSON(_ url: URL) throws -> [RemoteHost] {
        let data = try Data(contentsOf: url)
        return try importFromData(data)
    }

    func importFromData(_ data: Data) throws -> [RemoteHost] {
        let decoder = JSONDecoder()
        do {
            return importHosts(try decoder.decode([RemoteHost].self, from: data))
        } catch {
            guard
                let payload = try? decoder.decode([String: [RemoteHost]].self, from: data),
                let hosts = payload["hosts"]
            else {
                throw RemoteHostStoreError.unsupportedImportFormat
            }
            return importHosts(hosts)
        }
    }

    func ensureControlDir() {
        let controlDir = RemoteHost.controlPathBase()
        let controlURL = URL(fileURLWithPath: controlDir)
        guard !FileManager.default.fileExists(atPath: controlDir) else { return }
        do {
            try FileManager.default.createDirectory(at: controlURL, withIntermediateDirectories: true)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: controlDir
            )
        } catch {
            logger.error("Failed to create control dir: \(error)")
        }
    }

    private func importHosts(_ hosts: [RemoteHost]) -> [RemoteHost] {
        var imported: [RemoteHost] = []
        for host in hosts where !contains(host.connectionIdentity) {
            self.hosts.append(host)
            imported.append(host)
        }
        if !imported.isEmpty {
            save()
        }
        return imported
    }

    private func contains(_ host: RemoteHost) -> Bool {
        contains(host.connectionIdentity)
    }

    func hasMatch(_ identity: RemoteConnectionIdentity) -> Bool {
        contains(identity)
    }

    private func contains(_ identity: RemoteConnectionIdentity) -> Bool {
        self.hosts.contains {
            $0.connectionIdentity == identity
        }
    }

    func hasMatch(host: String, user: String, port: UInt16) -> Bool {
        let normalized = RemoteConnectionIdentity(host: host, user: user, port: port)
        return hosts.contains {
            $0.connectionIdentity.host == normalized.host &&
            $0.connectionIdentity.user == normalized.user &&
            $0.connectionIdentity.port == normalized.port
        }
    }
}
