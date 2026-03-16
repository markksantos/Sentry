import Foundation

// MARK: - Errors

public enum MMDBError: Error, CustomStringConvertible {
    case invalidFormat(String)
    case metadataNotFound
    case unsupportedRecordSize(UInt16)
    case dataCorruption(String)

    public var description: String {
        switch self {
        case .invalidFormat(let msg):       return "MMDB invalid format: \(msg)"
        case .metadataNotFound:             return "MMDB metadata marker not found"
        case .unsupportedRecordSize(let s): return "MMDB unsupported record size: \(s)"
        case .dataCorruption(let msg):      return "MMDB data corruption: \(msg)"
        }
    }
}

// MARK: - MMDBReader

/// Pure-Swift reader for MaxMind's MMDB binary format.
///
/// Supports GeoLite2-Country (and similar) databases with 24-, 28-, or 32-bit
/// record sizes for both IPv4 and IPv6.
public struct MMDBReader: Sendable {

    // MARK: - Metadata

    /// Parsed metadata from the MMDB file.
    public struct Metadata: Sendable {
        public let nodeCount: UInt32
        public let recordSize: UInt16
        public let ipVersion: UInt16
        public let databaseType: String
        public let buildEpoch: UInt64
    }

    // MARK: - Properties

    private let data: Data
    public let metadata: Metadata

    /// Byte offset where the data section begins.
    private let dataSectionStart: Int

    /// Size of a single node in bytes: `recordSize * 2 / 8`.
    private let nodeSize: Int

    /// Total size of the search tree in bytes.
    private let searchTreeSize: Int

    // MARK: - Initialization

    /// Create a reader from raw MMDB data.
    /// - Throws: `MMDBError` if the data is not a valid MMDB file.
    public init(data: Data) throws {
        guard data.count > 16 else {
            throw MMDBError.invalidFormat("File too small (\(data.count) bytes)")
        }
        self.data = data
        self.metadata = try Self.parseMetadata(from: data)

        guard [24, 28, 32].contains(metadata.recordSize) else {
            throw MMDBError.unsupportedRecordSize(metadata.recordSize)
        }

        self.nodeSize = Int(metadata.recordSize) * 2 / 8
        self.searchTreeSize = Int(metadata.nodeCount) * nodeSize
        // Data section starts 16 bytes after the search tree (null padding).
        self.dataSectionStart = searchTreeSize + 16
    }

    // MARK: - Public API

    /// Look up an IP address string (IPv4 or IPv6).
    /// Returns the data record as a dictionary, or `nil` if no entry exists.
    public func lookup(_ ip: String) -> [String: Any]? {
        guard let bits = ipToBits(ip) else { return nil }
        return traverse(bits: bits)
    }

    // MARK: - Metadata Parsing

    /// The metadata marker: `\xAB\xCD\xEFMaxMind.com`.
    private static let metadataMarker = Data(
        [0xAB, 0xCD, 0xEF] + Array("MaxMind.com".utf8)
    )

    private static func parseMetadata(from data: Data) throws -> Metadata {
        // Search backwards for the last occurrence of the metadata marker.
        guard let markerOffset = findLastOccurrence(of: metadataMarker, in: data) else {
            throw MMDBError.metadataNotFound
        }

        let metadataStart = markerOffset + metadataMarker.count
        guard metadataStart < data.count else {
            throw MMDBError.invalidFormat("Metadata section is empty")
        }

        var offset = metadataStart
        guard let rawMeta = decodeValue(from: data, offset: &offset) else {
            throw MMDBError.invalidFormat("Could not decode metadata")
        }

        guard let map = rawMeta as? [String: Any] else {
            throw MMDBError.invalidFormat("Metadata is not a map")
        }

        guard let nodeCount = asUInt32(map["node_count"]) else {
            throw MMDBError.invalidFormat("Missing or invalid node_count")
        }
        guard let recordSize = asUInt16(map["record_size"]) else {
            throw MMDBError.invalidFormat("Missing or invalid record_size")
        }
        let ipVersion = asUInt16(map["ip_version"]) ?? 6
        let dbType = map["database_type"] as? String ?? "unknown"
        let buildEpoch = asUInt64(map["build_epoch"]) ?? 0

        return Metadata(
            nodeCount: nodeCount,
            recordSize: recordSize,
            ipVersion: ipVersion,
            databaseType: dbType,
            buildEpoch: buildEpoch
        )
    }

