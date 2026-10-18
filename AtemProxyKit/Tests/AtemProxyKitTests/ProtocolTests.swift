@testable import AtemProxyKit
import Foundation
import Testing

@Suite struct PacketTests {
    @Test func roundTrip() {
        let packet = Packet(flags: [.ackRequest, .ackReply], sessionId: 0x8123, ackedId: 7, unknown: 0x68,
                            packetId: 0x1234, payload: [1, 2, 3])
        let bytes = packet.bytes
        #expect(bytes.count == 15)
        #expect(bytes[0] == (0x11 << 3))
        #expect(bytes[1] == 15)
        #expect(Packet(bytes: bytes) == packet)
    }

    @Test func rejectsShortDatagram() {
        #expect(Packet(bytes: [0, 1, 2]) == nil)
    }

    @Test func commandsParseAndPack() {
        let a = RawCommand(name: "PrgI", body: [0, 0, 0, 5])
        let b = RawCommand(name: "PrvI", body: [1, 0, 0, 6, 0, 0, 0, 0])
        #expect(RawCommand.parse(payload: a.bytes + b.bytes) == [a, b])

        let big = [UInt8](repeating: 0, count: 600)
        let commands = (0..<5).map { _ in RawCommand(name: "Test", body: big).bytes }
        let payloads = RawCommand.pack(commands)
        #expect(payloads.count == 3)
        #expect(payloads.allSatisfy { $0.count <= Packet.maxPayloadLength })
    }

    @Test func parseStopsAtGarbage() {
        let good = RawCommand(name: "PrgI", body: [0, 0, 0, 5]).bytes
        #expect(RawCommand.parse(payload: good + [0, 3, 0]).count == 1)
    }
}

@Suite struct ReliableSessionTests {
    final class Wire {
        var sent: [Packet] = []
        func transmit(_ bytes: [UInt8]) { sent.append(Packet(bytes: bytes)!) }
    }

    @Test func ackCoverageWraps() {
        #expect(ReliableSession.isCovered(packet: 5, byAck: 5))
        #expect(ReliableSession.isCovered(packet: 4, byAck: 5))
        #expect(!ReliableSession.isCovered(packet: 6, byAck: 5))
        #expect(ReliableSession.isCovered(packet: 32_760, byAck: 3))
        #expect(!ReliableSession.isCovered(packet: 3, byAck: 32_760))
        #expect(ReliableSession.increment(32_767) == 0)
    }

    @Test func deliversInOrderAndDropsGaps() {
        let wire = Wire()
        let session = ReliableSession(sessionId: 1, now: 0) { wire.transmit($0) }
        let p1 = Packet(flags: .ackRequest, sessionId: 1, packetId: 1, payload: [1])
        let p3 = Packet(flags: .ackRequest, sessionId: 1, packetId: 3, payload: [3])
        #expect(session.receive(p1, now: 0) == [1])
        #expect(session.receive(p3, now: 0) == nil)
        #expect(session.receive(p1, now: 0) == nil) // duplicate
        #expect(wire.sent.contains { $0.flags.contains(.ackReply) && $0.ackedId == 1 })
    }

    @Test func resendsUntilAcked() {
        let wire = Wire()
        let session = ReliableSession(sessionId: 1, now: 0) { wire.transmit($0) }
        session.enqueue(payload: [9])
        session.tick(now: 0)
        #expect(wire.sent.count == 1)
        session.tick(now: 0.01)
        #expect(wire.sent.count == 1)
        session.tick(now: 0.05)
        #expect(wire.sent.count == 2)
        #expect(wire.sent[1].flags.contains(.retransmit))
        _ = session.receive(Packet(flags: .ackReply, sessionId: 1, ackedId: wire.sent[0].packetId), now: 0.06)
        #expect(session.isOpen)
        #expect(!session.hasPendingOutbound)
    }

    @Test func resendsWholeWindowInOrder() {
        let wire = Wire()
        let session = ReliableSession(sessionId: 1, now: 0) { wire.transmit($0) }
        session.enqueue(payload: [1])
        session.tick(now: 0)
        session.enqueue(payload: [2])
        session.tick(now: 0.02)
        #expect(wire.sent.count == 2)
        // The oldest packet is overdue: the receiver dropped everything after it, so both go again.
        session.tick(now: 0.035)
        #expect(wire.sent.count == 4)
        #expect(wire.sent[2...].map(\.payload) == [[1], [2]])
        #expect(wire.sent[2...].allSatisfy { $0.flags.contains(.retransmit) })
    }

