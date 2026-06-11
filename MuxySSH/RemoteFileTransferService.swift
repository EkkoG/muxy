import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import os

private let logger = Logger(subsystem: "app.muxy", category: "RemoteFileTransferService")
private let sftpExitMarker = "__MUXY_EXIT__="
private let sftpPayloadStartMarker = "__MUXY_PAYLOAD_START__"
private let sftpPayloadEndMarker = "__MUXY_PAYLOAD_END__"

private func sftpPreview(_ value: String, limit: Int = 160) -> String {
    let flattened = value.replacingOccurrences(of: "\n", with: "\\n")
    if flattened.count <= limit {
        return flattened
    }
    return String(flattened.prefix(limit)) + "..."
}

public protocol RemoteFileTransferTransport: Sendable {
    func runCommand(
        configuration: any SSHConnectionConfigurable,
        command: String,
        timeout: TimeInterval,
        onOutputLine: ((String) -> Void)?
    ) async throws -> String

    func listRemoteDirectory(
        configuration: any SSHConnectionConfigurable,
        path: String
    ) async throws -> [RemoteFileTransferRemoteEntry]

    func download(
        configuration: any SSHConnectionConfigurable,
        remotePath: String,
        localPath: String
    ) async throws

    func upload(
        configuration: any SSHConnectionConfigurable,
        localPath: String,
        remotePath: String
    ) async throws
}

public extension RemoteFileTransferTransport {
    func runCommand(
        configuration: any SSHConnectionConfigurable,
        command: String,
        timeout: TimeInterval = 25
    ) async throws -> String {
        try await runCommand(configuration: configuration, command: command, timeout: timeout, onOutputLine: nil)
    }
}

public struct RemoteFileTransferRemoteEntry: Decodable {
    let name: String
    let isDirectory: Bool
    let size: Int64
    let modified: Int64
}

public struct RemoteFileTransferItem: Identifiable, Hashable {
    public let id: String
    public let name: String
    public let absolutePath: String
    public let isDirectory: Bool
    public let size: Int64
    public let modified: Date?

    public init(name: String, absolutePath: String, isDirectory: Bool, size: Int64, modified: TimeInterval?) {
        self.id = absolutePath
        self.name = name
        self.absolutePath = absolutePath
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified.map { Date(timeIntervalSince1970: $0) }
    }
}

public enum RemoteFileTransferError: Error, LocalizedError {
    case noRemoteConfig
    case commandFailed(String)
    case parseFailed(String)
    case remoteConnection(SSHConnectionError)

    public var errorDescription: String? {
        switch self {
        case .noRemoteConfig:
            return "Remote connection is not available for current terminal session"
        case let .commandFailed(message):
            return "Remote command failed: \(message)"
        case let .parseFailed(message):
            return "Unable to parse remote response: \(message)"
        case let .remoteConnection(error):
            return error.message
        }
    }
}

enum RemoteFileTransferPayloadParser {
    static func extractDelimitedPayload(from text: String) -> String? {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        guard let startIndex = lines.lastIndex(of: sftpPayloadStartMarker) else { return nil }
        guard let relativeEndIndex = lines[(startIndex + 1)...].firstIndex(of: sftpPayloadEndMarker) else {
            return nil
        }
        return lines[(startIndex + 1)..<relativeEndIndex].joined(separator: "\n")
    }

    static func extractJSONPayload(from text: String) -> String? {
        if let delimited = extractDelimitedPayload(from: text) {
            let trimmed = delimited.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard let start = normalized.firstIndex(of: "["),
              let end = normalized.lastIndex(of: "]"),
              start <= end
        else {
            return nil
        }

        let payload = String(normalized[start ... end]).trimmingCharacters(in: .whitespacesAndNewlines)
        return payload.isEmpty ? nil : payload
    }
}

public final class RemoteFileTransferService: @unchecked Sendable {
    public static let shared = RemoteFileTransferService()

    private let transport: RemoteFileTransferTransport

    public init(transport: RemoteFileTransferTransport = SSHExecTransport()) {
        self.transport = transport
    }

