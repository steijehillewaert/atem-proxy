import Foundation
import Network

/// An ATEM found on the local network.
public struct DiscoveredAtem: Hashable, Identifiable, Sendable {
    public var name: String
    public var ip: String
    public var id: String { ip }
}

/// Finds ATEM switchers on the network over Bonjour, skipping other AtemProxy instances.
@MainActor
public final class AtemBrowser {
    public private(set) var devices: [DiscoveredAtem] = []
    public var onChange: (([DiscoveredAtem]) -> Void)?

    /// Older firmware advertises `_blackmagic._tcp`. Newer firmware (seen on 9.6, SDI Pro ISO and
    /// 2 M/E Constellation HD) only advertises `_switcher_ctrl._udp`, named after the model.
    static let serviceTypes = [BonjourAdvertiser.serviceType, "_switcher_ctrl._udp"]

    private var browsers: [NWBrowser] = []
    private var results: [String: Set<NWBrowser.Result>] = [:]
    private var resolving: [NWEndpoint: NWConnection] = [:]
    private var found: [NWEndpoint: DiscoveredAtem] = [:]

    public init() {}

    public func start() {
        guard browsers.isEmpty else { return }
        for type in Self.serviceTypes {
            let browser = NWBrowser(for: .bonjourWithTXTRecord(type: type, domain: nil), using: .udp)
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                Task { @MainActor in self?.update(results, type: type) }
            }
            browser.start(queue: .main)
            browsers.append(browser)
        }
    }

    public func stop() {
        browsers.forEach { $0.cancel() }
        browsers.removeAll()
        results.removeAll()
        resolving.values.forEach { $0.cancel() }
        resolving.removeAll()
    }

    private func update(_ latest: Set<NWBrowser.Result>, type: String) {
        results[type] = latest
        let results = results.values.reduce(into: Set<NWBrowser.Result>()) { $0.formUnion($1) }
        let endpoints = Set(results.map(\.endpoint))
        for result in results where found[result.endpoint] == nil && resolving[result.endpoint] == nil {
            if case let .bonjour(txt) = result.metadata, txt["internal version"] == "AtemProxy" { continue }
            var name = "ATEM"
            if case let .service(serviceName, _, _, _) = result.endpoint { name = serviceName }
            if case let .bonjour(txt) = result.metadata, let txtName = txt["name"] {
                name = txtName.replacingOccurrences(of: "Blackmagic ", with: "")
            }
            resolve(result.endpoint, name: name)
        }
        for endpoint in found.keys where !endpoints.contains(endpoint) { found[endpoint] = nil }
        publish()
    }

    /// UDP has no handshake, so a connection becomes ready as soon as the
    /// service resolves, which exposes the switcher's IP.
    private func resolve(_ endpoint: NWEndpoint, name: String) {
        let params = NWParameters.udp
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        let connection = NWConnection(to: endpoint, using: params)
        resolving[endpoint] = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard case .ready = state else {
                if case .failed = state { Task { @MainActor in self?.resolving[endpoint] = nil } }
                return
            }
            let remote = connection?.currentPath?.remoteEndpoint
            connection?.cancel()
            Task { @MainActor in
                guard let self else { return }
                self.resolving[endpoint] = nil
                if case let .hostPort(host, _) = remote {
                    var ip = "\(host)"
                    if let percent = ip.firstIndex(of: "%") { ip = String(ip[..<percent]) }
                    self.found[endpoint] = DiscoveredAtem(name: name, ip: ip)
                    self.publish()
                }
            }
        }
        connection.start(queue: .main)
    }

    private func publish() {
        var seen = Set<String>()
        devices = found.values.filter { seen.insert($0.ip).inserted }.sorted { $0.name < $1.name }
        onChange?(devices)
    }
}
