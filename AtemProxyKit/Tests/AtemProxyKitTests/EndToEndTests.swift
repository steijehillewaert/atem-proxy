@testable import AtemProxyKit
import Foundation
import Testing

/// Minimal ATEM switcher speaking the real protocol over loopback.
final class FakeAtem: @unchecked Sendable {
    let queue = DispatchQueue(label: "fake-atem")
    private var socket: UDPSocket!
    private var session: ReliableSession?
    private var peer: IPv4Endpoint?
    private var timer: DispatchSourceTimer?
    private var sentDump = false
    private var received: [RawCommand] = []
    let program: UInt8
    let product: String

    var endpoint: IPv4Endpoint { socket.localEndpoint! }

    init(product: String, program: UInt8) throws {
        self.program = program
        self.product = product
        socket = try UDPSocket(bind: IPv4Endpoint(ip: "127.0.0.1", port: 0)!, queue: queue) { [unowned self] bytes, from in
            self.receive(bytes, from: from)
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 0.002)
        timer.setEventHandler { [unowned self] in self.session?.tick(now: ProcessInfo.processInfo.systemUptime) }
        timer.resume()
        self.timer = timer
    }

    deinit { timer?.cancel() }

    var commandsReceived: [RawCommand] { queue.sync { received } }

    func send(_ command: RawCommand) {
        queue.async { self.session?.enqueue(payload: command.bytes) }
    }

    private func receive(_ bytes: [UInt8], from: IPv4Endpoint) {
        guard let packet = Packet(bytes: bytes) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if packet.flags.contains(.handshake) {
            peer = from
            sentDump = false
            session = ReliableSession(sessionId: 0x8001, now: now) { [unowned self] in self.socket.send($0, to: from) }
            socket.send(Packet(flags: .handshake, sessionId: packet.sessionId, payload: Handshake.serverPayload).bytes, to: from)
            return
        }
        guard from == peer, let session else { return }
        let payload = session.receive(packet, now: now)
        if session.isOpen && !sentDump {
            sentDump = true
            var name = Array(product.utf8)
            name += [UInt8](repeating: 0, count: 44 - name.count)
            let dump = [
                RawCommand(name: "_ver", body: [0, 2, 0, 0x20]),
                RawCommand(name: "_pin", body: name),
                RawCommand(name: "PrgI", body: [0, 0, 0, program]),
                RawCommand(name: "InCm", body: [1, 0, 0, 0]),
            ]
            session.enqueue(payloads: RawCommand.pack(dump.map(\.bytes)))
        }
        if let payload { received += RawCommand.parse(payload: payload) }
    }
}

/// Minimal ATEM client, e.g. ATEM Software Control.
final class FakeClient: @unchecked Sendable {
    let queue = DispatchQueue(label: "fake-client")
    private var socket: UDPSocket!
    private var session: ReliableSession!
    private var timer: DispatchSourceTimer?
    private var received: [RawCommand] = []
    private var connected = false
    private var lastHello = 0.0
    let server: IPv4Endpoint

    init(server: IPv4Endpoint) throws {
        self.server = server
        socket = try UDPSocket(bind: IPv4Endpoint(ip: "127.0.0.1", port: 0)!, queue: queue) { [unowned self] bytes, _ in
            self.receive(bytes)
        }
        let now = ProcessInfo.processInfo.systemUptime
        session = ReliableSession(sessionId: 0x1234, now: now) { [unowned self] in self.socket.send($0, to: server) }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 0.002)
        timer.setEventHandler { [unowned self] in
            let now = ProcessInfo.processInfo.systemUptime
            if !connected && now - lastHello > 0.2 {
                lastHello = now
                let hello = Packet(flags: .handshake, sessionId: 0x1234, unknown: 0x68, payload: Handshake.clientPayload)
                socket.send(hello.bytes, to: server)
            }
            session.tick(now: now)
        }
        timer.resume()
        self.timer = timer
    }

    deinit { timer?.cancel() }

    var commandsReceived: [RawCommand] { queue.sync { received } }

    func send(_ command: RawCommand) {
        queue.async { self.session.enqueue(payload: command.bytes) }
    }

    private func receive(_ bytes: [UInt8]) {
        guard let packet = Packet(bytes: bytes) else { return }
        if packet.flags.contains(.handshake) {
            connected = true
            session.sendAck(force: true)
            return
        }
        session.sessionId = packet.sessionId
        if let payload = session.receive(packet, now: ProcessInfo.processInfo.systemUptime) {
            received += RawCommand.parse(payload: payload)
        }
    }
}