    /// Find the last occurrence of `marker` in `data`.
    private static func findLastOccurrence(of marker: Data, in data: Data) -> Int? {
        let markerCount = marker.count
        guard data.count >= markerCount else { return nil }
        var i = data.count - markerCount
        while i >= 0 {
            if data[data.startIndex.advanced(by: i)..<data.startIndex.advanced(by: i + markerCount)] == marker {
                return i
            }
            i -= 1
        }
        return nil
    }

    // MARK: - Tree Traversal

    /// Walk the binary search tree using the IP's bit representation.
    private func traverse(bits: [UInt8]) -> [String: Any]? {
        var node: UInt32 = 0
        let nodeCount = metadata.nodeCount

        // For IPv4 in an IPv6 database, the first 96 bits are zero (::ffff:0:0/96).
        // We need to walk those 96 zero bits to reach the IPv4 subtree.
        let startBit: Int
        if bits.count == 32 && metadata.ipVersion == 6 {
            // Walk 96 zero bits first.
            for _ in 0..<96 {
                let record = readRecord(node: node, bit: 0)
                if record >= nodeCount {
                    if record == nodeCount { return nil }
                    return resolveDataRecord(record)
                }
                node = record
            }
            startBit = 0
        } else {
            startBit = 0
        }

        for i in startBit..<bits.count {
            let bit = bits[i]
            let record = readRecord(node: node, bit: bit)
            if record >= nodeCount {
                if record == nodeCount { return nil }
                return resolveDataRecord(record)
            }
            node = record
        }

        return nil
    }

    /// Read the left (bit=0) or right (bit=1) record from a given node.
    private func readRecord(node: UInt32, bit: UInt8) -> UInt32 {
        let nodeOffset = Int(node) * nodeSize
        switch metadata.recordSize {
        case 24:
            return readRecord24(nodeOffset: nodeOffset, isRight: bit == 1)
        case 28:
            return readRecord28(nodeOffset: nodeOffset, isRight: bit == 1)
        case 32:
            return readRecord32(nodeOffset: nodeOffset, isRight: bit == 1)
        default:
            return metadata.nodeCount // Treat as not-found.
        }
    }

    // 24-bit records: 6 bytes per node (3 left, 3 right).
    private func readRecord24(nodeOffset: Int, isRight: Bool) -> UInt32 {
        let base = isRight ? nodeOffset + 3 : nodeOffset
        return readUInt24(at: base)
    }

    // 28-bit records: 7 bytes per node.
    // Layout: [left(24 bits)][middle byte][right(24 bits)]
    // Middle byte: high nibble is top 4 bits of left, low nibble is top 4 bits of right.
    // Actually per MaxMind spec for 28-bit records:
    //   Bytes 0-3: contains left record in bits 0-27 and right record's top 4 bits
    //   Layout: LL LL LM RR RR RR  (where M = middle byte has left-high-nibble | right-high-nibble)
    // More precisely (from the spec):
    //   left  = (middle_byte >> 4) << 24 | byte0 << 16 | byte1 << 8 | byte2
    //   right = (middle_byte & 0x0F) << 24 | byte4 << 16 | byte5 << 8 | byte6
    // With byte3 = middle_byte, total 7 bytes: [0][1][2][3=middle][4][5][6]
    private func readRecord28(nodeOffset: Int, isRight: Bool) -> UInt32 {
        let middle = readByte(at: nodeOffset + 3)
        if isRight {
            let top4 = UInt32(middle & 0x0F) << 24
            let low24 = readUInt24(at: nodeOffset + 4)
            return top4 | low24
        } else {
            let top4 = UInt32(middle >> 4) << 24
            let low24 = readUInt24(at: nodeOffset)
            return top4 | low24
        }
    }

    // 32-bit records: 8 bytes per node (4 left, 4 right).
    private func readRecord32(nodeOffset: Int, isRight: Bool) -> UInt32 {
        let base = isRight ? nodeOffset + 4 : nodeOffset
        return readUInt32(at: base)
    }

