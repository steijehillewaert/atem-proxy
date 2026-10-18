import Foundation

/// Adds or removes an extra IPv4 address on a network interface, so several
/// proxies can each listen on port 9910 at their own address.
///
/// Uses `ifconfig` through an administrator prompt. Aliases last until the
/// interface goes down or the Mac restarts; for a permanent address add a
/// manual IP service in System Settings > Network instead.
public enum IPAlias {
    public enum Failure: Error, CustomStringConvertible {
        case invalidInput
        case cancelled
        case failed(String)

        public var description: String {
            switch self {
            case .invalidInput: "Invalid interface or IP address."
            case .cancelled: "Cancelled."
            case let .failed(message): message
            }
        }
    }

    public static func add(ip: String, interface: String) throws {
        try add([(ip: ip, interface: interface)])
    }

    /// Adds several aliases behind a single administrator prompt.
    public static func add(_ aliases: [(ip: String, interface: String)]) throws {
        guard !aliases.isEmpty else { return }
        let commands = try aliases.map {
            "/sbin/ifconfig \(try validated(interface: $0.interface)) alias \(try validated(ip: $0.ip)) 255.255.255.255"
        }
        try run(commands.joined(separator: " && "))
    }

    public static func remove(ip: String, interface: String) throws {
        try run("/sbin/ifconfig \(try validated(interface: interface)) -alias \(try validated(ip: ip))")
    }

    private static func validated(ip: String) throws -> String {
        guard IPv4Endpoint(ip: ip, port: 0) != nil else { throw Failure.invalidInput }
        return ip
    }

    private static func validated(interface: String) throws -> String {
        guard !interface.isEmpty, interface.allSatisfy({ $0.isLetter || $0.isNumber }) else {
            throw Failure.invalidInput
        }
        return interface
    }

    private static func run(_ command: String) throws {
        let script = "do shell script \"\(command)\" with administrator privileges"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            if message.contains("-128") { throw Failure.cancelled }
            throw Failure.failed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
