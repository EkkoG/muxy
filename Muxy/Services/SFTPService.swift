import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import os

private let logger = Logger(subsystem: "app.muxy", category: "SFTPService")
private let sftpExitMarker = "__MUXY_EXIT__="

struct SFTPRemoteEntry: Decodable {
    let name: String
    let isDirectory: Bool
    let size: Int64
    let modified: Int64
}

struct SFTPFileItem: Identifiable, Hashable {
    let id: String
    let name: String
    let absolutePath: String
    let isDirectory: Bool
    let size: Int64
    let modified: Date?

    init(name: String, absolutePath: String, isDirectory: Bool, size: Int64, modified: TimeInterval?) {
        self.id = absolutePath
        self.name = name
        self.absolutePath = absolutePath
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified.map { Date(timeIntervalSince1970: $0) }
    }
}

enum SFTPServiceError: Error, LocalizedError {
    case noRemoteConfig
    case commandFailed(String)
    case parseFailed(String)
    case remoteConnection(SSHConnectionError)

    var errorDescription: String? {
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

final class SFTPService: @unchecked Sendable {
    static let shared = SFTPService()

    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

    private init() {}

    func localEntries(at path: String) -> [SFTPFileItem] {
        let normalizedPath = normalizedLocalPath(path)
        guard FileManager.default.fileExists(atPath: normalizedPath),
              let names = try? FileManager.default.contentsOfDirectory(atPath: normalizedPath)
        else { return [] }

        let entries: [SFTPFileItem] = names.compactMap { name in
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

            return SFTPFileItem(
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

    func listRemoteDirectory(
        configuration: NativeSSHConnectionConfiguration,
        path: String
    ) async throws -> [SFTPFileItem] {
        let command = remoteListCommand(path: path)
        let payload = try await runCommand(configuration: configuration, command: command)
        guard let data = payload.data(using: .utf8) else {
            throw SFTPServiceError.parseFailed("invalid remote payload")
        }
        do {
            let entries = try JSONDecoder().decode([SFTPRemoteEntry].self, from: data)
            return entries.map { entry in
                let absolute = joinRemotePath(base: path, child: entry.name)
                return SFTPFileItem(
                    name: entry.name,
                    absolutePath: absolute,
                    isDirectory: entry.isDirectory,
                    size: entry.size,
                    modified: TimeInterval(entry.modified)
                )
            }.sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        } catch {
            throw SFTPServiceError.parseFailed(error.localizedDescription)
        }
    }

    func download(
        configuration: NativeSSHConnectionConfiguration,
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
        do {
            try await runCommand(
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
        } catch {
            throw error
        }
        if let error = transferError {
            throw error
        }
    }

    func upload(
        configuration: NativeSSHConnectionConfiguration,
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

    private func runCommand(
        configuration: NativeSSHConnectionConfiguration,
        command: String,
        timeout: TimeInterval = 25
    ) async throws -> String {
        let wrapped = wrapCommand(command)
        return try await withCheckedThrowingContinuation { continuation in
            let runner = NativeSSHExecRunner(
                configuration: configuration,
                command: wrapped,
                group: group,
                timeout: timeout,
                callback: { result in
                    continuation.resume(with: result)
                }
            )
            runner.start()
        }
    }

    private func runCommand(
        configuration: NativeSSHConnectionConfiguration,
        command: String,
        timeout: TimeInterval = 25,
        onOutputLine: @escaping (String) -> Void
    ) async throws {
        let wrapped = wrapCommand(command)
        try await withCheckedThrowingContinuation { continuation in
            let runner = NativeSSHExecRunner(
                configuration: configuration,
                command: wrapped,
                group: group,
                timeout: timeout,
                callback: { result in
                    switch result {
                    case .success:
                        continuation.resume(returning: ())
                    case let .failure(error):
                        continuation.resume(throwing: error)
                    }
                },
                onOutputLine: onOutputLine
            )
            runner.start()
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
        let target = pythonString(absoluteRemotePath(path))
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
    print(json.dumps(entries))
except Exception as exc:
    print(str(exc))
    raise SystemExit(1)
PY
"""
    }

    private func remoteDownloadCommand(path: String) -> String {
        let target = pythonString(absoluteRemotePath(path))
        return """
python3 - <<'PY'
import base64
import os

target = os.path.expanduser(\(target))
with open(target, 'rb') as handle:
    while True:
        chunk = handle.read(262144)
        if not chunk:
            break
        print(base64.b64encode(chunk).decode())
PY
"""
    }

    private func remoteUploadCommand(path: String, base64: String, append: Bool) -> String {
        let target = pythonString(absoluteRemotePath(path))
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

    private func absoluteRemotePath(_ path: String) -> String {
        guard !path.isEmpty else { return "/" }
        if path == "/" { return "/" }
        return path
    }

    private func normalizedLocalPath(_ path: String) -> String {
        let normalized = URL(fileURLWithPath: path.isEmpty ? "/" : path).standardized.path
        return normalized.isEmpty ? "/" : normalized
    }

    private func joinRemotePath(base: String, child: String) -> String {
        if base == "/" { return "/\(child)" }
        if base.hasSuffix("/") { return "\(base)\(child)" }
        return "\(base)/\(child)"
    }
}

final class NativeSSHExecRunner: @unchecked Sendable {
    private let configuration: NativeSSHConnectionConfiguration
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
        configuration: NativeSSHConnectionConfiguration,
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
            let authDelegate = try NativeSSHAuthenticationDelegate(
                user: configuration.user,
                authentication: configuration.authentication,
                paneID: self.id
            )
            let serverDelegate = NativeSSHServerAuthenticationDelegate(
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
                            NativeSSHErrorHandler(stage: "sftp-parent", paneID: self.id)
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
                self.finish(.failure(SFTPServiceError.commandFailed("command timed out")))
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
        logger.info("Opening SFTP command channel for \(self.id.uuidString)")
        channel.pipeline.handler(type: NIOSSHHandler.self).flatMap { [self] sshHandler in
            let promise = channel.eventLoop.makePromise(of: Channel.self)
            sshHandler.createChannel(promise) { childChannel, channelType in
                guard channelType == .session else {
                    return childChannel.eventLoop.makeFailedFuture(NativeSSHConnectionFailure.invalidChannelType)
                }
                return childChannel.eventLoop.makeCompletedFuture {
                    let handler = NativeSSHCommandHandler(
                        command: self.command,
                        paneID: self.id,
                        onOutputLine: self.onOutputLine,
                        callback: { result in
                            self.finish(result)
                        }
                    )
                    try childChannel.pipeline.syncOperations.addHandler(handler)
                    try childChannel.pipeline.syncOperations.addHandler(
                        NativeSSHErrorHandler(stage: "sftp-child", paneID: self.id)
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

    private func finish(_ result: Result<NativeSSHCommandOutput, Error>) {
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

    private func mappedResult(_ result: Result<NativeSSHCommandOutput, Error>) -> Result<String, Error> {
        switch result {
        case let .success(value):
            if let exitCode = value.exitCode {
                guard exitCode == 0 else {
                    return .failure(SFTPServiceError.commandFailed(value.payload.isEmpty ? "command failed with status \(exitCode)" : value.payload))
                }
            } else {
                return parseOutput(value.payload)
            }
            return .success(value.payload)
        case let .failure(error):
            return .failure(mapFailure(error))
        }
    }

    private func parseOutput(_ text: String) -> Result<String, Error> {
        let marker = sftpExitMarker
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)
        guard let markerLine = lines.last(where: { $0.hasPrefix(marker) }) else {
            return .success(normalized)
        }
        guard let markerIndex = lines.lastIndex(where: { $0.hasPrefix(marker) }) else {
            return .success(normalized)
        }
        let payloadLines = lines[..<markerIndex]
        let payload = payloadLines.joined(separator: "\n")
        let statusText = markerLine.dropFirst(marker.count).trimmingCharacters(in: .whitespacesAndNewlines)
        let status = Int(statusText) ?? 1
        if status == 0 { return .success(payload) }
        return .failure(SFTPServiceError.commandFailed(payload.isEmpty ? "command failed with status \(status)" : payload))
    }

    private func mapFailure(_ error: Error) -> Error {
        if let sshError = error as? SSHConnectionError {
            return SFTPServiceError.remoteConnection(sshError)
        } else if let mapped = error as? NIOSSHError {
            return SFTPServiceError.remoteConnection(
                SSHConnectionErrorMapper.map(mapped, host: configuration.host)
            )
        }
        return error
    }
}

final class NativeSSHCommandHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    typealias OutboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData

    private let command: String
    private let paneID: UUID
    private let onOutputLine: ((String) -> Void)?
    private let callback: (Result<NativeSSHCommandOutput, Error>) -> Void
    private var output = Data()
    private var outputLineBuffer = ""
    private var exitCode: Int?
    private var isCompleted = false
    private weak var context: ChannelHandlerContext?

    fileprivate init(
        command: String,
        paneID: UUID,
        onOutputLine: ((String) -> Void)? = nil,
        callback: @escaping (Result<NativeSSHCommandOutput, Error>) -> Void
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
        if let onOutputLine {
            let chunk = String(decoding: bytes, as: UTF8.self)
            handleOutputChunk(chunk, onOutputLine: onOutputLine)
        } else {
            output.append(Data(bytes))
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        logger.error("SFTP command error for \(self.paneID.uuidString): \(error)")
        completeOnce(.failure(error))
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        if onOutputLine != nil && !outputLineBuffer.isEmpty {
            handleOutputLine(outputLineBuffer)
            outputLineBuffer.removeAll()
        }
        let payload = String(data: output, encoding: .utf8) ?? ""
        completeOnce(.success(NativeSSHCommandOutput(
            payload: payload,
            exitCode: exitCode
        )))
        context.fireChannelInactive()
    }

    private func completeOnce(_ result: Result<NativeSSHCommandOutput, Error>) {
        guard !isCompleted else { return }
        isCompleted = true
        callback(result)
        if case .failure = result {
            context?.close(promise: nil)
        }
    }

    private func handleOutputChunk(_ chunk: String, onOutputLine: @escaping (String) -> Void) {
        outputLineBuffer += chunk
        while let index = outputLineBuffer.firstIndex(of: "\n") {
            let line = String(outputLineBuffer[..<index]).trimmingCharacters(in: .newlines)
            outputLineBuffer.removeSubrange(...index)
            handleOutputLine(line, onOutputLine: onOutputLine)
        }
    }

    private func handleOutputLine(_ rawLine: String, onOutputLine: ((String) -> Void)? = nil) {
        let marker = sftpExitMarker
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }
        if line.hasPrefix(marker) {
            let statusText = String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            exitCode = Int(statusText) ?? 1
            return
        }
        if let onOutputLine {
            onOutputLine(line)
        } else {
            output.append(Data(line.utf8))
            output.append(Data([10]))
        }
    }

    private func handleOutputLine(_ line: String) {
        handleOutputLine(line, onOutputLine: onOutputLine)
    }
}

private final class SFTPDownloadWriter {
    private let fileHandle: FileHandle

    init(fileHandle: FileHandle) {
        self.fileHandle = fileHandle
    }

    func append(_ line: String) throws {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let chunk = Data(base64Encoded: trimmed) else {
            throw SFTPServiceError.commandFailed("Unable to decode downloaded chunk")
        }
        try fileHandle.write(contentsOf: chunk)
    }
}

private struct NativeSSHCommandOutput {
    let payload: String
    let exitCode: Int?
}
