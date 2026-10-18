import Darwin
import Dispatch
import dnssd

/// Advertises a proxy as `_blackmagic._tcp` so ATEM Software Control lists it.
///
/// A proxy bound to a specific IP gets its own host name with an A record for
/// that IP; otherwise clients would resolve the Mac's main address and reach
/// whichever proxy listens there.
final class BonjourAdvertiser {
    static let serviceType = "_blackmagic._tcp"

    /// The host name registered for a proxy bound to `listenIP`, e.g. atem-proxy-10-80-40-115.local
    static func hostName(for listenIP: String) -> String {
        "atem-proxy-\(listenIP.replacingOccurrences(of: ".", with: "-")).local"
    }

    private var connection: DNSServiceRef?
    private var service: DNSServiceRef?
    private var hostRecord: DNSRecordRef?

    init(name: String, productName: String?, listenIP: String?, port: UInt16, uniqueId: String,
         queue: DispatchQueue, onError: @escaping (String) -> Void) {
        var txt = TXTRecordRef()
        TXTRecordCreate(&txt, 0, nil)
        defer { TXTRecordDeallocate(&txt) }
        let entries = [
            ("txtvers", "1"),
            ("name", "Blackmagic \(productName ?? "ATEM") (\(name))"),
            ("class", "AtemSwitcher"),
            ("protocol version", "0.0"),
            ("internal version", "AtemProxy"),
            ("unique id", uniqueId),
        ]
        for (key, value) in entries {
            var bytes = Array(value.utf8)
            TXTRecordSetValue(&txt, key, UInt8(bytes.count), &bytes)
        }

        guard DNSServiceCreateConnection(&connection) == kDNSServiceErr_NoError, let connection else {
            onError("Bonjour unavailable; clients must enter the proxy address manually")
            return
        }

        var host: String?
        if let listenIP, let endpoint = IPv4Endpoint(ip: listenIP, port: port) {
            let hostName = Self.hostName(for: listenIP) + "."
            var address = endpoint.address // already network order, as the A record wants
            let err = withUnsafeBytes(of: &address) { raw in
                DNSServiceRegisterRecord(connection, &hostRecord, DNSServiceFlags(kDNSServiceFlagsShared), 0,
                                         hostName, UInt16(kDNSServiceType_A), UInt16(kDNSServiceClass_IN),
                                         UInt16(raw.count), raw.baseAddress, 0, { _, _, _, _, _ in }, nil)
            }
            if err == kDNSServiceErr_NoError { host = hostName }
            else { onError("Bonjour host record failed (\(err))") }
        }

        service = connection
        let err = DNSServiceRegister(&service, DNSServiceFlags(kDNSServiceFlagsShareConnection), 0,
                                     name, Self.serviceType, nil, host, port.bigEndian,
                                     TXTRecordGetLength(&txt), TXTRecordGetBytesPtr(&txt),
                                     { _, _, _, _, _, _, _ in }, nil)
        if err != kDNSServiceErr_NoError {
            service = nil
            onError("Bonjour registration failed (\(err))")
        }
        DNSServiceSetDispatchQueue(connection, queue)
    }

    func stop() {
        if let service { DNSServiceRefDeallocate(service) }
        service = nil
        hostRecord = nil
        if let connection { DNSServiceRefDeallocate(connection) }
        connection = nil
    }

    deinit { stop() }
}