    @Test func deadlineFollowsPendingWork() {
        let wire = Wire()
        let session = ReliableSession(sessionId: 1, now: 0) { wire.transmit($0) }
        #expect(session.nextDeadline == nil)
        session.enqueue(payload: [1])
        #expect(session.nextDeadline == -.infinity) // send right away
        session.tick(now: 1)
        #expect(session.nextDeadline == 1 + ReliableSession.resendAfter)
        _ = session.receive(Packet(flags: .ackReply, sessionId: 1, ackedId: wire.sent[0].packetId), now: 1.001)
        #expect(session.nextDeadline == nil)

        // A received packet whose ack is delayed for batching.
        _ = session.receive(Packet(flags: .ackRequest, sessionId: 1, packetId: 1, payload: [7]), now: 2)
        _ = session.receive(Packet(flags: .ackRequest, sessionId: 1, packetId: 2, payload: [8]), now: 2.001)
        #expect(session.nextDeadline == 2.001 + ReliableSession.ackDelay)
    }

    @Test func limitsInFlight() {
        let wire = Wire()
        let session = ReliableSession(sessionId: 1, now: 0) { wire.transmit($0) }
        for i in 0..<40 { session.enqueue(payload: [UInt8(i)]) }
        session.tick(now: 0)
        #expect(wire.sent.count == ReliableSession.maxInFlight)
    }

    @Test func timesOut() {
        let session = ReliableSession(sessionId: 1, now: 0) { _ in }
        #expect(!session.hasTimedOut(now: 0.5))
        #expect(session.hasTimedOut(now: 1.5))
    }
}

@Suite struct IdentityTests {
    /// WhoI as sent by a 2 M/E Constellation HD on 9.6.
    static func constellationWhoI() -> [UInt8] {
        func field(_ text: String, _ length: Int) -> [UInt8] {
            Array(text.utf8) + [UInt8](repeating: 0, count: length - text.utf8.count)
        }
        return field("e211f3c4cc0449a89100af8913c7c3e1", 32) + field("10.80.40.114", 16)
            + field("ATEM-2-ME-Constellation-HD.local", 64) + field("ATEM 2 M/E Constellation HD", 64)
    }

    @Test func whoIAnswersAsTheProxy() {
        let body = ProxyInstance.identify(Self.constellationWhoI(), uniqueId: "2e1bebe2e1694164b8864b71b500243f",
                                          ip: "10.80.40.115", host: "atem-proxy-10-80-40-115.local")
        func text(_ range: Range<Int>) -> String {
            String(decoding: body[range].prefix { $0 != 0 }, as: UTF8.self)
        }
        #expect(body.count == 176)
        #expect(text(0..<32) == "2e1bebe2e1694164b8864b71b500243f")
        #expect(text(32..<48) == "10.80.40.115")
        #expect(text(48..<112) == "atem-proxy-10-80-40-115.local")
        #expect(text(112..<176) == "ATEM 2 M/E Constellation HD")
    }

    @Test func deviceUniqueIdUsesTheAtemFormat() {
        let configuration = ProxyConfiguration(id: UUID(uuidString: "2E1BEBE2-E169-4164-B886-4B71B500243F")!,
                                               name: "A", atemHost: "10.80.40.114")
        #expect(configuration.deviceUniqueId == "2e1bebe2e1694164b8864b71b500243f")
    }
}

@Suite struct FreeAddressTests {
    @Test func candidatesStartNextToTheAtem() {
        let candidates = FreeAddress.candidates(base: "10.80.40.122", near: "10.80.40.114")
        #expect(Array(candidates.prefix(4)) == ["10.80.40.115", "10.80.40.113", "10.80.40.116", "10.80.40.112"])
        #expect(candidates.contains("10.80.40.250"))
        #expect(!candidates.contains("10.80.40.255") && !candidates.contains("10.80.40.0"))
    }

    @Test func candidatesStayInsideTheRange() {
        let candidates = FreeAddress.candidates(base: "192.168.1.10", near: "192.168.1.254")
        #expect(candidates.first == "192.168.1.253")
        #expect(candidates.allSatisfy { Int($0.split(separator: ".")[3])! <= 254 })
    }

    @Test func atemOnAnotherNetworkFallsBackToTopOfRange() {
        #expect(FreeAddress.candidates(base: "10.80.40.122", near: "192.168.10.240").first == "10.80.40.250")
    }

    @Test func picksTheInterfaceOnTheAtemsNetwork() {
        let addresses = [
            LocalInterfaceAddress(interface: "en1", ip: "192.168.0.146", netmask: "255.255.255.0"),
            LocalInterfaceAddress(interface: "en0", ip: "10.80.40.115", netmask: IPAlias.netmask),
            LocalInterfaceAddress(interface: "en0", ip: "10.80.40.122", netmask: "255.255.255.0"),
        ]
        #expect(FreeAddress.interface(reaching: "10.80.40.114", in: addresses)?.ip == "10.80.40.122")
        #expect(FreeAddress.interface(reaching: "172.16.0.1", in: addresses) == nil)
    }
}

