import Foundation
import os

/// Proxies one ATEM: holds a single upstream connection to the switcher and
/// serves any number of ATEM clients on the configured local address.
///
/// The proxy never decodes command contents. It forwards raw commands both ways,
/// keeps the latest value of each piece of state to replay to new clients, and
/// filters the few commands that can't be shared between clients.
///
/// All state lives on a private serial queue; the public API is thread safe.
public final class ProxyInstance: @unchecked Sendable {
    public let configuration: ProxyConfiguration

    /// Called on the main queue with the latest status, at most a few times per second.
    public var onStatus: (@MainActor @Sendable (ProxyStatus) -> Void)?
    /// Called on the main queue for each log line.
    public var onLog: (@MainActor @Sendable (ProxyLogEntry) -> Void)?

    private static let tickInterval = 0.002
    private static let reconnectInterval = 1.0
    private static let clientPingInterval = 0.2
    private static let statusInterval = 0.25
    private static let initCompleteCommand = "InCm"
    private static let versionCommand = "_ver"
    private static let productCommand = "_pin"

    private let queue: DispatchQueue
    private let logger: Logger
    private var timer: DispatchSourceTimer?
    private var running = false

    // Upstream
    private var upstreamSocket: UDPSocket?
    private var atem: IPv4Endpoint?
    private var upstream: ReliableSession?
    private var lastHandshake = -Double.infinity
    private var version = ProtocolVersion.minimum
    private var stateReady = false
    private var cache = StateCache()
    private var unknownNames: Set<String> = []

    // Clients
    private struct Client {
        let session: ReliableSession
        let connectedAt: Date
        var synchronized = false
        var lastPing: Double
    }
    private var listenSocket: UDPSocket?
    private var clients: [IPv4Endpoint: Client] = [:]
    private var audioSubscribers: Set<IPv4Endpoint> = []
    private var audioSubscribeCommand = CommandTable.fairlightAudioSubscribe
    private var nextServerSessionId: UInt16 = 0
    private var advertiser: BonjourAdvertiser?

    private var status = ProxyStatus()
    private var lastStatusPublish = -Double.infinity
    private var statusDirty = false

    public init(configuration: ProxyConfiguration) {
        self.configuration = configuration
        queue = DispatchQueue(label: "be.steije.atemproxy.\(configuration.id.uuidString.prefix(8))", qos: .userInitiated)
        logger = Logger(subsystem: "be.steije.atemproxy", category: configuration.name)
    }

    deinit {
        timer?.cancel()
        upstreamSocket?.close()
        listenSocket?.close()
    }

    // MARK: - Public API

    public func start() {
        queue.async { self.startOnQueue() }
    }

    public func stop() {
        queue.async { self.stopOnQueue() }
    }

    /// Stops and waits until sockets are closed, so a replacement can bind the same address.
    public func stopAndWait() {
        queue.sync { self.stopOnQueue() }
    }

    /// Whether the proxy holds a full copy of the ATEM state and accepts clients.
    var isSynchronized: Bool { queue.sync { stateReady } }

    /// Address clients connect to; resolves port 0 to the port actually bound.
    var listenEndpoint: IPv4Endpoint? { queue.sync { listenSocket?.localEndpoint } }

    // MARK: - Lifecycle

    private var now: Double { ProcessInfo.processInfo.systemUptime }

    private func startOnQueue() {
        guard !running else { return }
        running = true
        status = ProxyStatus()
        status.upstream = .resolving

        let listen: IPv4Endpoint
        if let ip = configuration.listenIP {
            guard let endpoint = IPv4Endpoint(ip: ip, port: configuration.listenPort) else {
                fail("Invalid listen address \(ip)")
                return
            }
            listen = endpoint
        } else {
            listen = .any(port: configuration.listenPort)
        }

        do {
            listenSocket = try UDPSocket(bind: listen, queue: queue) { [weak self] bytes, from in
                self?.receiveFromClient(bytes, from: from)
            }
            upstreamSocket = try UDPSocket(bind: .any(port: 0), queue: queue) { [weak self] bytes, from in
                self?.receiveFromAtem(bytes, from: from)
            }
            status.listening = listen.description
            log(.info, "Listening for clients on \(listen)")
        } catch {
            status.listenError = "\(error)"
            fail("\(error)")
            return
        }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: Self.tickInterval, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer

        resolveAtem()
        publishStatus(force: true)
    }