func eventually(timeout: Double = 5, _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        guard Date() < deadline else {
            Issue.record("Timed out waiting for condition")
            return
        }
        try await Task.sleep(for: .milliseconds(20))
    }
}

@Suite(.serialized) struct EndToEndTests {
    @Test func proxiesStateAndCommandsForTwoAtems() async throws {
        let atemA = try FakeAtem(product: "ATEM Mini Extreme", program: 1)
        let atemB = try FakeAtem(product: "ATEM Constellation", program: 7)

                let proxyA = ProxyInstance(configuration: ProxyConfiguration(
            name: "A", atemHost: "127.0.0.1", atemPort: atemA.endpoint.port,
            listenIP: "127.0.0.1", listenPort: 0, advertise: false))
        let proxyB = ProxyInstance(configuration: ProxyConfiguration(
            name: "B", atemHost: "127.0.0.1", atemPort: atemB.endpoint.port,
            listenIP: "127.0.0.1", listenPort: 0, advertise: false))
        proxyA.start()
        proxyB.start()
        defer {
            proxyA.stopAndWait()
            proxyB.stopAndWait()
        }

        // Wait for the proxies to sync from their ATEMs, then connect two clients to A and one to B.
        try await eventually { proxyA.isSynchronized && proxyB.isSynchronized }
        let endpointA = proxyA.listenEndpoint!, endpointB = proxyB.listenEndpoint!
        let a1 = try FakeClient(server: endpointA)
        let a2 = try FakeClient(server: endpointA)
        let b1 = try FakeClient(server: endpointB)

        func program(_ client: FakeClient) -> UInt8? {
            client.commandsReceived.last { $0.name == "PrgI" }?.body.last
        }
        try await eventually { [a1, a2, b1].allSatisfy { $0.commandsReceived.contains { $0.name == "InCm" } } }
        #expect(program(a1) == 1)
        #expect(program(a2) == 1)
        #expect(program(b1) == 7)
        #expect(a1.commandsReceived.first?.name == "_ver")

        // Client command reaches only its own ATEM.
        a1.send(RawCommand(name: "CPgI", body: [0, 0, 0, 4]))
        try await eventually { atemA.commandsReceived.contains { $0.name == "CPgI" } }
        #expect(!atemB.commandsReceived.contains { $0.name == "CPgI" })

        // State change on the ATEM fans out to every client of that proxy.
        atemA.send(RawCommand(name: "PrgI", body: [0, 0, 0, 4]))
        try await eventually { program(a1) == 4 && program(a2) == 4 }
        #expect(program(b1) == 7)

        // A late client gets the updated state from the cache.
        let a3 = try FakeClient(server: endpointA)
        try await eventually { a3.commandsReceived.contains { $0.name == "InCm" } }
        #expect(program(a3) == 4)
        #expect(a3.commandsReceived.filter { $0.name == "PrgI" }.count == 1)
    }

    @Test func mediaTransferCommandsAreNotForwarded() async throws {
        let atem = try FakeAtem(product: "ATEM Mini", program: 1)
                let proxy = ProxyInstance(configuration: ProxyConfiguration(
            name: "T", atemHost: "127.0.0.1", atemPort: atem.endpoint.port,
            listenIP: "127.0.0.1", listenPort: 0, advertise: false))
        proxy.start()
        defer { proxy.stopAndWait() }
        try await eventually { proxy.isSynchronized }
        let port = proxy.listenEndpoint!.port

        let client = try FakeClient(server: IPv4Endpoint(ip: "127.0.0.1", port: port)!)
        try await eventually { client.commandsReceived.contains { $0.name == "InCm" } }
        client.send(RawCommand(name: "LOCK", body: [0, 0, 1, 0]))
        client.send(RawCommand(name: "CPvI", body: [0, 0, 0, 2]))
        try await eventually { atem.commandsReceived.contains { $0.name == "CPvI" } }
        #expect(!atem.commandsReceived.contains { $0.name == "LOCK" })
    }
}