@Suite struct StateKeyTests {
    let version = ProtocolVersion.latestKnown

    @Test func keysByCommandId() {
        // PrgI: mix effect index at byte 0 identifies the state.
        let me1 = StateKey(command: RawCommand(name: "PrgI", body: [0, 0, 0, 1]), version: version)
        let me1Changed = StateKey(command: RawCommand(name: "PrgI", body: [0, 0, 0, 2]), version: version)
        let me2 = StateKey(command: RawCommand(name: "PrgI", body: [1, 0, 0, 1]), version: version)
        #expect(me1 == me1Changed)
        #expect(me1 != me2)
    }

    @Test func singletonCommandHasEmptyId() {
        let key = StateKey(command: RawCommand(name: "_ver", body: [0, 2, 0, 32]), version: version)
        #expect(key.id.isEmpty)
    }

    @Test func unknownCommandUsesLeadingBytes() {
        let a = StateKey(command: RawCommand(name: "Zzzz", body: [1, 2, 3, 4, 5]), version: version)
        let b = StateKey(command: RawCommand(name: "Zzzz", body: [1, 2, 3, 4, 9]), version: version)
        #expect(a == b)
    }

    @Test func cacheKeepsLatestInFirstSeenOrder() {
        var cache = StateCache()
        let first = RawCommand(name: "PrgI", body: [0, 0, 0, 1])
        let other = RawCommand(name: "PrvI", body: [0, 0, 0, 2, 0, 0, 0, 0])
        let updated = RawCommand(name: "PrgI", body: [0, 0, 0, 3])
        for command in [first, other, updated] {
            cache.set(StateKey(command: command, version: version), encoded: command.bytes)
        }
        #expect(cache.encodedCommands() == [updated.bytes, other.bytes])
    }

    @Test func unknownCommandKeyGrowsWhenDumpCollides() {
        // Like the Constellation's KBfT: a 4-byte tag, then the index that tells items apart.
        var cache = StateCache()
        let a0 = RawCommand(name: "Zzzz", body: Array("TrPs".utf8) + [0, 0, 0x77, 0x19])
        let a1 = RawCommand(name: "Zzzz", body: Array("TrPs".utf8) + [0, 1, 0xE8, 0x19])
        let a1Updated = RawCommand(name: "Zzzz", body: Array("TrPs".utf8) + [0, 1, 0x00, 0x00])
        cache.set(a0, version: version, learning: true)
        cache.set(a1, version: version, learning: true)
        #expect(cache.encodedCommands() == [a0.bytes, a1.bytes])

        // After the dump, updates replace their own item instead of adding entries.
        cache.set(a1Updated, version: version, learning: false)
        #expect(cache.encodedCommands() == [a0.bytes, a1Updated.bytes])
    }

    @Test func versionDecoding() {
        let v = ProtocolVersion(versionCommandBody: [0, 2, 0, 0x20])!
        #expect(v.major == 2 && v.minor == 32)
        #expect(v.firmwareName == "v9.6.0")
        #expect(ProtocolVersion(rawValue: 0x0002_0021).isNewerThanKnown)
    }
}

@Suite struct ConfigurationTests {
    @Test func detectsClashes() {
        let a = ProxyConfiguration(name: "A", atemHost: "10.0.0.1", listenIP: "10.0.0.50")
        let b = ProxyConfiguration(name: "B", atemHost: "10.0.0.2", listenIP: "10.0.0.50")
        let c = ProxyConfiguration(name: "C", atemHost: "10.0.0.3", listenIP: "10.0.0.51")
        let d = ProxyConfiguration(name: "D", atemHost: "10.0.0.4")
        #expect(!a.validationErrors(among: [a, b]).isEmpty)
        #expect(a.validationErrors(among: [a, c, d]).isEmpty)
        #expect(!ProxyConfiguration(name: "", atemHost: "").validationErrors(among: []).isEmpty)
    }
}

@Suite struct ConfigurationCodingTests {
    @Test func decodesConfigurationsSavedBeforeAliasInterface() throws {
        let json = #"[{"id":"6F1B2C3D-0000-4000-8000-000000000001","name":"A","atemHost":"10.0.0.1","atemPort":9910,"listenPort":9910,"advertise":true,"autoStart":true}]"#
        let decoded = try JSONDecoder().decode([ProxyConfiguration].self, from: Data(json.utf8))
        #expect(decoded.first?.aliasInterface == nil)
        #expect(decoded.first?.listenIP == nil)
    }

    @Test func roundTrips() throws {
        let config = ProxyConfiguration(name: "B", atemHost: "10.0.0.2", listenIP: "10.0.0.201", aliasInterface: "en0")
        let decoded = try JSONDecoder().decode(ProxyConfiguration.self, from: JSONEncoder().encode(config))
        #expect(decoded == config)
    }
}