    public func localEntries(at path: String) -> [RemoteFileTransferItem] {
        let normalizedPath = normalizedLocalPath(path)
        guard FileManager.default.fileExists(atPath: normalizedPath),
              let names = try? FileManager.default.contentsOfDirectory(atPath: normalizedPath)
        else { return [] }

        let entries: [RemoteFileTransferItem] = names.compactMap { name in
            let absolute = URL(fileURLWithPath: normalizedPath).appendingPathComponent(name).path
            var isDirectory = false
            var size: Int64 = 0
            var modified: TimeInterval = 0
            var isDir: ObjCBool = false

            guard FileManager.default.fileExists(atPath: absolute, isDirectory: &isDir) else { return nil }
            isDirectory = isDir.boolValue

            if let attrs = try? FileManager.default.attributesOfItem(atPath: absolute) {
                size = Int64((attrs[.size] as? NSNumber)?.int64Value ?? 0)
                if let date = attrs[.modificationDate] as? Date {
                    modified = date.timeIntervalSince1970
                }
            }

            return RemoteFileTransferItem(
                name: name,
                absolutePath: absolute,
                isDirectory: isDirectory,
                size: size,
                modified: modified > 0 ? modified : nil
            )
        }

        return entries.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    public func listRemoteDirectory(
        configuration: any SSHConnectionConfigurable,
        path: String
    ) async throws -> [RemoteFileTransferItem] {
        let entries = try await transport.listRemoteDirectory(
            configuration: configuration,
            path: absoluteRemotePath(path)
        )
        return entries
            .map { entry in
                let absolute = joinRemotePath(base: absoluteRemotePath(path), child: entry.name)
                return RemoteFileTransferItem(
                    name: entry.name,
                    absolutePath: absolute,
                    isDirectory: entry.isDirectory,
                    size: entry.size,
                    modified: TimeInterval(entry.modified)
                )
            }
            .sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
    }

    public func download(
        configuration: any SSHConnectionConfigurable,
        remotePath: String,
        localPath: String
    ) async throws {
        try await transport.download(
            configuration: configuration,
            remotePath: absoluteRemotePath(remotePath),
            localPath: localPath
        )
    }

    public func upload(
        configuration: any SSHConnectionConfigurable,
        localPath: String,
        remotePath: String
    ) async throws {
        try await transport.upload(
            configuration: configuration,
            localPath: localPath,
            remotePath: absoluteRemotePath(remotePath)
        )
    }

    private func normalizedLocalPath(_ path: String) -> String {
        let normalized = URL(fileURLWithPath: path.isEmpty ? "/" : path).standardized.path
        return normalized.isEmpty ? "/" : normalized
    }

    private func absoluteRemotePath(_ path: String) -> String {
        guard !path.isEmpty else { return "/" }
        if path == "/" { return "/" }
        return path
    }

    private func joinRemotePath(base: String, child: String) -> String {
        if base == "/" { return "/\(child)" }
        if base.hasSuffix("/") { return "\(base)\(child)" }
        return "\(base)/\(child)"
    }
}

public final class SSHExecTransport: RemoteFileTransferTransport, @unchecked Sendable {
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

    public init() {}

    public func runCommand(
        configuration: any SSHConnectionConfigurable,
        command: String,
        timeout: TimeInterval = 25,
        onOutputLine: ((String) -> Void)?
    ) async throws -> String {
        let wrapped = wrapCommand(command)
        return try await withCheckedThrowingContinuation { continuation in
            let runner = SSHExecRunner(
                configuration: configuration,
                command: wrapped,
                group: group,
                timeout: timeout,
                callback: { result in
                    continuation.resume(with: result)
                },
                onOutputLine: onOutputLine
            )
            runner.start()
        }
    }

    public func listRemoteDirectory(
        configuration: any SSHConnectionConfigurable,
        path: String
    ) async throws -> [RemoteFileTransferRemoteEntry] {
        let command = remoteListCommand(path: path)
        let response = try await runCommand(configuration: configuration, command: command)
        logger.debug("SFTP list raw response path=\(path, privacy: .public) preview=\(sftpPreview(response), privacy: .public)")
        guard let payload = RemoteFileTransferPayloadParser.extractJSONPayload(from: response) else {
            logger.error("SFTP list payload extraction failed path=\(path, privacy: .public) raw=\(sftpPreview(response), privacy: .public)")
            throw RemoteFileTransferError.parseFailed(sftpPreview(response))
        }
        logger.debug("SFTP list payload extracted path=\(path, privacy: .public) payload=\(sftpPreview(payload), privacy: .public)")
        guard let data = payload.data(using: .utf8) else {
            logger.error("SFTP list payload encoding invalid path=\(path, privacy: .public) payload=\(sftpPreview(payload), privacy: .public)")
            throw RemoteFileTransferError.parseFailed("invalid remote payload encoding")
        }
        do {
            return try JSONDecoder().decode([RemoteFileTransferRemoteEntry].self, from: data)
        } catch {
            logger.error("SFTP list JSON decode failed path=\(path, privacy: .public) error=\(error.localizedDescription, privacy: .public) payload=\(sftpPreview(payload), privacy: .public)")
            throw RemoteFileTransferError.parseFailed("\(error.localizedDescription). Payload: \(sftpPreview(payload))")
        }
    }

