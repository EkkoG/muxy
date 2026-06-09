import Foundation
import Testing

@testable import Muxy

@Suite("RemoteHostStore")
@MainActor
struct RemoteHostStoreTests {
    @Test("export imports and round-trips SSH hosts")
    func exportRoundTrip() throws {
        let storeURL = tempURL()
        let exportURL = tempURL()
        let source = RemoteHostStore(storageURL: storeURL)

        let host = RemoteHost(
            name: "example",
            host: "example.com",
            port: 2222,
            user: "deploy"
        )

        source.add(host)

        try source.export(to: exportURL)

        let importedStore = RemoteHostStore(storageURL: tempURL())
        _ = try importedStore.importFromJSON(exportURL)

        let imported = try #require(importedStore.hosts.first)
        #expect(importedStore.hosts.count == 1)
        #expect(imported == host)
        #expect(imported.name == host.name)
        #expect(imported.host == host.host)
        #expect(imported.user == host.user)
        #expect(imported.port == host.port)
    }

    @Test("JSON import skips duplicate hosts")
    func skipDuplicateImports() throws {
        let source = RemoteHostStore(storageURL: tempURL())
        let exportURL = tempURL()

        source.add(
            RemoteHost(
                name: "staging",
                host: "staging.example",
                user: "deploy"
            )
        )

        try source.export(to: exportURL)

        let imported = try source.importFromJSON(exportURL)

        #expect(imported.isEmpty)
        #expect(source.hosts.count == 1)
    }

    @Test("invalid JSON payload throws on import")
    func invalidPayload() throws {
        let store = RemoteHostStore(storageURL: tempURL())
        let invalidURL = tempURL()
        try "not json".data(using: .utf8)!.write(to: invalidURL, options: .atomic)

        #expect(throws: RemoteHostStoreError.self) {
            _ = try store.importFromJSON(invalidURL)
        }
    }

    private func tempURL() -> URL {
        let file = "test-\(UUID().uuidString).json"
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteHostStoreTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(file)
    }
}
