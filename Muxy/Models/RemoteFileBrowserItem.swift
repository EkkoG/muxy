import Foundation

struct RemoteFileBrowserItem: Identifiable, Hashable {
    let id: String
    let name: String
    let absolutePath: String
    let isDirectory: Bool
    let size: Int64
    let modified: Date?
}
