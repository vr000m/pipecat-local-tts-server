import Darwin
import Foundation

/// Checks whether a loopback port is free and, when not, who holds it.
public enum PortProbe {
    public struct Owner: Sendable, Equatable {
        public var pid: Int32?
        public var command: String?
        /// Set when the matching `pipecat.tts-server.<backend>` launchd agent is loaded.
        public var launchdLabel: String?

        public init(pid: Int32? = nil, command: String? = nil, launchdLabel: String? = nil) {
            self.pid = pid
            self.command = command
            self.launchdLabel = launchdLabel
        }

        public var summary: String {
            var parts: [String] = []
            if let command { parts.append(command) }
            if let pid { parts.append("pid \(pid)") }
            return parts.isEmpty ? "another process" : parts.joined(separator: ", ")
        }
    }

    /// Mirrors the server's own preflight: an `SO_REUSEADDR` bind to 127.0.0.1.
    public static func isFree(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return true }
        defer { close(fd) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    /// Best-effort owner lookup via `lsof`, plus the backend's launchd agent if loaded.
    public static func owner(of port: Int, backend: Service) async -> Owner {
        var owner = Owner()
        let lsof = Subprocess(
            .init(
                executable: URL(filePath: "/usr/sbin/lsof"),
                arguments: ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fpc"],
                environment: ProcessEnvironment.base()))
        if let result = try? await lsof.collect() {
            for line in result.stdout {
                if line.hasPrefix("p"), owner.pid == nil { owner.pid = Int32(line.dropFirst()) }
                if line.hasPrefix("c"), owner.command == nil { owner.command = String(line.dropFirst()) }
            }
        }
        guard let label = backend.info.launchdLabel else { return owner }
        let launchctl = Subprocess(
            .init(
                executable: URL(filePath: "/bin/launchctl"),
                arguments: ["print", "gui/\(getuid())/\(label)"],
                environment: ProcessEnvironment.base()))
        if let result = try? await launchctl.collect(), result.status == 0 {
            owner.launchdLabel = label
        }
        return owner
    }
}
