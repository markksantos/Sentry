import Foundation
import SwiftUI

// MARK: - Supporting Enums

public enum ProtocolType: String, Codable, Sendable, Hashable {
    case tcp
    case udp
}

public enum ConnectionState: String, Codable, Sendable, Hashable {
    case established = "ESTABLISHED"
    case listen = "LISTEN"
    case timeWait = "TIME_WAIT"
    case closeWait = "CLOSE_WAIT"
    case finWait1 = "FIN_WAIT_1"
    case finWait2 = "FIN_WAIT_2"
    case synSent = "SYN_SENT"
    case synReceived = "SYN_RECEIVED"
    case closing = "CLOSING"
    case lastAck = "LAST_ACK"
    case unknown = "UNKNOWN"

    public var displayName: String {
        switch self {
        case .established:  return "Established"
        case .listen:       return "Listen"
        case .timeWait:     return "Time Wait"
        case .closeWait:    return "Close Wait"
        case .finWait1:     return "FIN Wait 1"
        case .finWait2:     return "FIN Wait 2"
        case .synSent:      return "SYN Sent"
        case .synReceived:  return "SYN Received"
        case .closing:      return "Closing"
        case .lastAck:      return "Last ACK"
        case .unknown:      return "Unknown"
        }
    }

    public var color: Color {
        switch self {
        case .established:  return .green
        case .listen:       return .blue
        case .timeWait:     return .orange
        case .closeWait:    return .yellow
        case .finWait1:     return .orange
        case .finWait2:     return .orange
        case .synSent:      return .purple
        case .synReceived:  return .purple
        case .closing:      return .red
        case .lastAck:      return .red
        case .unknown:      return .gray
        }
    }
}

public enum Direction: String, Codable, Sendable, Hashable {
    case inbound
    case outbound
    case unknown
}

// MARK: - ConnectionEntry

public struct ConnectionEntry: Identifiable, Hashable, Sendable, Codable {

    public let id: UUID
    public let appName: String
    public let pid: Int32
    public let protocolType: ProtocolType
    public let localAddress: String
    public let localPort: UInt16
    public let remoteAddress: String
    public let remotePort: UInt16
    public let state: ConnectionState
    public let direction: Direction
    public let timestamp: Date

    // Enrichment fields
    public var remoteHostname: String?
    public var countryCode: String?
    public var flagEmoji: String?

    public init(
        id: UUID = UUID(),
        appName: String,
        pid: Int32,
        protocolType: ProtocolType,
        localAddress: String,
        localPort: UInt16,
        remoteAddress: String,
        remotePort: UInt16,
        state: ConnectionState,
        direction: Direction? = nil,
        timestamp: Date = Date(),
        remoteHostname: String? = nil,
        countryCode: String? = nil,
        flagEmoji: String? = nil
    ) {
        self.id = id
        self.appName = appName
        self.pid = pid
        self.protocolType = protocolType
        self.localAddress = localAddress
        self.localPort = localPort
        self.remoteAddress = remoteAddress
        self.remotePort = remotePort
        self.state = state
        self.direction = direction ?? Self.inferDirection(
            state: state,
            localPort: localPort
        )
        self.timestamp = timestamp
        self.remoteHostname = remoteHostname
        self.countryCode = countryCode
        self.flagEmoji = flagEmoji
    }

    // MARK: - Direction Inference

    /// Infers connection direction based on state and port number.
    /// - LISTEN state implies inbound (server socket).
    /// - Local port in the ephemeral range (>= 49152) implies outbound (client initiated).
    /// - Otherwise defaults to outbound.
    public static func inferDirection(
        state: ConnectionState,
        localPort: UInt16
    ) -> Direction {
        if state == .listen {
            return .inbound
        }
        if localPort >= 49152 {
            return .outbound
        }
        return .outbound
    }
}
