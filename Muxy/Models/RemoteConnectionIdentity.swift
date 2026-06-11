import Foundation

struct RemoteConnectionIdentity: Codable, Equatable, Hashable {
    let host: String
    let user: String
    let port: UInt16
    let keyFingerprint: String?

    init(host: String, user: String, port: UInt16, keyFingerprint: String? = nil) {
        self.host = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.user = user.trimmingCharacters(in: .whitespacesAndNewlines)
        self.port = port
        self.keyFingerprint = keyFingerprint?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    init(_ host: RemoteHost) {
        self.init(host: host.host, user: host.user, port: host.port, keyFingerprint: host.keyFingerprint)
    }

    var keychainAccountSuffix: String {
        if let keyFingerprint, !keyFingerprint.isEmpty {
            return "\(user)@\(host):\(port)#\(keyFingerprint)"
        }
        return "\(user)@\(host):\(port)"
    }
}
