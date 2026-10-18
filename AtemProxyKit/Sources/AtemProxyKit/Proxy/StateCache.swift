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

    /// Longest key `StateCache` grows an unknown command's key to.
    static let maxUnknownCommandIdBytes = 16

    init(command: RawCommand, version: ProtocolVersion, unknownIdLength: Int = unknownCommandIdBytes) {
        name = command.name
        guard let ranges = Self.ranges(for: command.name, version: version) else {
            id = Array(command.body.prefix(unknownIdLength))
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
    /// Key length per unknown command, where the default turned out too short.
    private var unknownIdLengths: [String: Int] = [:]

    var count: Int { order.count }

    mutating func removeAll() {
        order.removeAll()
        values.removeAll()
        unknownIdLengths.removeAll()
    }

    /// Stores the latest value of `command`.
    ///
    /// While `learning` (the ATEM's initial state dump, which holds each piece of state once),
    /// two different bodies under one key of an unknown command mean its key is too short:
    /// the 2 M/E Constellation sends 32 `KBfT` that share their first 4 bytes, and replaying
    /// only the last one lost state. The key then grows until the two bodies differ.
    mutating func set(_ command: RawCommand, version: ProtocolVersion, learning: Bool) {
        let encoded = command.bytes
        var key = key(for: command, version: version)
        if learning, CommandTable.stateKeys[command.name] == nil,
           let existing = values[key], existing != encoded {
            let body = existing.dropFirst(RawCommand.headerLength)
            let differsAt = zip(body, command.body).enumerated().first { $0.element.0 != $0.element.1 }?.offset
                ?? min(body.count, command.body.count)
            let length = differsAt + 1
            if length > key.id.count, length <= StateKey.maxUnknownCommandIdBytes {
                rekey(command.name, idLength: length)
                key = self.key(for: command, version: version)
            }
        }
        set(key, encoded: encoded)
    }

    private func key(for command: RawCommand, version: ProtocolVersion) -> StateKey {
        StateKey(command: command, version: version,
                 unknownIdLength: unknownIdLengths[command.name] ?? StateKey.unknownCommandIdBytes)
    }

    private mutating func rekey(_ name: String, idLength: Int) {
        unknownIdLengths[name] = idLength
        for index in order.indices where order[index].name == name {
            guard let encoded = values.removeValue(forKey: order[index]) else { continue }
            let key = StateKey(name: name, id: Array(encoded.dropFirst(RawCommand.headerLength).prefix(idLength)))
            order[index] = key
            values[key] = encoded
        }
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
