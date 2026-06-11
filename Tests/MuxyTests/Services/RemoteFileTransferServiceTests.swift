import Foundation
import Testing

@testable import MuxySSH

@Suite("Remote file transfer payload parsing")
struct RemoteFileTransferServiceTests {
    @Test("Extracts JSON payload from noisy shell output")
    func extractsJSONFromNoisyOutput() {
        let output = """
        Welcome to remote host
        Last login: today
        \(remotePayloadStart)
        [{"name":"file.txt","isDirectory":false,"size":12,"modified":123}]
        \(remotePayloadEnd)
        """

        let payload = RemoteFileTransferPayloadParser.extractJSONPayload(from: output)

        #expect(payload == "[{\"name\":\"file.txt\",\"isDirectory\":false,\"size\":12,\"modified\":123}]")
    }

    @Test("Falls back to bracketed JSON without markers")
    func extractsBracketedJSONWithoutMarkers() {
        let output = """
        noise before
        [{"name":"folder","isDirectory":true,"size":0,"modified":456}]
        noise after
        """

        let payload = RemoteFileTransferPayloadParser.extractJSONPayload(from: output)

        #expect(payload == "[{\"name\":\"folder\",\"isDirectory\":true,\"size\":0,\"modified\":456}]")
    }

    @Test("Default runCommand collects output without enabling streaming mode")
    func defaultRunCommandDoesNotInstallOutputCallback() async throws {
        let transport = MockRemoteFileTransferTransport()
        let configuration = MockSSHConfiguration()

        _ = try await transport.runCommand(
            configuration: configuration,
            command: "echo test"
        )

        #expect(transport.receivedOutputCallback == false)
    }
}

private let remotePayloadStart = "__MUXY_PAYLOAD_START__"
private let remotePayloadEnd = "__MUXY_PAYLOAD_END__"

private struct MockSSHConfiguration: SSHConnectionConfigurable {
    let host = "example.com"
    let port = 22
    let user = "tester"
    let remoteExecCommand: String? = nil
    let initialShellInput = ""
    let authentication: SSHAuthentication? = nil
}

private final class MockRemoteFileTransferTransport: RemoteFileTransferTransport, @unchecked Sendable {
    private(set) var receivedOutputCallback = false

    func runCommand(
        configuration _: any SSHConnectionConfigurable,
        command _: String,
        timeout _: TimeInterval,
        onOutputLine: ((String) -> Void)?
    ) async throws -> String {
        receivedOutputCallback = onOutputLine != nil
        return "ok"
    }

    func listRemoteDirectory(
        configuration _: any SSHConnectionConfigurable,
        path _: String
    ) async throws -> [RemoteFileTransferRemoteEntry] {
        []
    }

    func download(
        configuration _: any SSHConnectionConfigurable,
        remotePath _: String,
        localPath _: String
    ) async throws {}

    func upload(
        configuration _: any SSHConnectionConfigurable,
        localPath _: String,
        remotePath _: String
    ) async throws {}
}
