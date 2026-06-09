import Foundation

enum SSHConnectionError {
    case refused(String)
    case authFailed(String)
    case hostKeyChanged(String)
    case unknownHostKey(String)
    case timeout(String)
    case unknown(String)

    var title: String {
        switch self {
        case .refused: "Connection Refused"
        case .authFailed: "Authentication Failed"
        case .hostKeyChanged: "Host Key Changed"
        case .unknownHostKey: "Unknown Host Key"
        case .timeout: "Connection Timeout"
        case .unknown: "Connection Error"
        }
    }

    var message: String {
        switch self {
        case let .refused(host): "Could not connect to \(host): Connection refused"
        case let .authFailed(detail): detail
        case let .hostKeyChanged(detail): detail
        case let .unknownHostKey(host): "The host key for \(host) is not in known_hosts. Add it to ~/.ssh/known_hosts to connect."
        case let .timeout(host): "Connection to \(host) timed out"
        case let .unknown(detail): detail
        }
    }
}

struct TerminalPaneLaunch: Equatable {
    let command: String?
    let interactive: Bool
    let closesOnCommandExit: Bool
}

@MainActor
@Observable
final class TerminalPaneState: Identifiable {
    let id: UUID
    let projectPath: String
    var title: String
    var currentWorkingDirectory: String?
    let startupCommand: String?
    let startupCommandInteractive: Bool
    let closesOnStartupCommandExit: Bool
    let externalEditorFilePath: String?
    var nativeSSHConfiguration: NativeSSHConnectionConfiguration?
    var envVars: [(key: String, value: String)] = []
    var remoteHostID: UUID?
    var sshError: SSHConnectionError?
    var sshStartTime: Date?
    var isOffline = false
    let searchState = TerminalSearchState()
    @ObservationIgnored private var titleDebounceTask: Task<Void, Never>?

    init(
        id: UUID = UUID(),
        projectPath: String,
        title: String = "Terminal",
        initialWorkingDirectory: String? = nil,
        startupCommand: String? = nil,
        startupCommandInteractive: Bool = false,
        closesOnStartupCommandExit: Bool = true,
        externalEditorFilePath: String? = nil,
        nativeSSHConfiguration: NativeSSHConnectionConfiguration? = nil
    ) {
        self.id = id
        self.projectPath = projectPath
        self.title = title
        self.currentWorkingDirectory = initialWorkingDirectory
        self.startupCommand = startupCommand
        self.startupCommandInteractive = startupCommandInteractive
        self.closesOnStartupCommandExit = closesOnStartupCommandExit
        self.externalEditorFilePath = externalEditorFilePath
        self.nativeSSHConfiguration = nativeSSHConfiguration
    }

    func consumeRestoredLaunch() -> TerminalPaneLaunch {
        if nativeSSHConfiguration != nil {
            return TerminalPaneLaunch(command: nil, interactive: false, closesOnCommandExit: false)
        }
        TerminalPaneLaunch(
            command: startupCommand,
            interactive: startupCommandInteractive,
            closesOnCommandExit: closesOnStartupCommandExit
        )
    }

    func setTitle(_ newTitle: String) {
        titleDebounceTask?.cancel()
        titleDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self, self.title != newTitle else { return }
            self.title = newTitle
            self.notifyTabUpdated()
        }
    }

    func setWorkingDirectory(_ path: String) {
        guard currentWorkingDirectory != path else { return }
        currentWorkingDirectory = path
        notifyTabUpdated()
    }

    private func notifyTabUpdated() {
        guard let appState = NotificationStore.shared.appState else { return }
        ExtensionEventEmitter.emitTabUpdated(forPane: id, appState: appState)
    }
}
