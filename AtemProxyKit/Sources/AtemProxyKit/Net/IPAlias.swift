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

    /// Netmask for app-added aliases: the address alone, so it never claims a subnet route.
    public static let netmask = "255.255.255.255"

    /// Adds several aliases behind a single administrator prompt. An alias that is already
    /// there is removed and added again, which repairs ones added by versions before 2.1.3.
    public static func add(_ aliases: [(ip: String, interface: String)]) throws {
        guard !aliases.isEmpty else { return }
        let commands = try aliases.map { alias -> String in
            let interface = try validated(interface: alias.interface), ip = try validated(ip: alias.ip)
            // Without the netmask keyword ifconfig takes the mask as a point-to-point destination
            // and falls back to the class A mask; the address then never becomes local
            // (no lo0 route, ARP incomplete) and clients can't reach the proxy.
            return "{ /sbin/ifconfig \(interface) -alias \(ip) 2>/dev/null; "
                + "/sbin/ifconfig \(interface) alias \(ip) netmask \(netmask); }"
        }
        try run(commands.joined(separator: " && "))
    }

    /// Whether an address on this Mac is an alias set up the way `add` does it.
    public static func isWorking(_ address: LocalInterfaceAddress) -> Bool {
        address.netmask == netmask
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
