/// The reliable-delivery half of the ATEM protocol, shared by both ends of a link.
///
/// Port of LibAtem's `AtemConnection`. It performs no IO: datagrams to send are
/// handed to `transmit`, and time is passed in so the logic is testable.
/// Not thread safe; the owner confines it to one queue.
final class ReliableSession {
    static let packetIdLimit: UInt16 = 1 << 15 // ATEM wraps at 15 bits, not 16
    static let timeout = 1.0
    static let maxInFlight = 32
    static let resendAfter = 0.030
    static let ackDelay = 0.005
    static let maxUnackedBeforeAck: UInt16 = 16

    private struct InFlight {
        let packetId: UInt16
        let payload: [UInt8]
        var lastSent: Double
    }

    var sessionId: UInt16
    private(set) var lastReceived: Double
    private(set) var isOpen = false

    private var lastPacketId: UInt16 = 0
    private var lastReceivedAck: UInt16?
    private var readyToAck: UInt16?
    private var lastSentAck: UInt16?
    private var ackWaitingSince: Double?
    private var queue: [[UInt8]] = []
    private var inFlight: [InFlight] = []

    private(set) var packetsSent = 0
    private(set) var packetsReceived = 0
    private(set) var packetsResent = 0

    private let transmit: ([UInt8]) -> Void

    init(sessionId: UInt16, now: Double, transmit: @escaping ([UInt8]) -> Void) {
        self.sessionId = sessionId
        self.lastReceived = now
        self.transmit = transmit
    }

    func hasTimedOut(now: Double) -> Bool { now - lastReceived > Self.timeout }

    var hasPendingOutbound: Bool { !queue.isEmpty || !inFlight.isEmpty }

    /// When `tick` next has work: queued data to send, a delayed ack or a resend.
    /// `nil` when only an incoming packet or a new payload can create work.
    var nextDeadline: Double? {
        if !queue.isEmpty && inFlight.count < Self.maxInFlight { return -.infinity }
        var deadline = ackWaitingSince.map { $0 + Self.ackDelay }
        if let oldest = inFlight.first {
            deadline = min(deadline ?? .infinity, oldest.lastSent + Self.resendAfter)
        }
        return deadline
    }

    func reset(now: Double) {
        lastReceived = now
        isOpen = false
        lastPacketId = 0
        lastReceivedAck = nil
        readyToAck = nil
        lastSentAck = nil
        ackWaitingSince = nil
        queue.removeAll()
        inFlight.removeAll()
    }

    /// Queues a payload (encoded commands) for reliable delivery.
    func enqueue(payload: [UInt8]) { queue.append(payload) }

    func enqueue(payloads: [[UInt8]]) { queue.append(contentsOf: payloads) }

    /// Queues an empty reliable packet, used as a keep-alive.
    func enqueuePing() { queue.append([]) }

    /// Processes an incoming non-handshake packet. Returns the payload when the
    /// packet carries new in-order data that should be handled.
    func receive(_ packet: Packet, now: Double) -> [UInt8]? {
        lastReceived = now
        packetsReceived += 1

        let wantsAck = packet.flags.contains(.ackRequest)
        if wantsAck {
            let acked = readyToAck ?? 0
            if Self.isCovered(packet: packet.packetId, byAck: acked) && readyToAck != nil {
                // Duplicate of something we already have; the remote missed our ack.
                queueAck(packet.packetId, now: now)
                return nil
            }
            if packet.packetId != Self.increment(acked) {
                // Gap. Drop it and let the remote resend in order.
                return nil
            }
            queueAck(packet.packetId, now: now)
        }

        if packet.flags.contains(.ackReply) {
            isOpen = true
            if lastReceivedAck == nil || !Self.isCovered(packet: packet.ackedId, byAck: lastReceivedAck!) {
                lastReceivedAck = packet.ackedId
            }
            pruneInFlight()
        }

        return wantsAck ? packet.payload : nil
    }

