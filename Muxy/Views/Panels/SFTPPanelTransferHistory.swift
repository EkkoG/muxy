import Foundation

enum SFTPTransferDirection: String {
    case upload = "Upload"
    case download = "Download"
}

enum SFTPTransferResult: String {
    case success = "Success"
    case blocked = "Blocked"
    case failed = "Failed"
}

struct SFTPTransferRecord: Identifiable, Hashable {
    let id = UUID()
    let direction: SFTPTransferDirection
    let source: String
    let destination: String
    let result: SFTPTransferResult
    let message: String
    let timestamp: Date
}

@Observable
final class SFTPPanelTransferHistory {
    let maxEntries: Int
    private(set) var records: [SFTPTransferRecord] = []

    init(maxEntries: Int = 120) {
        self.maxEntries = maxEntries
    }

    func clear() {
        records.removeAll()
    }

    func append(
        direction: SFTPTransferDirection,
        source: String,
        destination: String,
        result: SFTPTransferResult,
        message: String
    ) {
        let record = SFTPTransferRecord(
            direction: direction,
            source: source,
            destination: destination,
            result: result,
            message: message,
            timestamp: Date()
        )
        records.insert(record, at: 0)
        if records.count > maxEntries {
            records.removeLast(records.count - maxEntries)
        }
    }
}