    public func download(
        configuration: any SSHConnectionConfigurable,
        remotePath: String,
        localPath: String
    ) async throws {
        let destination = URL(fileURLWithPath: localPath).standardizedFileURL
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        let writer = SFTPDownloadWriter(fileHandle: handle)
        let command = remoteDownloadCommand(path: remotePath)
        var transferError: Error?
        _ = try await runCommand(
            configuration: configuration,
            command: command,
            onOutputLine: { line in
                guard transferError == nil else { return }
                do {
                    try writer.append(line)
                } catch {
                    transferError = error
                }
            }
        )
        if let error = transferError {
            logger.error("SFTP download failed remotePath=\(remotePath, privacy: .public) localPath=\(localPath, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    public func upload(
        configuration: any SSHConnectionConfigurable,
        localPath: String,
        remotePath: String
    ) async throws {
        let source = URL(fileURLWithPath: localPath).standardized
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        let chunkSize = 256 * 1024
        var appended = false
        var hasChunk = false
        while true {
            let chunk = handle.readData(ofLength: chunkSize)
            guard !chunk.isEmpty else {
                break
            }
            hasChunk = true
            let encoded = chunk.base64EncodedString()
            let command = remoteUploadCommand(path: remotePath, base64: encoded, append: appended)
            _ = try await runCommand(configuration: configuration, command: command)
            appended = true
        }
        if !hasChunk {
            let command = remoteUploadCommand(path: remotePath, base64: "", append: false)
            _ = try await runCommand(configuration: configuration, command: command)
        }
    }

    private func wrapCommand(_ command: String) -> String {
        """
{
    \(command)
    code=$?
    printf '\\n\(sftpExitMarker)%d\\n' "$code"
}
"""
    }

    private func remoteListCommand(path: String) -> String {
        let target = pythonString(path)
        return """
python3 - <<'PY'
import json
import os
import time

base = os.path.abspath(os.path.expanduser(\(target)))

try:
    entries = []
    for name in sorted(os.listdir(base)):
        if name in {".", ".."}:
            continue
        entry_path = os.path.join(base, name)
        try:
            info = os.lstat(entry_path)
        except OSError:
            continue
        entries.append({
            "name": name,
            "isDirectory": os.path.isdir(entry_path),
            "size": int(info.st_size),
            "modified": int(info.st_mtime)
        })
    print("\(sftpPayloadStartMarker)")
    print(json.dumps(entries))
    print("\(sftpPayloadEndMarker)")
except Exception as exc:
    print(str(exc))
    raise SystemExit(1)
PY
"""
    }

    private func remoteDownloadCommand(path: String) -> String {
        let target = pythonString(path)
        return """
python3 - <<'PY'
import base64
import os

target = os.path.expanduser(\(target))
with open(target, 'rb') as handle:
    print("\(sftpPayloadStartMarker)")
    while True:
        chunk = handle.read(262144)
        if not chunk:
            break
        print(base64.b64encode(chunk).decode())
    print("\(sftpPayloadEndMarker)")
PY
"""
    }

    private func remoteUploadCommand(path: String, base64: String, append: Bool) -> String {
        let target = pythonString(path)
        let payload = escapePythonString(base64)
        let mode = append ? "ab" : "wb"
        return """
python3 - <<'PY'
import base64
from pathlib import Path
import os

target = os.path.expanduser(\(target))
data = "\(payload)"
mode = "\(mode)"
Path(target).parent.mkdir(parents=True, exist_ok=True)
with open(target, mode) as handle:
    handle.write(base64.b64decode(data))
PY
"""
    }

    private func pythonString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private func escapePythonString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

}

final class SSHExecRunner: @unchecked Sendable {
    private let configuration: any SSHConnectionConfigurable
    private let command: String
    private let group: EventLoopGroup
    private let timeout: TimeInterval
    private let callback: (Result<String, Error>) -> Void
    private let onOutputLine: ((String) -> Void)?
    private var timer: DispatchSourceTimer?
    private var parentChannel: Channel?
    private var childChannel: Channel?
    private var isCompleted = false
    private let id = UUID()

    init(
        configuration: any SSHConnectionConfigurable,
        command: String,
        group: EventLoopGroup,
        timeout: TimeInterval,
        callback: @escaping (Result<String, Error>) -> Void,
        onOutputLine: ((String) -> Void)? = nil
    ) {
        self.configuration = configuration
        self.command = command
        self.group = group
        self.timeout = timeout
        self.callback = callback
        self.onOutputLine = onOutputLine
    }

    func start() {
        do {
            let authDelegate = try SSHAuthenticationDelegate(
                user: configuration.user,
                authentication: configuration.authentication,
                paneID: self.id
            )
            let serverDelegate = SSHServerAuthenticationDelegate(
                host: configuration.host,
                port: configuration.port,
                paneID: self.id
            )
            let bootstrap = ClientBootstrap(group: group)
                .channelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        let ssh = NIOSSHHandler(
                            role: .client(.init(
                                userAuthDelegate: authDelegate,
                                serverAuthDelegate: serverDelegate
                            )),
                            allocator: channel.allocator,
                            inboundChildChannelInitializer: nil
                        )
                        try channel.pipeline.syncOperations.addHandler(ssh)
                        try channel.pipeline.syncOperations.addHandler(
                            SSHErrorHandler(stage: "sftp-parent", paneID: self.id)
                        )
                    }
                }
                .channelOption(
                    ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR),
                    value: 1
                )

            let timeout = timeout
            self.timer = DispatchSource.makeTimerSource()
            self.timer?.schedule(deadline: .now() + .milliseconds(Int(timeout * 1000)))
            self.timer?.setEventHandler {
                self.finish(.failure(RemoteFileTransferError.commandFailed("command timed out")))
            }
            self.timer?.resume()

            bootstrap.connect(host: configuration.host, port: configuration.port).whenComplete { result in
                let runner = self
                switch result {
                case let .success(channel):
                    runner.parentChannel = channel
                    runner.openSession(on: channel)
                case let .failure(error):
                    runner.finish(.failure(error))
                }
            }
        } catch {
            finish(.failure(error))
        }
    }

