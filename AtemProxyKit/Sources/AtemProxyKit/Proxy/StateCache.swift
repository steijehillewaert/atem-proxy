/// Identifying bytes of a command, from LibAtem's `[CommandId]` properties.
struct KeyRange: Sendable {
    let offset: Int
    let length: Int
    init(_ offset: Int, _ length: Int) {
        self.offset = offset
        self.length = length
    }
}

/// What piece of switcher state a command describes.
struct StateKey: Hashable, Sendable {
    let name: String
    let id: [UInt8]

    /// Bytes used to key commands LibAtem does not know (e.g. from newer firmware).
    /// Most ATEM commands start with their index fields, so this keeps one value per
    /// index without growing forever as values change.
    static let unknownCommandIdBytes = 4

    init(name: String, id: [UInt8]) {
        self.name = name
        self.id = id
    }

    init(command: RawCommand, version: ProtocolVersion) {
        name = command.name
        guard let ranges = Self.ranges(for: command.name, version: version) else {
            id = Array(command.body.prefix(Self.unknownCommandIdBytes))
            return
        }
        var bytes: [UInt8] = []
        for range in ranges {
            let end = min(range.offset + range.length, command.body.count)
            if range.offset < end { bytes.append(contentsOf: command.body[range.offset..<end]) }
        }
        id = bytes
    }

    static func ranges(for name: String, version: ProtocolVersion) -> [KeyRange]? {
        guard let options = CommandTable.stateKeys[name] else { return nil }
        // Pick the newest layout valid for this version; fall back to the oldest.
        return (options.last { $0.0 <= version.rawValue } ?? options.first)?.1
    }
}

/// Latest value of every piece of switcher state, in first-seen order.
/// Replayed to each client when it connects, as the ATEM would.
struct StateCache {
    private var order: [StateKey] = []
    private var values: [StateKey: [UInt8]] = [:]

    var count: Int { order.count }

    mutating func removeAll() {
        order.removeAll()
        values.removeAll()
    }

    mutating func set(_ key: StateKey, encoded: [UInt8]) {
        if values.updateValue(encoded, forKey: key) == nil {
            order.append(key)
        }
    }

    func encodedCommands() -> [[UInt8]] {
        order.compactMap { values[$0] }
    }
}
