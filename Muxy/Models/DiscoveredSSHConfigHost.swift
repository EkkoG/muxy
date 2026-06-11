import Foundation

struct DiscoveredSSHConfigHost: Equatable, Hashable {
    let name: String
    let hostName: String
    let user: String?
    let port: UInt16
    let identityFile: String?
}
