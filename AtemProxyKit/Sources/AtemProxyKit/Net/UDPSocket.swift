import Darwin
import Dispatch

/// An IPv4 address and port. ATEM switchers only speak IPv4.
public struct IPv4Endpoint: Hashable, Sendable, CustomStringConvertible {
    /// Address in network byte order.
    public var address: in_addr_t
    public var port: UInt16

    public static let atemPort: UInt16 = 9910

    public init(address: in_addr_t, port: UInt16) {
        self.address = address
        self.port = port
    }

    /// Parses dotted quad notation. `nil` for anything else.
    public init?(ip: String, port: UInt16) {
        var addr = in_addr()
        guard inet_pton(AF_INET, ip, &addr) == 1 else { return nil }
        self.init(address: addr.s_addr, port: port)
    }

    public static func any(port: UInt16) -> IPv4Endpoint {
        IPv4Endpoint(address: INADDR_ANY, port: port)
    }

    public var isAny: Bool { address == INADDR_ANY }

    public var ip: String {
        var addr = in_addr(s_addr: address)
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &addr, &buffer, socklen_t(buffer.count))
        return cString(buffer)
    }

    public var description: String { "\(ip):\(port)" }

    var sockaddr: sockaddr_in {
        var sa = sockaddr_in()
        sa.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        sa.sin_family = sa_family_t(AF_INET)
        sa.sin_port = port.bigEndian
        sa.sin_addr = in_addr(s_addr: address)
        return sa
    }

    init(_ sa: sockaddr_in) {
        self.init(address: sa.sin_addr.s_addr, port: UInt16(bigEndian: sa.sin_port))
    }
}

public struct SocketError: Error, CustomStringConvertible, Sendable {
    public let operation: String
    public let code: Int32

    public var isAddressInUse: Bool { code == EADDRINUSE }
    public var isAddressUnavailable: Bool { code == EADDRNOTAVAIL }

    public var description: String {
        if isAddressInUse { return "\(operation): address already in use" }
        if isAddressUnavailable { return "\(operation): this Mac does not have that IP address" }
        return "\(operation): \(cString(strerror(code)))"
    }
}

/// Non-blocking UDP socket delivering datagrams on a dispatch queue.
final class UDPSocket: @unchecked Sendable {
    private let fd: Int32
    private let source: DispatchSourceRead
    private var closed = false

    /// Binds to `local` and starts receiving on `queue`.
    init(bind local: IPv4Endpoint, queue: DispatchQueue,
         onReceive: @escaping ([UInt8], IPv4Endpoint) -> Void) throws {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw SocketError(operation: "socket", code: errno) }

        var yes: Int32 = 1
        // Lets a proxy bound to a specific IP coexist with one bound to all interfaces.
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var bufferSize: Int32 = 1500 * 128
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &bufferSize, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &bufferSize, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        var sa = local.sockaddr
        let bound = withUnsafePointer(to: &sa) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            let code = errno
            Darwin.close(fd)
            throw SocketError(operation: "bind \(local)", code: code)
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler {
            var buffer = [UInt8](repeating: 0, count: 2048)
            while true {
                var from = sockaddr_in()
                var fromLength = socklen_t(MemoryLayout<sockaddr_in>.size)
                let count = buffer.withUnsafeMutableBytes { raw in
                    withUnsafeMutablePointer(to: &from) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            recvfrom(fd, raw.baseAddress, raw.count, 0, $0, &fromLength)
                        }
                    }
                }
                guard count > 0 else { break }
                onReceive(Array(buffer[0..<count]), IPv4Endpoint(from))
            }
        }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        self.fd = fd
        self.source = source
    }

    var localEndpoint: IPv4Endpoint? {
        var sa = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &sa) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        return result == 0 ? IPv4Endpoint(sa) : nil
    }

    func send(_ bytes: [UInt8], to remote: IPv4Endpoint) {
        guard !closed else { return }
        var sa = remote.sockaddr
        _ = bytes.withUnsafeBytes { raw in
            withUnsafePointer(to: &sa) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, raw.baseAddress, raw.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        source.cancel()
    }

    deinit { close() }
}

/// Resolves a host name or IP to an IPv4 address. Blocking; call off the main thread.
func resolveIPv4(host: String, port: UInt16) -> IPv4Endpoint? {
    if let direct = IPv4Endpoint(ip: host, port: port) { return direct }
    var hints = addrinfo()
    hints.ai_family = AF_INET
    hints.ai_socktype = SOCK_DGRAM
    var result: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return nil }
    defer { freeaddrinfo(result) }
    guard let addr = first.pointee.ai_addr else { return nil }
    let sa = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
    return IPv4Endpoint(address: sa.sin_addr.s_addr, port: port)
}

/// A local IPv4 address of this Mac.
public struct LocalInterfaceAddress: Hashable, Sendable, Identifiable {
    public var interface: String
    public var ip: String
    /// Dotted quad, e.g. 255.255.255.0.
    public var netmask: String = ""
    public var id: String { "\(interface)/\(ip)" }
}

/// IPv4 addresses currently assigned to this Mac, excluding loopback.
public func localIPv4Addresses() -> [LocalInterfaceAddress] {
    var result: [LocalInterfaceAddress] = []
    var list: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&list) == 0 else { return [] }
    defer { freeifaddrs(list) }
    var cursor = list
    while let entry = cursor {
        defer { cursor = entry.pointee.ifa_next }
        guard let addr = entry.pointee.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET) else { continue }
        let flags = Int32(entry.pointee.ifa_flags)
        guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
        let sa = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
        let mask = entry.pointee.ifa_netmask.map {
            IPv4Endpoint($0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }).ip
        } ?? ""
        result.append(LocalInterfaceAddress(interface: cString(entry.pointee.ifa_name),
                                            ip: IPv4Endpoint(sa).ip, netmask: mask))
    }
    return result
}

private func cString(_ buffer: [CChar]) -> String {
    String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

private func cString(_ pointer: UnsafePointer<CChar>) -> String {
    cString(Array(UnsafeBufferPointer(start: pointer, count: strlen(pointer))))
}
