import Darwin
import Foundation

/// Picks an IPv4 address that nothing on the network uses yet, to give a proxy its own
/// listen address next to the ATEM it serves.
public enum FreeAddress {
    /// The local interface on the same /24 as `ip`, e.g. the one that reaches an ATEM.
    public static func interface(reaching ip: String, in addresses: [LocalInterfaceAddress]) -> LocalInterfaceAddress? {
        guard let prefix = prefix24(ip) else { return nil }
        return addresses.first { prefix24($0.ip) == prefix && $0.netmask != IPAlias.netmask }
    }

    /// Candidates in the same /24 as `base`: right next to `near` first (how people usually
    /// number a proxy for an ATEM), then the top of the range.
    static func candidates(base: String, near: String?) -> [String] {
        guard let prefix = prefix24(base) else { return [] }
        var hosts: [Int] = []
        if let near, prefix24(near) == prefix, let host = Int(near.split(separator: ".")[3]) {
            for distance in 1...20 { hosts += [host + distance, host - distance] }
        }
        hosts += Array((201...250).reversed())
        var seen = Set<Int>()
        return hosts.filter { (2...254).contains($0) && seen.insert($0).inserted }.map { "\(prefix).\($0)" }
    }

    /// A free address on the same /24 as `interface`, near `near` (the ATEM's IP) when given.
    ///
    /// An address counts as taken when it is on this Mac, in `excluding`, or answers ARP.
    /// A device that is switched off can't be seen, so this is a best guess, not a lease.
    /// Blocking (probes the network for about half a second per batch); call off the main thread.
    public static func find(interface: LocalInterfaceAddress, near: String?, excluding: Set<String> = []) -> String? {
        let local = Set(localIPv4Addresses().map(\.ip))
        let candidates = candidates(base: interface.ip, near: near).filter { !local.contains($0) && !excluding.contains($0) }
        for batch in stride(from: 0, to: candidates.count, by: 8).map({ Array(candidates[$0..<min($0 + 8, candidates.count)]) }) {
            probe(batch)
            Thread.sleep(forTimeInterval: 0.5)
            let answered = arpAnswered(batch, interface: interface.interface)
            if let free = batch.first(where: { !answered.contains($0) }) { return free }
        }
        return nil
    }

    private static func prefix24(_ ip: String) -> String? {
        let parts = ip.split(separator: ".")
        guard parts.count == 4, IPv4Endpoint(ip: ip, port: 0) != nil else { return nil }
        return parts.prefix(3).joined(separator: ".")
    }

    /// Sends one UDP datagram to each address, which makes the Mac ARP for it.
    private static func probe(_ ips: [String]) {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var byte: UInt8 = 0
        for ip in ips {
            guard var sa = IPv4Endpoint(ip: ip, port: 9)?.sockaddr else { continue }
            _ = withUnsafePointer(to: &sa) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, &byte, 1, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    /// Addresses among `ips` with a resolved hardware address in the ARP table.
    private static func arpAnswered(_ ips: [String], interface: String) -> Set<String> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/arp")
        process.arguments = ["-an", "-i", interface]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        let wanted = Set(ips)
        var answered = Set<String>()
        // "? (10.80.40.88) at 7c:2e:d:21:bc:71 on en0 ifscope [ethernet]"
        for line in output.split(separator: "\n") where !line.contains("(incomplete)") {
            guard let open = line.firstIndex(of: "("), let close = line.firstIndex(of: ")") else { continue }
            let ip = String(line[line.index(after: open)..<close])
            if wanted.contains(ip) { answered.insert(ip) }
        }
        return answered
    }
}
