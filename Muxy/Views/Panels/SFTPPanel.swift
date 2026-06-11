import Foundation
import SwiftUI
import UniformTypeIdentifiers
import os

struct SFTPPanel: View {
    nonisolated private static let logger = Logger(subsystem: "app.muxy", category: "SFTPPanel")

    @Environment(AppState.self) private var appState
    @Environment(ProjectStore.self) private var projectStore
    @Environment(WorktreeStore.self) private var worktreeStore
    @State private var viewModel = SFTPPanelViewModel()

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().overlay(MuxyTheme.border)
            HStack(spacing: 0) {
                fileList(
                    title: "Local",
                    path: viewModel.localPath,
                    items: viewModel.localItems,
                    loading: viewModel.localLoading,
                    message: viewModel.localMessage,
                    selectedID: viewModel.selectedLocalItemID,
                    showUpButton: viewModel.hasLocalParent(viewModel.localPath),
                    onUp: { viewModel.navigateLocalParent() },
                    onSelect: { item in viewModel.selectLocalItem(item) },
                    onOpen: { item in viewModel.openLocalItem(item) },
                    onUpload: { item in
                        Task { await viewModel.uploadItem(item, overwrite: false) }
                    },
                    onUploadOverwrite: { item in
                        Task { await viewModel.uploadItem(item, overwrite: true) }
                    }
                )

                Rectangle()
                    .fill(MuxyTheme.border)
                    .frame(width: 1)

                fileList(
                    title: "Remote",
                    path: viewModel.remotePath,
                    items: viewModel.remoteItems,
                    loading: viewModel.remoteLoading,
                    message: viewModel.remoteMessage,
                    selectedID: viewModel.selectedRemoteItemID,
                    showUpButton: viewModel.remotePath != "/",
                    onUp: { viewModel.navigateRemoteParent() },
                    onSelect: { item in viewModel.selectRemoteItem(item) },
                    onOpen: { item in viewModel.openRemoteItem(item) },
                    onDownload: { item in
                        Task { await viewModel.downloadItem(item, overwrite: false) }
                    },
                    onDownloadOverwrite: { item in
                        Task { await viewModel.downloadItem(item, overwrite: true) }
                    }
                )
            }
            Divider().overlay(MuxyTheme.border)
            transferHistorySection
        }
        .onAppear { syncContext() }
        .onChange(of: appState.activeProjectID) { _, _ in syncContext() }
        .onChange(of: viewModel.localPath) { _, _ in
            viewModel.clearLocalSelection()
            viewModel.refreshLocal()
        }
        .onChange(of: viewModel.remotePath) { _, _ in
            viewModel.clearRemoteSelection()
            Task { await viewModel.refreshRemote() }
        }
    }

    private var toolbar: some View {
        HStack(spacing: UIMetrics.spacing2) {
            Group {
                Text("Local")
                    .font(.system(size: UIMetrics.fontFootnote, weight: .medium))
                    .foregroundStyle(MuxyTheme.fgMuted)
                    .frame(width: UIMetrics.scaled(54), alignment: .leading)

                Text(viewModel.localPath)
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

                Text(viewModel.remotePath)
                    .font(.system(size: UIMetrics.fontFootnote))
                    .foregroundStyle(MuxyTheme.fg)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer(minLength: UIMetrics.spacing2)
            iconButton(symbol: "arrow.clockwise", label: "Refresh", action: { viewModel.refreshBoth() })
            iconButton(
                symbol: "arrow.up.to.line.compact",
                label: "Upload",
                action: { Task { await viewModel.uploadSelected() } },
                isDisabled: viewModel.selectedLocalItem?.isDirectory ?? true || remoteConfiguration == nil
            )
            iconButton(
                symbol: "arrow.down.to.line.compact",
                label: "Download",
                action: { Task { await viewModel.downloadSelected() } },
                isDisabled: remoteConfiguration == nil || viewModel.selectedRemoteItem?.isDirectory ?? true
            )
        }
        .padding(.horizontal, UIMetrics.spacing4)
        .frame(height: UIMetrics.scaled(36))
    }

    private func syncContext() {
        Self.logger.info("syncContext start localPath=\(viewModel.localPath, privacy: .public) remotePath=\(viewModel.remotePath, privacy: .public)")
        viewModel.syncContext(
            localRootPath: localRootPath(),
            remoteRootPath: remoteRootPath(),
            configuration: remoteConfiguration
        )
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

    private var activeProject: Project? {
        guard let activeID = appState.activeProjectID else { return nil }
        return projectStore.projects.first(where: { $0.id == activeID })
    }

    private var remoteConfiguration: SSHConnectionConfiguration? {
        guard let projectID = appState.activeProjectID,
              let tab = appState.activeTab(for: projectID),
              let pane = tab.content.pane,
              let config = pane.sshConfiguration
        else { return nil }
        return config
    }

    private func remoteRootPath() -> String {
        remoteConfiguration?.remotePath ?? "/"
    }

    private func fileList(
        title: String,
        path: String,
        items: [RemoteFileBrowserItem],
        loading: Bool,
        message: String,
        selectedID: String?,
        showUpButton: Bool,
        onUp: @escaping () -> Void,
        onSelect: @escaping (RemoteFileBrowserItem) -> Void,
        onOpen: @escaping (RemoteFileBrowserItem) -> Void,
        onUpload: ((RemoteFileBrowserItem) -> Void)? = nil,
        onUploadOverwrite: ((RemoteFileBrowserItem) -> Void)? = nil,
        onDownload: ((RemoteFileBrowserItem) -> Void)? = nil,
        onDownloadOverwrite: ((RemoteFileBrowserItem) -> Void)? = nil
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
                            item: RemoteFileBrowserItem(
                                id: "",
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
    }

    private func fileRow(
        item: RemoteFileBrowserItem,
        isSelected: Bool,
        onSelect: @escaping () -> Void,
        onOpen: @escaping () -> Void,
        onUpload: ((RemoteFileBrowserItem) -> Void)? = nil,
        onUploadOverwrite: ((RemoteFileBrowserItem) -> Void)? = nil,
        onDownload: ((RemoteFileBrowserItem) -> Void)? = nil,
        onDownloadOverwrite: ((RemoteFileBrowserItem) -> Void)? = nil
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
                    viewModel.transferHistoryStore.clear()
                }
                .buttonStyle(.plain)
                .font(.system(size: UIMetrics.fontCaption, weight: .medium))
                .foregroundStyle(MuxyTheme.fgMuted)
                .disabled(viewModel.transferHistoryStore.records.isEmpty)
            }
            .padding(.horizontal, UIMetrics.spacing3)
            .padding(.vertical, UIMetrics.spacing2)

            Divider().overlay(MuxyTheme.border)

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    ForEach(viewModel.transferHistoryStore.records) { record in
                        transferHistoryRow(record)
                    }
                    if viewModel.transferHistoryStore.records.isEmpty {
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

    private func fileSizeLabel(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
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
}
