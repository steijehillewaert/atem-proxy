/// ATEM protocol version as sent in the `_ver` command (major << 16 | minor).
public struct ProtocolVersion: Sendable, Hashable, Comparable, CustomStringConvertible {
    public let rawValue: UInt32

    public init(rawValue: UInt32) { self.rawValue = rawValue }

    /// Oldest version LibAtem understands; used until `_ver` arrives.
    public static let minimum = ProtocolVersion(rawValue: CommandTable.knownVersions.first!.0)
    public static let latestKnown = ProtocolVersion(rawValue: CommandTable.knownVersions.last!.0)

    public var major: UInt16 { UInt16(rawValue >> 16) }
    public var minor: UInt16 { UInt16(rawValue & 0xFFFF) }

    /// Firmware release name, when the version is one LibAtem knows.
    public var firmwareName: String? {
        CommandTable.knownVersions.first { $0.0 == rawValue }?.1
    }

    public var isNewerThanKnown: Bool { self > Self.latestKnown }

    public var description: String {
        let base = "\(major).\(minor)"
        if let name = firmwareName { return "\(base) (\(name))" }
        return isNewerThanKnown ? "\(base) (newer than known)" : base
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Decodes the body of a `_ver` command.
    init?(versionCommandBody body: [UInt8]) {
        guard body.count >= 4 else { return nil }
        rawValue = UInt32(body[0]) << 24 | UInt32(body[1]) << 16 | UInt32(body[2]) << 8 | UInt32(body[3])
    }
}