    private func openSession(on channel: Channel) {
        logger.info(
            "Opening SFTP command channel for \(self.id.uuidString) command=\(sftpPreview(self.command), privacy: .public)"
        )
        channel.pipeline.handler(type: NIOSSHHandler.self).flatMap { [self] sshHandler in
            let promise = channel.eventLoop.makePromise(of: Channel.self)
            sshHandler.createChannel(promise) { childChannel, channelType in
                guard channelType == .session else {
                    return childChannel.eventLoop.makeFailedFuture(SSHConnectionFailure.invalidChannelType)
                }
                return childChannel.eventLoop.makeCompletedFuture {
                    let handler = SSHCommandHandler(
                        command: self.command,
                        paneID: self.id,
                        onOutputLine: self.onOutputLine,
                        callback: { result in
                            self.finish(result)
                        }
                    )
                    try childChannel.pipeline.syncOperations.addHandler(handler)
                    try childChannel.pipeline.syncOperations.addHandler(
                        SSHErrorHandler(stage: "sftp-child", paneID: self.id)
                    )
                }
            }
            return promise.futureResult
        }.whenComplete { result in
            let runner = self
            switch result {
            case let .success(channel):
                runner.childChannel = channel
            case let .failure(error):
                runner.finish(.failure(error))
            }
        }
    }

    private func finish(_ result: Result<SSHCommandOutput, Error>) {
        guard !isCompleted else { return }
        isCompleted = true
        timer?.cancel()
        timer = nil
        childChannel?.close(promise: nil)
        parentChannel?.close(promise: nil)
        childChannel = nil
        parentChannel = nil
        callback(mappedResult(result))
    }

    private func mappedResult(_ result: Result<SSHCommandOutput, Error>) -> Result<String, Error> {
        switch result {
        case let .success(value):
            logger.debug(
                "SFTP command finished exitCode=\(String(describing: value.exitCode), privacy: .public) stdoutBytes=\(value.stdout.utf8.count, privacy: .public) stderrBytes=\(value.stderr.utf8.count, privacy: .public) stdout=\(sftpPreview(value.stdout), privacy: .public) stderr=\(sftpPreview(value.stderr), privacy: .public)"
            )
            if let exitCode = value.exitCode {
                guard exitCode == 0 else {
                    logger.error(
                        "SFTP command exited non-zero exitCode=\(exitCode, privacy: .public) stdout=\(sftpPreview(value.stdout), privacy: .public) stderr=\(sftpPreview(value.stderr), privacy: .public)"
                    )
                    let message = value.stderr.isEmpty ? value.stdout : value.stderr
                    return .failure(RemoteFileTransferError.commandFailed(message.isEmpty ? "command failed with status \(exitCode)" : message))
                }
            } else {
                return parseOutput(value.stdout)
            }
            return .success(value.stdout)
        case let .failure(error):
            logger.error("SFTP command failed before completion error=\(error.localizedDescription, privacy: .public)")
            return .failure(mapFailure(error))
        }
    }