    /// Sends anything due: delayed acks, resends and queued payloads.
    func tick(now: Double) {
        if let since = ackWaitingSince, now - since >= Self.ackDelay {
            sendAck()
        }

        pruneInFlight()
        // Go-back-N: receivers drop anything after a gap, so once the oldest packet is overdue
        // the whole window has to go again, in order. Resending only overdue packets made a
        // lossy client recover one packet per timeout instead (seconds behind at 20% loss).
        if let oldest = inFlight.first, now - oldest.lastSent >= Self.resendAfter {
            packetsResent += inFlight.count
            for index in inFlight.indices {
                send(packetId: inFlight[index].packetId, payload: inFlight[index].payload, retransmit: true)
                inFlight[index].lastSent = now
            }
            return
        }

        let count = min(Self.maxInFlight - inFlight.count, queue.count)
        guard count > 0 else { return }
        for payload in queue.prefix(count) {
            let packetId = nextPacketId()
            send(packetId: packetId, payload: payload, retransmit: false)
            inFlight.append(InFlight(packetId: packetId, payload: payload, lastSent: now))
        }
        queue.removeFirst(count)
    }

    /// Sends an ack for the latest received packet, or packet 0 when forced.
    func sendAck(force: Bool = false) {
        if !force {
            guard let ready = readyToAck, ready != lastSentAck else {
                ackWaitingSince = nil
                return
            }
        }
        let id = readyToAck ?? 0
        lastSentAck = id
        ackWaitingSince = nil
        transmit(Packet(flags: .ackReply, sessionId: sessionId, ackedId: id).bytes)
    }

    // MARK: - Internals

    private func queueAck(_ packetId: UInt16, now: Double) {
        if readyToAck == nil || !Self.isCovered(packet: packetId, byAck: readyToAck!) {
            readyToAck = packetId
        }
        var shouldSend = lastSentAck == nil
        if let ready = readyToAck, let sent = lastSentAck,
           (ready &- sent) % Self.packetIdLimit >= Self.maxUnackedBeforeAck {
            shouldSend = true
        }
        if let since = ackWaitingSince, now - since >= Self.ackDelay {
            shouldSend = true
        }
        if shouldSend {
            sendAck()
        } else if ackWaitingSince == nil {
            ackWaitingSince = now
        }
    }

    private func send(packetId: UInt16, payload: [UInt8], retransmit: Bool) {
        var flags: PacketFlags = .ackRequest
        if retransmit { flags.insert(.retransmit) }
        var packet = Packet(flags: flags, sessionId: sessionId, packetId: packetId, payload: payload)
        // Piggyback a pending ack on outgoing data, as the ATEM does.
        if let ready = readyToAck, ready != lastSentAck || ackWaitingSince != nil {
            packet.flags.insert(.ackReply)
            packet.ackedId = ready
            lastSentAck = ready
            ackWaitingSince = nil
        }
        packetsSent += 1
        transmit(packet.bytes)
    }

    private func pruneInFlight() {
        guard let acked = lastReceivedAck else { return }
        inFlight.removeAll { Self.isCovered(packet: $0.packetId, byAck: acked) }
    }

    private func nextPacketId() -> UInt16 {
        lastPacketId = Self.increment(lastPacketId)
        return lastPacketId
    }

    static func increment(_ id: UInt16) -> UInt16 {
        let next = id &+ 1
        return next >= packetIdLimit ? 0 : next
    }

    /// Whether `packet` is at or before `ack`, allowing for wrap-around.
    static func isCovered(packet: UInt16, byAck ack: UInt16) -> Bool {
        let p = Int(packet), a = Int(ack), tolerance = 1 << 8
        let shortlyBefore = p < a && p + tolerance > a
        let shortlyAfter = p > a && p < a + tolerance
        let beforeWrap = p > a + tolerance
        return p == a || ((shortlyBefore || beforeWrap) && !shortlyAfter)
    }
}
