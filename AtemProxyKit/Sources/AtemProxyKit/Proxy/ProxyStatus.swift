import Foundation

/// Point-in-time view of a running proxy, for display.
public struct ProxyStatus: Sendable, Equatable {
    public enum Upstream: Sendable, Equatable {
        case stopped
        case resolving
        case connecting
        /// Handshake done, receiving the initial state dump.
        case synchronizing
        case connected
        /// The ATEM has no free connection slots.
        case rejected
        case failed(String)
    }

    public struct Client: Sendable, Equatable, Identifiable {
        public var endpoint: String
        public var connectedAt: Date
        public var isSynchronized: Bool
        public var receivesAudioLevels: Bool
        public var packetsSent: Int
        public var packetsReceived: Int
        public var packetsResent: Int
        public var id: String { endpoint }
    }

    public var upstream: Upstream = .stopped
    public var atemEndpoint: String?
    public var protocolVersion: ProtocolVersion?
    public var productName: String?
    public var listening: String?
    public var listenError: String?
    public var clients: [Client] = []
    public var cachedStateEntries = 0
    public var commandsFromAtem = 0
    public var commandsToAtem = 0
    public var unknownCommandNames: [String] = []

    public var isRunning: Bool { upstream != .stopped }

    public init() {}
}

public struct ProxyLogEntry: Sendable, Identifiable, Hashable {
    public enum Level: String, Sendable { case debug, info, warning, error }
    public let id = UUID()
    public let date: Date
    public let level: Level
    public let message: String

    public init(date: Date, level: Level, message: String) {
        self.date = date
        self.level = level
        self.message = message
    }
}
