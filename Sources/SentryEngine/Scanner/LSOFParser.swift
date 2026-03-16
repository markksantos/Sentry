import Foundation

/// Parses the output of `lsof -i -n -P +c0 -F pcnPtTf` into `ConnectionEntry` values.
///
/// The lsof field-output format emits one field per line. Each line starts with
/// a single-character tag followed by the field value:
///   - `p` — PID (starts a new process block)
///   - `c` — command name
///   - `f` — file descriptor (starts a new FD block within the current process)
///   - `t` — type (IPv4 / IPv6)
///   - `P` — protocol (TCP / UDP)
///   - `n` — name (address info)
///   - `T` — TCP info, e.g. `TST=ESTABLISHED`
public struct LSOFParser: Sendable {

    private init() {}

    // MARK: - Public API

    /// Parse raw lsof output into an array of `ConnectionEntry`.
    public static func parse(_ output: String) -> [ConnectionEntry] {
        let lines = output.components(separatedBy: .newlines)

        var results: [ConnectionEntry] = []
        var currentPID: Int32?
        var currentCommand: String?
        var fdContext = FDContext()

        for line in lines {
            guard !line.isEmpty else { continue }

            let tag = line.first!
            let value = String(line.dropFirst())

            switch tag {
            case "p":
                // Flush any pending FD from the previous process block.
                if let entry = buildEntry(pid: currentPID, command: currentCommand, fd: fdContext) {
                    results.append(entry)
                }
                fdContext.reset()
                currentPID = Int32(value)
                currentCommand = nil

            case "c":
                currentCommand = value

            case "f":
                // New file-descriptor block — flush the previous one if it existed.
                if let entry = buildEntry(pid: currentPID, command: currentCommand, fd: fdContext) {
                    results.append(entry)
                }
                fdContext.reset()
                fdContext.fd = value

            case "t":
                fdContext.type = value   // "IPv4" or "IPv6"

            case "P":
                fdContext.protocol_ = value.lowercased()  // "TCP" or "UDP"

            case "n":
                fdContext.name = value

            case "T":
                // TCP info lines look like "TST=ESTABLISHED", "TQR=0", "TQS=0".
                if value.hasPrefix("ST=") {
                    fdContext.tcpState = String(value.dropFirst(3))
                }

            default:
                break
            }
        }

        // Flush the final FD block.
        if let entry = buildEntry(pid: currentPID, command: currentCommand, fd: fdContext) {
            results.append(entry)
        }

        return results
    }

    // MARK: - Private Helpers

    /// Temporary accumulator for fields within a single file-descriptor block.
    private struct FDContext {
        var fd: String?
        var type: String?       // IPv4 / IPv6
        var protocol_: String?  // tcp / udp
        var name: String?
        var tcpState: String?

        mutating func reset() {
            fd = nil
            type = nil
            protocol_ = nil
            name = nil
            tcpState = nil
        }
    }

    /// Attempt to build a `ConnectionEntry` from the accumulated fields.
    private static func buildEntry(
        pid: Int32?,
        command: String?,
        fd: FDContext
    ) -> ConnectionEntry? {
        guard let pid = pid,
              let command = command,
              let protoString = fd.protocol_,
              let name = fd.name,
              fd.fd != nil
        else {
            return nil
        }

        let proto: ProtocolType
        switch protoString {
        case "tcp": proto = .tcp
        case "udp": proto = .udp
        default:    return nil
        }

        // Determine state.
        let state: ConnectionState
        if let rawState = fd.tcpState {
            state = parseState(rawState)
        } else if proto == .udp {
            state = .unknown
        } else {
            state = .unknown
        }

        // Parse the name field into local/remote address+port.
        let parsed = parseName(name, isIPv6: fd.type == "IPv6")

        return ConnectionEntry(
            appName: command,
            pid: pid,
            protocolType: proto,
            localAddress: parsed.localAddress,
            localPort: parsed.localPort,
            remoteAddress: parsed.remoteAddress,
            remotePort: parsed.remotePort,
            state: state
        )
    }

    /// Map the raw TCP state string from lsof to our enum.
    private static func parseState(_ raw: String) -> ConnectionState {
        switch raw.uppercased() {
        case "ESTABLISHED":  return .established
        case "LISTEN":       return .listen
        case "TIME_WAIT":    return .timeWait
        case "CLOSE_WAIT":   return .closeWait
        case "FIN_WAIT_1":   return .finWait1
        case "FIN_WAIT_2":   return .finWait2
        case "SYN_SENT":     return .synSent
        case "SYN_RECEIVED": return .synReceived
        case "CLOSING":      return .closing
        case "LAST_ACK":     return .lastAck
        default:             return .unknown
        }
    }

    /// Split an address+port string at the last colon.
    /// Handles IPv6 bracket notation like `[::1]:443`.
    private static func splitAddressPort(_ raw: String) -> (address: String, port: UInt16) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == "*" {
            return ("*", 0)
        }

        // Handle IPv6 bracket notation: [addr]:port
        if trimmed.hasPrefix("[") {
            if let closeBracket = trimmed.lastIndex(of: "]") {
                let address = String(trimmed[trimmed.index(after: trimmed.startIndex)...trimmed.index(before: closeBracket)])
                let afterBracket = trimmed.index(after: closeBracket)
                if afterBracket < trimmed.endIndex,
                   trimmed[afterBracket] == ":",
                   let port = UInt16(trimmed[trimmed.index(after: afterBracket)...]) {
                    return (address, port)
                }
                return (address, 0)
            }
        }

        // Split at the last colon (handles IPv4 and bare IPv6 without brackets).
        if let lastColon = trimmed.lastIndex(of: ":") {
            let address = String(trimmed[..<lastColon])
            let portStr = String(trimmed[trimmed.index(after: lastColon)...])
            let port = UInt16(portStr) ?? 0
            let addr = address.isEmpty ? "*" : address
            return (addr, port)
        }

        return (trimmed, 0)
    }

    /// Parse the `n` (name) field.
    /// Patterns:
    ///   - `192.168.1.1:53866->142.250.80.46:443` — connection with local->remote
    ///   - `[::1]:8080->[::1]:9090` — IPv6 connection
    ///   - `*:8080` — LISTEN (no remote)
    ///   - `*:5353` — UDP (no remote)
    private static func parseName(
        _ name: String,
        isIPv6: Bool
    ) -> (localAddress: String, localPort: UInt16, remoteAddress: String, remotePort: UInt16) {
        // Check for connection arrow.
        if let arrowRange = name.range(of: "->") {
            let localPart = String(name[..<arrowRange.lowerBound])
            let remotePart = String(name[arrowRange.upperBound...])
            let local = splitAddressPort(localPart)
            let remote = splitAddressPort(remotePart)
            return (local.address, local.port, remote.address, remote.port)
        }

        // No arrow — LISTEN or UDP with only a local side.
        let local = splitAddressPort(name)
        return (local.address, local.port, "*", 0)
    }
}