    // MARK: - Data Section Resolution

    /// Resolve a record value from the search tree to a data section entry.
    private func resolveDataRecord(_ record: UInt32) -> [String: Any]? {
        let offset = dataSectionStart + Int(record) - Int(metadata.nodeCount) - 16
        guard offset >= 0, offset < data.count else { return nil }
        var cursor = offset
        let value = Self.decodeValue(from: data, offset: &cursor)
        return value as? [String: Any]
    }

    // MARK: - Data Section Decoding

    /// Decode a single value from the data section at the given offset.
    /// Advances `offset` past the decoded value.
    private static func decodeValue(from data: Data, offset: inout Int) -> Any? {
        guard offset < data.count else { return nil }

        let controlByte = UInt8(data[data.startIndex.advanced(by: offset)])
        offset += 1

        var typeNum = UInt8(controlByte >> 5)
        var size = Int(controlByte & 0x1F)

        // Extended type: type 0 means the actual type is in the next byte + 7.
        if typeNum == 0 {
            guard offset < data.count else { return nil }
            typeNum = data[data.startIndex.advanced(by: offset)] + 7
            offset += 1
        }

        // Pointer type (1): size field encodes pointer info, not payload size.
        if typeNum == 1 {
            return resolvePointer(from: data, controlByte: controlByte, offset: &offset)
        }

        // Decode size for non-pointer types.
        if size == 29 {
            guard offset < data.count else { return nil }
            size = 29 + Int(data[data.startIndex.advanced(by: offset)])
            offset += 1
        } else if size == 30 {
            guard offset + 1 < data.count else { return nil }
            size = 285 + (Int(data[data.startIndex.advanced(by: offset)]) << 8)
                       + Int(data[data.startIndex.advanced(by: offset + 1)])
            offset += 2
        } else if size == 31 {
            guard offset + 2 < data.count else { return nil }
            size = 65821 + (Int(data[data.startIndex.advanced(by: offset)]) << 16)
                         + (Int(data[data.startIndex.advanced(by: offset + 1)]) << 8)
                         + Int(data[data.startIndex.advanced(by: offset + 2)])
            offset += 3
        }

        switch typeNum {
        case 2: // String (UTF-8)
            return decodeString(from: data, offset: &offset, size: size)
        case 3: // Double
            return decodeDouble(from: data, offset: &offset, size: size)
        case 5: // UInt16
            return decodeUInt(from: data, offset: &offset, size: size)
        case 6: // UInt32
            return decodeUInt(from: data, offset: &offset, size: size)
        case 7: // Map
            return decodeMap(from: data, offset: &offset, count: size)
        case 8: // Int32
            return decodeInt32(from: data, offset: &offset, size: size)
        case 9: // UInt64
            return decodeUInt(from: data, offset: &offset, size: size)
        case 10: // UInt128
            return decodeUInt(from: data, offset: &offset, size: size)
        case 11: // Array
            return decodeArray(from: data, offset: &offset, count: size)
        case 14: // Boolean
            return size != 0
        case 15: // Float (extended type 8)
            return decodeFloat(from: data, offset: &offset, size: size)
        default:
            // Skip unknown types.
            offset += size
            return nil
        }
    }

    // MARK: Pointer