    private func stopOnQueue() {
        guard running else { return }
        running = false
        timer?.cancel()
        timer = nil
        advertiser?.stop()
        advertiser = nil
        dropAllClients()
        upstreamSocket?.close()
        upstreamSocket = nil
        listenSocket?.close()
        listenSocket = nil
        upstream = nil
        atem = nil
        resetUpstreamState()
        status = ProxyStatus()
        log(.info, "Stopped")
        publishStatus(force: true)
    }

    private func fail(_ message: String) {
        log(.error, message)
        let listenError = status.listenError
        stopOnQueue()
        status.upstream = .failed(message)
        status.listenError = listenError
        publishStatus(force: true)
    }

    private func resolveAtem() {
        let host = configuration.atemHost.trimmingCharacters(in: .whitespaces)
        let port = configuration.atemPort
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let endpoint = resolveIPv4(host: host, port: port)
            guard let instance = self else { return }
            instance.queue.async { [weak instance] in
                guard let self = instance, self.running else { return }
                guard let endpoint else {
                    self.log(.warning, "Can't resolve \(host), retrying")
                    self.queue.asyncAfter(deadline: .now() + Self.reconnectInterval) { [weak self] in
                        guard let self, self.running, self.atem == nil else { return }
                        self.resolveAtem()
                    }
                    return
                }
                self.atem = endpoint
                self.status.atemEndpoint = endpoint.description
                self.status.upstream = .connecting
                self.log(.info, "Connecting to ATEM at \(endpoint)")
                self.publishStatus(force: true)
            }
        }
    }

    // MARK: - Timer

    private func tick() {
        let now = self.now
        tickUpstream(now: now)
        tickClients(now: now)
        if statusDirty || now - lastStatusPublish > 1 { publishStatus() }
    }

    private func tickUpstream(now: Double) {
        guard let atem, let socket = upstreamSocket else { return }
        if let upstream, !upstream.hasTimedOut(now: now) {
            upstream.tick(now: now)
            return
        }
        guard now - lastHandshake >= Self.reconnectInterval else { return }

        if upstream != nil, stateReady {
            log(.warning, "Lost connection to ATEM")
        }
        resetUpstreamState()
        if status.upstream != .rejected { status.upstream = .connecting }
        markDirty()

        let sessionId = UInt16.random(in: 1..<0x7FFF)
        upstream = ReliableSession(sessionId: sessionId, now: now) { [weak socket] bytes in
            socket?.send(bytes, to: atem)
        }
        lastHandshake = now
        let hello = Packet(flags: .handshake, sessionId: sessionId, unknown: 0x0068,
                           payload: Handshake.clientPayload)
        socket.send(hello.bytes, to: atem)
    }

    private func tickClients(now: Double) {
        var lost: [IPv4Endpoint] = []
        for (endpoint, client) in clients {
            if client.session.hasTimedOut(now: now) {
                lost.append(endpoint)
                continue
            }
            if client.synchronized, !client.session.hasPendingOutbound,
               now - client.lastPing >= Self.clientPingInterval {
                client.session.enqueuePing()
                clients[endpoint]?.lastPing = now
            }
            client.session.tick(now: now)
        }
        for endpoint in lost {
            log(.info, "Client \(endpoint) disconnected")
            removeClient(endpoint)
        }
    }

    // MARK: - Upstream

    private func resetUpstreamState() {
        let hadClients = !clients.isEmpty
        stateReady = false
        version = .minimum
        cache.removeAll()
        unknownNames.removeAll()
        status.protocolVersion = nil
        status.productName = nil
        status.cachedStateEntries = 0
        advertiser?.stop()
        advertiser = nil
        if hadClients {
            // Clients reconnect, and get a fresh state dump, once the ATEM is back.
            dropAllClients()
        }
    }

    private func receiveFromAtem(_ bytes: [UInt8], from: IPv4Endpoint) {
        guard from == atem, let upstream, let packet = Packet(bytes: bytes) else { return }
        let now = self.now

        if packet.flags.contains(.handshake) {
            switch packet.payload.first {
            case Handshake.accepted:
                upstream.sendAck(force: true)
                status.upstream = .synchronizing
                log(.info, "ATEM accepted connection")
            case Handshake.rejected:
                status.upstream = .rejected
                log(.warning, "ATEM rejected connection: no free connection slots")
            default:
                log(.warning, "Unexpected handshake reply \(packet.payload.first.map { String($0) } ?? "-")")
            }
            markDirty()
            return
        }

        if upstream.sessionId != packet.sessionId {
            upstream.sessionId = packet.sessionId
        }
        guard let payload = upstream.receive(packet, now: now), !payload.isEmpty else { return }
        handleFromAtem(RawCommand.parse(payload: payload))
    }

    private func handleFromAtem(_ commands: [RawCommand]) {
        var broadcast: [[UInt8]] = []
        var levels: [[UInt8]] = []

        for command in commands {
            status.commandsFromAtem += 1
            switch command.name {
            case Self.versionCommand:
                if let v = ProtocolVersion(versionCommandBody: command.body) {
                    version = v
                    status.protocolVersion = v
                    log(v.isNewerThanKnown ? .warning : .info,
                        "ATEM protocol \(v)" + (v.isNewerThanKnown ? ". Unknown commands are forwarded as-is." : ""))
                }
            case Self.productCommand:
                let name = String(decoding: command.body.prefix(40).prefix { $0 != 0 }, as: UTF8.self)
                status.productName = name
            default:
                break
            }

            if CommandTable.audioLevelCommands.contains(command.name) {
                levels.append(command.bytes)
                continue
            }
            if CommandTable.lockCommands.contains(command.name) || CommandTable.transferCommands.contains(command.name) {
                continue
            }
            if command.name == Self.initCompleteCommand {
                if !stateReady {
                    stateReady = true
                    status.upstream = .connected
                    log(.info, "Synchronized \(cache.count) state entries from \(status.productName ?? "ATEM")")
                    startAdvertising()
                }
                continue
            }

            if CommandTable.stateKeys[command.name] == nil, unknownNames.insert(command.name).inserted {
                status.unknownCommandNames = unknownNames.sorted()
                log(.debug, "Forwarding unknown command \(command.name)")
            }
            let encoded = command.bytes
            cache.set(StateKey(command: command, version: version), encoded: encoded)
            broadcast.append(encoded)
        }
        status.cachedStateEntries = cache.count
        markDirty()

        if !broadcast.isEmpty {
            let payloads = RawCommand.pack(broadcast)
            for client in clients.values where client.synchronized {
                client.session.enqueue(payloads: payloads)
            }
        }
        if !levels.isEmpty, !audioSubscribers.isEmpty {
            let payloads = RawCommand.pack(levels)
            for endpoint in audioSubscribers {
                guard let client = clients[endpoint], client.synchronized else { continue }
                client.session.enqueue(payloads: payloads)
            }
        }
    }

    private func sendToAtem(_ encoded: [[UInt8]]) {
        guard let upstream, stateReady, !encoded.isEmpty else { return }
        status.commandsToAtem += encoded.count
        upstream.enqueue(payloads: RawCommand.pack(encoded))
    }

    // MARK: - Clients

    private func receiveFromClient(_ bytes: [UInt8], from: IPv4Endpoint) {
        guard let packet = Packet(bytes: bytes) else { return }
        let now = self.now

        if packet.flags.contains(.handshake) {
            // Like the C# proxy: only accept clients once there is state to give them.
            guard stateReady, let socket = listenSocket else { return }
            if clients[from] != nil { removeClient(from) }

            nextServerSessionId = (nextServerSessionId &+ 1) & 0x7FFF
            let serverSession = 0x8000 | nextServerSessionId
            let session = ReliableSession(sessionId: serverSession, now: now) { [weak socket] bytes in
                socket?.send(bytes, to: from)
            }
            clients[from] = Client(session: session, connectedAt: Date(), lastPing: now)

            let reply = Packet(flags: .handshake, sessionId: packet.sessionId, unknown: packet.unknown,
                               payload: Handshake.serverPayload)
            socket.send(reply.bytes, to: from)
            log(.info, "Client \(from) connected")
            markDirty()
            return
        }

        guard let client = clients[from] else { return }
        let payload = client.session.receive(packet, now: now)

        if client.session.isOpen && !client.synchronized {
            // First ack from the client: send it the full state, like a real ATEM would.
            var dump = cache.encodedCommands()
            dump.append(RawCommand(name: Self.initCompleteCommand, body: [0, 0, 0, 0]).bytes)
            client.session.enqueue(payloads: RawCommand.pack(dump))
            clients[from]?.synchronized = true
            markDirty()
        }

        guard let payload, !payload.isEmpty else { return }
        handleFromClient(RawCommand.parse(payload: payload), from: from)
    }

    private func handleFromClient(_ commands: [RawCommand], from: IPv4Endpoint) {
        var forward: [[UInt8]] = []
        for command in commands {
            switch command.name {
            case CommandTable.legacyAudioSubscribe, CommandTable.fairlightAudioSubscribe:
                let subscribe = command.body.first.map { $0 != 0 } ?? false
                audioSubscribeCommand = command.name
                let wasEmpty = audioSubscribers.isEmpty
                if subscribe { audioSubscribers.insert(from) } else { audioSubscribers.remove(from) }
                // Only the first subscriber and the last unsubscriber change what the ATEM sends.
                if wasEmpty != audioSubscribers.isEmpty { forward.append(command.bytes) }
                markDirty()
            case _ where CommandTable.lockCommands.contains(command.name),
                 _ where CommandTable.transferCommands.contains(command.name):
                // Media transfers and locks are per connection; can't be shared through one upstream link.
                log(.debug, "Ignoring \(command.name) from \(from): media transfers aren't proxied")
            default:
                forward.append(command.bytes)
            }
        }
        sendToAtem(forward)
    }

    private func removeClient(_ endpoint: IPv4Endpoint) {
        clients[endpoint] = nil
        if audioSubscribers.remove(endpoint) != nil, audioSubscribers.isEmpty {
            sendToAtem([RawCommand(name: audioSubscribeCommand, body: [0, 0, 0, 0]).bytes])
        }
        markDirty()
    }

    private func dropAllClients() {
        clients.removeAll()
        audioSubscribers.removeAll()
        markDirty()
    }

    // MARK: - Bonjour

    private func startAdvertising() {
        guard configuration.advertise, advertiser == nil else { return }
        advertiser = BonjourAdvertiser(
            name: configuration.name,
            productName: status.productName,
            listenIP: configuration.listenIP,
            port: configuration.listenPort,
            uniqueId: configuration.id.uuidString,
            queue: queue
        ) { [weak self] message in self?.log(.warning, message) }
    }

    // MARK: - Status & logging

    private func markDirty() { statusDirty = true }

    private func publishStatus(force: Bool = false) {
        let now = self.now
        guard force || now - lastStatusPublish >= Self.statusInterval else { return }
        lastStatusPublish = now
        statusDirty = false

        var snapshot = status
        snapshot.clients = clients.map { endpoint, client in
            ProxyStatus.Client(endpoint: endpoint.description, connectedAt: client.connectedAt,
                               isSynchronized: client.synchronized,
                               receivesAudioLevels: audioSubscribers.contains(endpoint),
                               packetsSent: client.session.packetsSent,
                               packetsReceived: client.session.packetsReceived,
                               packetsResent: client.session.packetsResent)
        }.sorted { $0.connectedAt < $1.connectedAt }

        guard let onStatus else { return }
        DispatchQueue.main.async { onStatus(snapshot) }
    }

    private func log(_ level: ProxyLogEntry.Level, _ message: String) {
        switch level {
        case .debug: logger.debug("\(message, privacy: .public)")
        case .info: logger.info("\(message, privacy: .public)")
        case .warning: logger.warning("\(message, privacy: .public)")
        case .error: logger.error("\(message, privacy: .public)")
        }
        guard let onLog else { return }
        let entry = ProxyLogEntry(date: Date(), level: level, message: message)
        DispatchQueue.main.async { onLog(entry) }
    }
}

enum Handshake {
    static let accepted: UInt8 = 0x02
    static let rejected: UInt8 = 0x03
    static let clientPayload: [UInt8] = [0x01, 0x00, 0x00, 0x08, 0x00, 0x00, 0x00, 0x00]
    static let serverPayload: [UInt8] = [0x02, 0x00, 0x00, 0x08, 0x00, 0x00, 0x00, 0x00]
}
