/// Header flags of an ATEM UDP packet (top 5 bits of the first byte).
public struct PacketFlags: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let ackRequest = PacketFlags(rawValue: 1 << 0)
    public static let handshake = PacketFlags(rawValue: 1 << 1)
    public static let retransmit = PacketFlags(rawValue: 1 << 2)
    public static let retransmitRequest = PacketFlags(rawValue: 1 << 3)
    public static let ackReply = PacketFlags(rawValue: 1 << 4)
}

/// One ATEM protocol datagram.
///
/// ```
/// 0      1      2      3      4      5      6      7      8      9      10     11
/// flags|length  session id    acked id      retransmit id  unknown       packet id
/// ```
public struct Packet: Sendable, Equatable {
    public static let headerLength = 12
    public static let maxLength = 1400
    public static let maxPayloadLength = maxLength - headerLength

    public var flags: PacketFlags
    public var sessionId: UInt16
    public var ackedId: UInt16
    public var retransmitFromId: UInt16
    public var unknown: UInt16
    public var packetId: UInt16
    public var payload: [UInt8]

    public init(flags: PacketFlags, sessionId: UInt16, ackedId: UInt16 = 0, retransmitFromId: UInt16 = 0,
                unknown: UInt16 = 0, packetId: UInt16 = 0, payload: [UInt8] = []) {
        self.flags = flags
        self.sessionId = sessionId
        self.ackedId = ackedId
        self.retransmitFromId = retransmitFromId
        self.unknown = unknown
        self.packetId = packetId
        self.payload = payload
    }

    /// Parses a datagram. Returns nil when it is too short to be a packet.
    public init?(bytes raw: [UInt8]) {
        guard raw.count >= Self.headerLength else { return nil }
        flags = PacketFlags(rawValue: raw[0] >> 3)
        let declared = (Int(raw[0] & 0x07) << 8) | Int(raw[1])
        let length = min(max(declared, Self.headerLength), raw.count)
        sessionId = UInt16(raw[2]) << 8 | UInt16(raw[3])
        ackedId = UInt16(raw[4]) << 8 | UInt16(raw[5])
        retransmitFromId = UInt16(raw[6]) << 8 | UInt16(raw[7])
        unknown = UInt16(raw[8]) << 8 | UInt16(raw[9])
        packetId = UInt16(raw[10]) << 8 | UInt16(raw[11])
        payload = Array(raw[Self.headerLength..<length])
    }

    public var bytes: [UInt8] {
        let length = Self.headerLength + payload.count
        var out: [UInt8] = [
            flags.rawValue << 3 | UInt8((length >> 8) & 0x07), UInt8(length & 0xFF),
            UInt8(sessionId >> 8), UInt8(sessionId & 0xFF),
            UInt8(ackedId >> 8), UInt8(ackedId & 0xFF),
            UInt8(retransmitFromId >> 8), UInt8(retransmitFromId & 0xFF),
            UInt8(unknown >> 8), UInt8(unknown & 0xFF),
            UInt8(packetId >> 8), UInt8(packetId & 0xFF),
        ]
        out.reserveCapacity(length)
        out.append(contentsOf: payload)
        return out
    }
}

/// A single command inside a packet payload, kept as opaque bytes.
///
/// ```
/// 0      1      2      3      4 .. 7       8 ..
/// length        unknown       name (ASCII) body
/// ```
public struct RawCommand: Sendable, Equatable {
    public static let headerLength = 8

    public var name: String
    public var body: [UInt8]

    public init(name: String, body: [UInt8]) {
        precondition(name.utf8.count == 4, "ATEM command names are four characters")
        self.name = name
        self.body = body
    }

    public var bytes: [UInt8] {
        let length = Self.headerLength + body.count
        var out: [UInt8] = [UInt8((length >> 8) & 0xFF), UInt8(length & 0xFF), 0, 0]
        out.reserveCapacity(length)
        out.append(contentsOf: name.utf8)
        out.append(contentsOf: body)
        return out
    }

    /// Splits a packet payload into commands. Stops at the first malformed command.
    public static func parse(payload: [UInt8]) -> [RawCommand] {
        var result: [RawCommand] = []
        var offset = 0
        while offset + headerLength <= payload.count {
            let length = Int(payload[offset]) << 8 | Int(payload[offset + 1])
            guard length >= headerLength, offset + length <= payload.count else { break }
            let nameBytes = payload[(offset + 4)..<(offset + 8)]
            guard nameBytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { break }
            let name = String(decoding: nameBytes, as: UTF8.self)
            result.append(RawCommand(name: name, body: Array(payload[(offset + 8)..<(offset + length)])))
            offset += length
        }
        return result
    }

    /// Packs encoded commands into as few payloads as fit in a packet.
    /// A single command larger than a packet is sent on its own.
    public static func pack(_ encoded: [[UInt8]]) -> [[UInt8]] {
        var payloads: [[UInt8]] = []
        var current: [UInt8] = []
        for command in encoded {
            if !current.isEmpty && current.count + command.count > Packet.maxPayloadLength {
                payloads.append(current)
                current = []
            }
            current.append(contentsOf: command)
        }
        if !current.isEmpty { payloads.append(current) }
        return payloads
    }
}