    private func parseOutput(_ text: String) -> Result<String, Error> {
        let marker = sftpExitMarker
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)
        guard let markerLine = lines.last(where: { $0.hasPrefix(marker) }) else {
            logger.debug("SFTP command response missing exit marker payload=\(sftpPreview(normalized), privacy: .public)")
            return .success(normalized)
        }
        guard let markerIndex = lines.lastIndex(where: { $0.hasPrefix(marker) }) else {
            logger.debug("SFTP command response missing exit marker index payload=\(sftpPreview(normalized), privacy: .public)")
            return .success(normalized)
        }
        let payloadLines = lines[..<markerIndex]
        let payload = payloadLines.joined(separator: "\n")
        let statusText = markerLine.dropFirst(marker.count).trimmingCharacters(in: .whitespacesAndNewlines)
        let status = Int(statusText) ?? 1
        logger.debug("SFTP command parsed exit marker status=\(status, privacy: .public) payload=\(sftpPreview(payload), privacy: .public)")
        if status == 0 { return .success(payload) }
        return .failure(RemoteFileTransferError.commandFailed(payload.isEmpty ? "command failed with status \(status)" : payload))
    }

    private func mapFailure(_ error: Error) -> Error {
        if let sshError = error as? SSHConnectionError {
            return RemoteFileTransferError.remoteConnection(sshError)
        } else if let mapped = error as? NIOSSHError {
            return RemoteFileTransferError.remoteConnection(
                SSHConnectionErrorMapper.map(mapped, host: configuration.host)
            )
        } else if let channelError = error as? ChannelError {
            return RemoteFileTransferError.remoteConnection(.unknown(channelError.localizedDescription))
        }
        return error
    }
}