    private static func resolvePointer(
        from data: Data,
        controlByte: UInt8,
        offset: inout Int
    ) -> Any? {
        let sizeField = Int((controlByte >> 3) & 0x03)
        let base = Int(controlByte & 0x07)

        let pointerOffset: Int
        switch sizeField {
        case 0:
            guard offset < data.count else { return nil }
            pointerOffset = (base << 8) + Int(data[data.startIndex.advanced(by: offset)])
            offset += 1
        case 1:
            guard offset + 1 < data.count else { return nil }
            pointerOffset = 2048 + (base << 16)
                + (Int(data[data.startIndex.advanced(by: offset)]) << 8)
                + Int(data[data.startIndex.advanced(by: offset + 1)])
            offset += 2
        case 2:
            guard offset + 2 < data.count else { return nil }
            pointerOffset = 526336 + (base << 24)
                + (Int(data[data.startIndex.advanced(by: offset)]) << 16)
                + (Int(data[data.startIndex.advanced(by: offset + 1)]) << 8)
                + Int(data[data.startIndex.advanced(by: offset + 2)])
            offset += 3
        case 3:
            guard offset + 3 < data.count else { return nil }
            pointerOffset = (Int(data[data.startIndex.advanced(by: offset)]) << 24)
                + (Int(data[data.startIndex.advanced(by: offset + 1)]) << 16)
                + (Int(data[data.startIndex.advanced(by: offset + 2)]) << 8)
                + Int(data[data.startIndex.advanced(by: offset + 3)])
            offset += 4
        default:
            return nil
        }

        var ptrOffset = pointerOffset
        return decodeValue(from: data, offset: &ptrOffset)
    }

    // MARK: Primitive Decoders

    private static func decodeString(from data: Data, offset: inout Int, size: Int) -> String {
        guard size > 0, offset + size <= data.count else {
            offset += size
            return ""
        }
        let start = data.startIndex.advanced(by: offset)
        let str = String(data: data[start..<start.advanced(by: size)], encoding: .utf8) ?? ""
        offset += size
        return str
    }

    private static func decodeUInt(from data: Data, offset: inout Int, size: Int) -> UInt64 {
        guard size > 0 else { return 0 }
        var value: UInt64 = 0
        for i in 0..<min(size, 8) {
            guard offset + i < data.count else { break }
            value = (value << 8) | UInt64(data[data.startIndex.advanced(by: offset + i)])
        }
        offset += size
        return value
    }

    private static func decodeInt32(from data: Data, offset: inout Int, size: Int) -> Int32 {
        let raw = decodeUInt(from: data, offset: &offset, size: size)
        return Int32(bitPattern: UInt32(truncatingIfNeeded: raw))
    }

    private static func decodeDouble(from data: Data, offset: inout Int, size: Int) -> Double {
        guard size == 8, offset + 8 <= data.count else {
            offset += size
            return 0
        }
        var bits: UInt64 = 0
        for i in 0..<8 {
            bits = (bits << 8) | UInt64(data[data.startIndex.advanced(by: offset + i)])
        }
        offset += 8
        return Double(bitPattern: bits)
    }

    private static func decodeFloat(from data: Data, offset: inout Int, size: Int) -> Float {
        guard size == 4, offset + 4 <= data.count else {
            offset += size
            return 0
        }
        var bits: UInt32 = 0
        for i in 0..<4 {
            bits = (bits << 8) | UInt32(data[data.startIndex.advanced(by: offset + i)])
        }
        offset += 4
        return Float(bitPattern: bits)
    }

    private static func decodeMap(from data: Data, offset: inout Int, count: Int) -> [String: Any] {
        var map: [String: Any] = [:]
        map.reserveCapacity(count)
        for _ in 0..<count {
            guard let key = decodeValue(from: data, offset: &offset) as? String else { continue }
            let value = decodeValue(from: data, offset: &offset)
            map[key] = value
        }
        return map
    }

    private static func decodeArray(from data: Data, offset: inout Int, count: Int) -> [Any] {
        var array: [Any] = []
        array.reserveCapacity(count)
        for _ in 0..<count {
            if let value = decodeValue(from: data, offset: &offset) {
                array.append(value)
            }
        }
        return array
    }

    // MARK: - Byte Readers

    private func readByte(at index: Int) -> UInt8 {
        guard index >= 0, index < data.count else { return 0 }
        return data[data.startIndex.advanced(by: index)]
    }

    private func readUInt24(at index: Int) -> UInt32 {
        guard index + 2 < data.count else { return 0 }
        let b0 = UInt32(data[data.startIndex.advanced(by: index)])
        let b1 = UInt32(data[data.startIndex.advanced(by: index + 1)])
        let b2 = UInt32(data[data.startIndex.advanced(by: index + 2)])
        return (b0 << 16) | (b1 << 8) | b2
    }

