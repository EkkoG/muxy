import Foundation
import MuxySSH

protocol SSHConfigHostDiscovering {
    func discoverHosts(configPath: String?) -> [DiscoveredSSHConfigHost]
}

struct DefaultSSHConfigHostDiscoverer: SSHConfigHostDiscovering {
    func discoverHosts(configPath: String? = nil) -> [DiscoveredSSHConfigHost] {
        SSHConfigParser.parse(configPath: configPath).map {
            DiscoveredSSHConfigHost(
                name: $0.name,
                hostName: $0.hostName,
                user: $0.user,
                port: $0.port,
                identityFile: $0.identityFile
            )
        }
    }
}