final class SSHCommandHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    typealias OutboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData

    private let command: String
    private let paneID: UUID
    private let onOutputLine: ((String) -> Void)?
    private let callback: (Result<SSHCommandOutput, Error>) -> Void
    private var stdout = Data()
    private var stderr = Data()
    private var outputLineBuffer = ""
    private var errorLineBuffer = ""
    private var exitCode: Int?
    private var isCompleted = false
    private weak var context: ChannelHandlerContext?

    fileprivate init(
        command: String,
        paneID: UUID,
        onOutputLine: ((String) -> Void)? = nil,
        callback: @escaping (Result<SSHCommandOutput, Error>) -> Void
    ) {
        self.command = command
        self.paneID = paneID
        self.onOutputLine = onOutputLine
        self.callback = callback
    }

    func channelActive(context: ChannelHandlerContext) {
        self.context = context
        sendExecRequest(context: context)
    }

    private func sendExecRequest(context: ChannelHandlerContext) {
        let promise = context.eventLoop.makePromise(of: Void.self)
        context.triggerUserOutboundEvent(
            SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true),
            promise: promise
        )
        promise.futureResult.whenComplete { [weak self] result in
            switch result {
            case .success:
                logger.info("SFTP exec request accepted for \(self?.paneID.uuidString ?? "unknown")")
            case let .failure(error):
                self?.completeOnce(.failure(error))
            }
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let data = unwrapInboundIn(data)
        guard case let .byteBuffer(buffer) = data.data else { return }
        let copy = buffer
        let bytes = copy.readableBytesView
        let chunk = String(decoding: bytes, as: UTF8.self)
        logger.debug(
            "SFTP channel chunk type=\(String(describing: data.type), privacy: .public) bytes=\(bytes.count, privacy: .public) preview=\(sftpPreview(chunk), privacy: .public)"
        )
        switch data.type {
        case .channel:
            if let onOutputLine {
                handleOutputChunkToCallback(chunk, buffer: &outputLineBuffer, onOutputLine: onOutputLine)
            } else {
                handleOutputChunkToData(chunk, buffer: &outputLineBuffer, sink: &stdout)
            }
        case .stdErr:
            handleOutputChunkToData(chunk, buffer: &errorLineBuffer, sink: &stderr)
        default:
            return
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        logger.error("SFTP command error for \(self.paneID.uuidString): \(error)")
        completeOnce(.failure(error))
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        if !outputLineBuffer.isEmpty {
            if let onOutputLine {
                handleOutputLineToCallback(outputLineBuffer, onOutputLine: onOutputLine)
            } else {
                handleOutputLineToData(outputLineBuffer, sink: &stdout)
            }
            outputLineBuffer.removeAll()
        }
        if !errorLineBuffer.isEmpty {
            handleOutputLineToData(errorLineBuffer, sink: &stderr)
            errorLineBuffer.removeAll()
        }
        completeOnce(.success(SSHCommandOutput(
            stdout: String(data: stdout, encoding: .utf8) ?? "",
            stderr: String(data: stderr, encoding: .utf8) ?? "",
            exitCode: exitCode
        )))
        context.fireChannelInactive()
    }

    private func completeOnce(_ result: Result<SSHCommandOutput, Error>) {
        guard !isCompleted else { return }
        isCompleted = true
        callback(result)
        if case .failure = result {
            context?.close(promise: nil)
        }
    }

    private func handleOutputChunkToCallback(
        _ chunk: String,
        buffer: inout String,
        onOutputLine: @escaping (String) -> Void
    ) {
        buffer += chunk
        while let index = buffer.firstIndex(of: "\n") {
            let line = String(buffer[..<index]).trimmingCharacters(in: .newlines)
            buffer.removeSubrange(...index)
            handleOutputLineToCallback(line, onOutputLine: onOutputLine)
        }
    }

    private func handleOutputChunkToData(_ chunk: String, buffer: inout String, sink: inout Data) {
        buffer += chunk
        while let index = buffer.firstIndex(of: "\n") {
            let line = String(buffer[..<index]).trimmingCharacters(in: .newlines)
            buffer.removeSubrange(...index)
            handleOutputLineToData(line, sink: &sink)
        }
    }

    private func handleOutputLineToCallback(_ rawLine: String, onOutputLine: (String) -> Void) {
        let marker = sftpExitMarker
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }
        logger.debug("SFTP stdout line callback value=\(sftpPreview(line), privacy: .public)")
        if line.hasPrefix(marker) {
            let statusText = String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            exitCode = Int(statusText) ?? 1
            return
        }
        onOutputLine(line)
    }

    private func handleOutputLineToData(_ rawLine: String, sink: inout Data) {
        let marker = sftpExitMarker
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }
        logger.debug("SFTP stdout/stderr line value=\(sftpPreview(line), privacy: .public)")
        if line.hasPrefix(marker) {
            let statusText = String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            exitCode = Int(statusText) ?? 1
            return
        }
        sink.append(Data(line.utf8))
        sink.append(Data([10]))
    }
}

private final class SFTPDownloadWriter {
    private let fileHandle: FileHandle
    private var isInsidePayload = false
    private var sawDelimitedPayload = false
    private var lineCount = 0

    init(fileHandle: FileHandle) {
        self.fileHandle = fileHandle
    }

    func append(_ line: String) throws {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lineCount += 1
        if trimmed == sftpPayloadStartMarker {
            logger.debug("SFTP download payload start line=\(self.lineCount, privacy: .public)")
            sawDelimitedPayload = true
            isInsidePayload = true
            return
        }
        if trimmed == sftpPayloadEndMarker {
            logger.debug("SFTP download payload end line=\(self.lineCount, privacy: .public)")
            isInsidePayload = false
            return
        }
        if sawDelimitedPayload && !isInsidePayload {
            logger.debug("SFTP download ignoring post-payload line line=\(self.lineCount, privacy: .public) value=\(trimmed, privacy: .public)")
            return
        }
        guard let chunk = Data(base64Encoded: trimmed) else {
            if !sawDelimitedPayload {
                logger.error("SFTP download non-payload output before marker line=\(self.lineCount, privacy: .public) value=\(trimmed, privacy: .public)")
                return
            }
            logger.error("SFTP download invalid base64 chunk line=\(self.lineCount, privacy: .public) value=\(trimmed, privacy: .public)")
            throw RemoteFileTransferError.commandFailed("Unable to decode downloaded chunk")
        }
        try fileHandle.write(contentsOf: chunk)
    }
}

private struct SSHCommandOutput {
    let stdout: String
    let stderr: String
    let exitCode: Int?
}