    private func readUInt32(at index: Int) -> UInt32 {
        guard index + 3 < data.count else { return 0 }
        let b0 = UInt32(data[data.startIndex.advanced(by: index)])
        let b1 = UInt32(data[data.startIndex.advanced(by: index + 1)])
        let b2 = UInt32(data[data.startIndex.advanced(by: index + 2)])
        let b3 = UInt32(data[data.startIndex.advanced(by: index + 3)])
        return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
    }

    // MARK: - IP Parsing

    /// Convert an IP string to an array of bits (MSB first).
    /// Returns 32 bits for IPv4, 128 bits for IPv6.
    private func ipToBits(_ ip: String) -> [UInt8]? {
        // Try IPv4 first.
        if let ipv4Bits = parseIPv4(ip) {
            return ipv4Bits
        }
        // Try IPv6.
        if let ipv6Bits = parseIPv6(ip) {
            return ipv6Bits
        }
        return nil
    }

    private func parseIPv4(_ ip: String) -> [UInt8]? {
        let parts = ip.split(separator: ".")
        guard parts.count == 4 else { return nil }
        var bits: [UInt8] = []
        bits.reserveCapacity(32)
        for part in parts {
            guard let byte = UInt8(part) else { return nil }
            for shift in stride(from: 7, through: 0, by: -1) {
                bits.append((byte >> shift) & 1)
            }
        }
        return bits
    }

    private func parseIPv6(_ ip: String) -> [UInt8]? {
        // Expand :: notation.
        var working = ip

        // Handle IPv4-mapped IPv6 (e.g., ::ffff:192.168.1.1)
        if let lastColon = working.lastIndex(of: ":") {
            let suffix = String(working[working.index(after: lastColon)...])
            if suffix.contains(".") {
                // IPv4 mapped - convert the IPv4 part to hex.
                guard let v4Parts = parseIPv4Octets(suffix) else { return nil }
                let hex1 = String(format: "%02x%02x", v4Parts[0], v4Parts[1])
                let hex2 = String(format: "%02x%02x", v4Parts[2], v4Parts[3])
                working = String(working[...lastColon]) + hex1 + ":" + hex2
            }
        }

        // Expand ::
        if working.contains("::") {
            let halves = working.components(separatedBy: "::")
            guard halves.count <= 2 else { return nil }
            let left = halves[0].isEmpty ? [] : halves[0].split(separator: ":").map(String.init)
            let right = halves.count > 1 && !halves[1].isEmpty
                ? halves[1].split(separator: ":").map(String.init)
                : []
            let missing = 8 - left.count - right.count
            guard missing >= 0 else { return nil }
            let allGroups = left + Array(repeating: "0", count: missing) + right
            return groupsToBits(allGroups)
        }

        let groups = working.split(separator: ":").map(String.init)
        guard groups.count == 8 else { return nil }
        return groupsToBits(groups)
    }

    private func parseIPv4Octets(_ ip: String) -> [UInt8]? {
        let parts = ip.split(separator: ".")
        guard parts.count == 4 else { return nil }
        var octets: [UInt8] = []
        for part in parts {
            guard let byte = UInt8(part) else { return nil }
            octets.append(byte)
        }
        return octets
    }

    private func groupsToBits(_ groups: [String]) -> [UInt8]? {
        guard groups.count == 8 else { return nil }
        var bits: [UInt8] = []
        bits.reserveCapacity(128)
        for group in groups {
            guard let value = UInt16(group, radix: 16) else { return nil }
            for shift in stride(from: 15, through: 0, by: -1) {
                bits.append(UInt8((value >> shift) & 1))
            }
        }
        return bits
    }

    // MARK: - Numeric Conversion Helpers

    private static func asUInt16(_ value: Any?) -> UInt16? {
        if let v = value as? UInt64 { return UInt16(v) }
        if let v = value as? Int    { return UInt16(v) }
        return nil
    }

    private static func asUInt32(_ value: Any?) -> UInt32? {
        if let v = value as? UInt64 { return UInt32(v) }
        if let v = value as? Int    { return UInt32(v) }
        return nil
    }

    private static func asUInt64(_ value: Any?) -> UInt64? {
        if let v = value as? UInt64 { return v }
        if let v = value as? Int    { return UInt64(v) }
        return nil
    }
}
