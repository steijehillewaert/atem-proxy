import Foundation

/// One ATEM to proxy, and where on this Mac its clients connect.
public struct ProxyConfiguration: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    /// Shown in the app and advertised to ATEM Software Control.
    public var name: String
    /// IP address or host name of the ATEM.
    public var atemHost: String
    public var atemPort: UInt16
    /// Local IPv4 address clients connect to. `nil` listens on all addresses.
    ///
    /// ATEM clients always use port 9910, so proxying several ATEMs at once needs
    /// one local IP per ATEM (see `IPAlias`), unless every client lets you pick a port.
    public var listenIP: String?
    public var listenPort: UInt16
    /// Interface the app added `listenIP` to as an alias, so it can restore it after a restart.
    public var aliasInterface: String?
    /// Advertise over Bonjour so ATEM Software Control lists the proxy.
    public var advertise: Bool
    /// Start when the app launches.
    public var autoStart: Bool

    public init(id: UUID = UUID(), name: String, atemHost: String, atemPort: UInt16 = IPv4Endpoint.atemPort,
                listenIP: String? = nil, listenPort: UInt16 = IPv4Endpoint.atemPort,
                aliasInterface: String? = nil, advertise: Bool = true, autoStart: Bool = true) {
        self.id = id
        self.name = name
        self.atemHost = atemHost
        self.atemPort = atemPort
        self.listenIP = listenIP
        self.listenPort = listenPort
        self.aliasInterface = aliasInterface
        self.advertise = advertise
        self.autoStart = autoStart
    }

    public var listenDescription: String {
        "\(listenIP ?? "all addresses"):\(listenPort)"
    }

    /// Problems that stop this configuration from starting, or that clash with others.
    public func validationErrors(among others: [ProxyConfiguration]) -> [String] {
        var errors: [String] = []
        if name.trimmingCharacters(in: .whitespaces).isEmpty { errors.append("Name is empty.") }
        if atemHost.trimmingCharacters(in: .whitespaces).isEmpty { errors.append("ATEM address is empty.") }
        if let ip = listenIP, IPv4Endpoint(ip: ip, port: listenPort) == nil {
            errors.append("Listen address \(ip) is not an IPv4 address.")
        }
        if listenPort == 0 { errors.append("Listen port can't be 0.") }
        // A proxy on all addresses can share the port with ones bound to a specific IP:
        // the specific bind wins for traffic to its address.
        for other in others where other.id != id && other.listenPort == listenPort && other.listenIP == listenIP {
            errors.append("\(other.name) already listens on \(listenDescription).")
        }
        return errors
    }
}
