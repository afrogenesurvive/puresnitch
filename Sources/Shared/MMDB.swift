import Foundation

/// A minimal reader for the MaxMind DB (`.mmdb`) binary format.
///
/// Vendored deliberately rather than taken as a Swift Package:
/// `Scripts/test_hardening.sh` compiles a fixed file list with `swiftc` and
/// links only `-lsqlite3`, so a package dependency would mean teaching that
/// script about a built package graph. The format is small and stable, and this
/// file imports nothing but Foundation.
///
/// The reader memory-maps the database (the DB-IP city file is ~121 MB) and
/// never copies it onto the heap. Every stored property is immutable after
/// `init`, which is what makes sharing it across queues safe - hence the
/// `@unchecked Sendable`.
public final class MMDBReader: @unchecked Sendable {

    public enum MMDBError: Error, LocalizedError {
        case unreadable(String)
        case metadataMarkerMissing
        case unsupportedRecordSize(Int)
        case malformedMetadata(String)

        public var errorDescription: String? {
            switch self {
            case .unreadable(let path):
                return "the GeoIP database could not be read at \(path)"
            case .metadataMarkerMissing:
                return "the GeoIP database has no metadata section - it is not a MaxMind DB file"
            case .unsupportedRecordSize(let size):
                return "the GeoIP database uses an unsupported record size of \(size) bits"
            case .malformedMetadata(let detail):
                return "the GeoIP database metadata is malformed: \(detail)"
            }
        }
    }

    public struct Metadata: Sendable {
        public let nodeCount: Int
        public let recordSize: Int
        public let ipVersion: Int
        public let databaseType: String
        public let buildEpoch: Date?
        public let description: [String: String]

        /// Bytes per tree node: the node holds two records of `recordSize` bits.
        public let nodeByteSize: Int
        /// Total size of the search tree in bytes.
        public let treeSize: Int
        /// Offset of the first byte of the data section: the tree, then a
        /// 16-byte zero separator.
        public let dataSectionOffset: Int
    }

    private let data: Data
    public let metadata: Metadata

    public init(url: URL) throws {
        let mapped: Data
        do {
            // mappedIfSafe keeps the 121 MB file out of the heap; the pages are
            // faulted in on demand instead.
            mapped = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw MMDBError.unreadable(url.path)
        }
        self.data = mapped

        // Raw bytes, not a Swift string: "\u{ab}" would be the scalar U+00AB,
        // which UTF-8 encodes as two bytes (0xC2 0xAB) and would never match.
        let marker = Data([0xAB, 0xCD, 0xEF] + Array("MaxMind.com".utf8))
        guard let markerStart = Self.findMarker(marker, in: mapped) else {
            throw MMDBError.metadataMarkerMissing
        }
        let metadataOffset = markerStart + marker.count
        let decoded = try Self.decodeValue(in: mapped, at: metadataOffset, pointerBase: metadataOffset)
        guard case .map(let fields) = decoded else {
            throw MMDBError.malformedMetadata("the metadata section is not a map")
        }
        func int(_ key: String) throws -> Int {
            guard case .uint(let v)? = fields[key] else {
                throw MMDBError.malformedMetadata("\(key) is missing or not an integer")
            }
            return Int(v)
        }
        let nodeCount = try int("node_count")
        let recordSize = try int("record_size")
        guard recordSize == 24 || recordSize == 28 || recordSize == 32 else {
            throw MMDBError.unsupportedRecordSize(recordSize)
        }
        let nodeByteSize = recordSize / 4
        var description: [String: String] = [:]
        if case .map(let raw)? = fields["description"] {
            for (key, value) in raw {
                if case .string(let s) = value { description[key] = s }
            }
        }
        var buildDate: Date?
        if case .uint(let epoch)? = fields["build_epoch"], epoch > 0 {
            buildDate = Date(timeIntervalSince1970: TimeInterval(epoch))
        }

        self.metadata = Metadata(
            nodeCount: nodeCount,
            recordSize: recordSize,
            ipVersion: try int("ip_version"),
            databaseType: {
                if case .string(let t)? = fields["database_type"] { return t }
                return "unknown"
            }(),
            buildEpoch: buildDate,
            description: description,
            nodeByteSize: nodeByteSize,
            treeSize: nodeCount * nodeByteSize,
            dataSectionOffset: nodeCount * nodeByteSize + 16
        )
    }

    /// Looks up a textual IPv4 or IPv6 address. Returns `nil` when the address
    /// is not in the database or cannot be parsed.
    public func lookup(_ address: String) -> MMDBValue? {
        guard let packed = Self.pack(address) else { return nil }
        return lookup(packed)
    }

    public func lookup(_ address: [UInt8]) -> MMDBValue? {
        guard let bits = Self.addressBits(address, databaseIsIPv6: metadata.ipVersion == 6) else {
            return nil
        }

        var node = 0
        var index = 0
        // Consume EVERY bit of the address: `bits.count` is bytes, and stopping
        // after 16 iterations would abandon the walk at the first branch on IPv6.
        let totalBits = bits.count * 8
        let nodeCount = metadata.nodeCount
        while index < totalBits && node < nodeCount {
            let byte = bits[index >> 3]
            let bit = (byte >> (7 - UInt8(index & 7))) & 1
            node = readNode(node, Int(bit))
            index += 1
        }

        if node == nodeCount { return nil }        // an empty record: not found
        guard node > nodeCount else { return nil } // ran out of bits inside the tree

        // A data record's value encodes the offset within the data section,
        // biased by the node count AND the 16-byte separator, i.e.
        // `value = offset + node_count + 16`. Inverting that gives
        // `value - node_count + treeSize` - deliberately NOT
        // `value - node_count + dataSectionOffset`, which lands 16 bytes into
        // each record and decodes as garbage.
        let pointer = node - nodeCount + metadata.treeSize
        return try? Self.decodeValue(in: data, at: pointer, pointerBase: metadata.dataSectionOffset)
    }

    // MARK: - Tree

    /// Reads one of the two records of a node. The layouts are fixed by the
    /// spec: a 28-bit node splits its seventh byte between the two records.
    private func readNode(_ node: Int, _ right: Int) -> Int {
        let base = node * metadata.nodeByteSize
        switch metadata.recordSize {
        case 24:
            if right == 0 {
                return (Int(data[base]) << 16) | (Int(data[base + 1]) << 8) | Int(data[base + 2])
            }
            return (Int(data[base + 3]) << 16) | (Int(data[base + 4]) << 8) | Int(data[base + 5])
        case 28:
            if right == 0 {
                return ((Int(data[base + 3]) & 0xF0) << 20)
                    | (Int(data[base]) << 16)
                    | (Int(data[base + 1]) << 8)
                    | Int(data[base + 2])
            }
            return ((Int(data[base + 3]) & 0x0F) << 24)
                | (Int(data[base + 4]) << 16)
                | (Int(data[base + 5]) << 8)
                | Int(data[base + 6])
        default:
            if right == 0 {
                return (Int(data[base]) << 24) | (Int(data[base + 1]) << 16)
                    | (Int(data[base + 2]) << 8) | Int(data[base + 3])
            }
            return (Int(data[base + 4]) << 24) | (Int(data[base + 5]) << 16)
                | (Int(data[base + 6]) << 8) | Int(data[base + 7])
        }
    }

    // MARK: - Address handling

    /// Parses a dotted-quad or colon-separated address into bytes. Handles the
    /// `::` elision and a trailing embedded IPv4 form.
    static func pack(_ address: String) -> [UInt8]? {
        if address.contains(":") {
            return packIPv6(address)
        }
        let parts = address.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(4)
        for part in parts {
            guard let byte = UInt8(part) else { return nil }
            out.append(byte)
        }
        return out
    }

    private static func packIPv6(_ address: String) -> [UInt8]? {
        // An IPv4 tail (`::ffff:1.2.3.4`) is expanded into its two 16-bit halves.
        var text = address
        if let lastColon = text.lastIndex(of: ":"), text[text.index(after: lastColon)...].contains(".") {
            guard let tail = pack(String(text[text.index(after: lastColon)...])) else { return nil }
            let high = (UInt16(tail[0]) << 8) | UInt16(tail[1])
            let low = (UInt16(tail[2]) << 8) | UInt16(tail[3])
            text = String(text[..<text.index(after: lastColon)])
                + String(high, radix: 16) + ":" + String(low, radix: 16)
        }

        let halves = text.components(separatedBy: "::")
        guard halves.count <= 2 else { return nil }
        func groups(_ s: String) -> [UInt16]? {
            if s.isEmpty { return [] }
            var out: [UInt16] = []
            for piece in s.split(separator: ":", omittingEmptySubsequences: false) {
                guard !piece.isEmpty, let v = UInt16(piece, radix: 16) else { return nil }
                out.append(v)
            }
            return out
        }
        guard let head = groups(halves[0]) else { return nil }
        var words = head
        if halves.count == 2 {
            guard let tail = groups(halves[1]) else { return nil }
            guard head.count + tail.count <= 7 else { return nil }
            words += Array(repeating: 0, count: 8 - head.count - tail.count)
            words += tail
        }
        guard words.count == 8 else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(16)
        for word in words {
            out.append(UInt8(word >> 8))
            out.append(UInt8(word & 0xFF))
        }
        return out
    }

    /// A 4-byte address against an IPv6 tree has to be walked as the
    /// IPv4-in-IPv6 form, i.e. after 96 leading zero bits.
    private static func addressBits(_ bytes: [UInt8], databaseIsIPv6: Bool) -> [UInt8]? {
        if bytes.count == 4 {
            return databaseIsIPv6 ? Array(repeating: 0, count: 12) + bytes : bytes
        }
        if bytes.count == 16 {
            return bytes
        }
        return nil
    }

    // MARK: - Decoding

    private static func findMarker(_ marker: Data, in data: Data) -> Int? {
        // The spec caps the metadata section at 128 KB from the end of the file.
        let limit = 128 * 1024
        let start = max(0, data.count - limit)
        var candidate = start
        let first = marker[marker.startIndex]
        while candidate <= data.count - marker.count {
            if data[candidate] == first,
               data[candidate..<(candidate + marker.count)].elementsEqual(marker) {
                return candidate
            }
            candidate += 1
        }
        return nil
    }

    /// Decodes the value starting at `offset`. `pointerBase` is the offset that
    /// a data-section pointer is relative to - the metadata region for the
    /// metadata map, the data section for everything else.
    private static func decodeValue(in data: Data, at offset: Int, pointerBase: Int) throws -> MMDBValue {
        var cursor = offset
        return try decode(in: data, cursor: &cursor, pointerBase: pointerBase, depth: 0)
    }

    private static func decode(
        in data: Data,
        cursor: inout Int,
        pointerBase: Int,
        depth: Int
    ) throws -> MMDBValue {
        guard depth <= 32 else { throw MMDBError.malformedMetadata("nesting is too deep") }
        let control = try byte(at: cursor, in: data)
        cursor += 1
        var type = Int(control >> 5)
        if type == 0 {
            // Extended: the real type is the next byte plus seven.
            type = Int(try byte(at: cursor, in: data)) + 7
            cursor += 1
        }
        let sizeBits = Int(control & 0x1F)

        switch type {
        case 1: // pointer
            let size = ((Int(control) >> 3) & 0x3) + 1
            var value: Int
            switch size {
            case 1:
                value = ((Int(control) & 0x7) << 8) | Int(try byte(at: cursor, in: data))
                cursor += 1
            case 2:
                let b = try bytes(at: cursor, count: 2, in: data)
                value = (((Int(control) & 0x7) << 16) | (Int(b[0]) << 8) | Int(b[1])) + 2048
                cursor += 2
            case 3:
                let b = try bytes(at: cursor, count: 3, in: data)
                value = (((Int(control) & 0x7) << 24) | (Int(b[0]) << 16) | (Int(b[1]) << 8) | Int(b[2])) + 526336
                cursor += 3
            default:
                let b = try bytes(at: cursor, count: 4, in: data)
                value = (Int(b[0]) << 24) | (Int(b[1]) << 16) | (Int(b[2]) << 8) | Int(b[3])
                cursor += 4
            }
            var target = pointerBase + value
            return try decode(in: data, cursor: &target, pointerBase: pointerBase, depth: depth + 1)

        case 2: // UTF-8 string
            let size = try resolveSize(sizeBits, cursor: &cursor, in: data)
            let raw = try bytes(at: cursor, count: size, in: data)
            cursor += size
            return .string(String(decoding: raw, as: UTF8.self))

        case 3: // double
            let raw = try bytes(at: cursor, count: 8, in: data)
            cursor += 8
            var bits: UInt64 = 0
            for b in raw { bits = (bits << 8) | UInt64(b) }
            return .double(Double(bitPattern: bits))

        case 4: // bytes
            let size = try resolveSize(sizeBits, cursor: &cursor, in: data)
            let raw = try bytes(at: cursor, count: size, in: data)
            cursor += size
            return .bytes(raw)

        case 5, 6, 9, 10: // uint16 / uint32 / uint64 / uint128
            // The encoder trims leading zero bytes, so the declared size is the
            // width actually stored, not the type's nominal width.
            let size = try resolveSize(sizeBits, cursor: &cursor, in: data)
            let raw = try bytes(at: cursor, count: size, in: data)
            cursor += size
            var value: UInt64 = 0
            for b in raw { value = (value << 8) | UInt64(b) }
            return type == 10 ? .bytes(raw) : .uint(value)

        case 7: // map
            let size = try resolveSize(sizeBits, cursor: &cursor, in: data)
            var out: [String: MMDBValue] = [:]
            out.reserveCapacity(size)
            for _ in 0..<size {
                let key = try decode(in: data, cursor: &cursor, pointerBase: pointerBase, depth: depth + 1)
                guard case .string(let name) = key else {
                    throw MMDBError.malformedMetadata("a map key was not a string")
                }
                out[name] = try decode(in: data, cursor: &cursor, pointerBase: pointerBase, depth: depth + 1)
            }
            return .map(out)

        case 8: // int32
            let size = try resolveSize(sizeBits, cursor: &cursor, in: data)
            let raw = try bytes(at: cursor, count: size, in: data)
            cursor += size
            var value: UInt32 = 0
            for b in raw { value = (value << 8) | UInt32(b) }
            return .int(Int32(bitPattern: value))

        case 11: // array
            let size = try resolveSize(sizeBits, cursor: &cursor, in: data)
            var out: [MMDBValue] = []
            out.reserveCapacity(size)
            for _ in 0..<size {
                out.append(try decode(in: data, cursor: &cursor, pointerBase: pointerBase, depth: depth + 1))
            }
            return .array(out)

        case 14: // boolean: the size field carries the value
            return .bool(sizeBits != 0)

        case 15: // float
            let raw = try bytes(at: cursor, count: 4, in: data)
            cursor += 4
            var bits: UInt32 = 0
            for b in raw { bits = (bits << 8) | UInt32(b) }
            return .float(Double(Float(bitPattern: bits)))

        default:
            return .unsupported(type)
        }
    }

    /// The five size bits either hold the size directly or select an extended
    /// form with one, two or three following bytes.
    private static func resolveSize(_ sizeBits: Int, cursor: inout Int, in data: Data) throws -> Int {
        switch sizeBits {
        case 0..<29:
            return sizeBits
        case 29:
            let b = try byte(at: cursor, in: data)
            cursor += 1
            return 29 + Int(b)
        case 30:
            let b = try bytes(at: cursor, count: 2, in: data)
            cursor += 2
            return 285 + (Int(b[0]) << 8) + Int(b[1])
        default:
            let b = try bytes(at: cursor, count: 3, in: data)
            cursor += 3
            return 65821 + (Int(b[0]) << 16) + (Int(b[1]) << 8) + Int(b[2])
        }
    }

    private static func byte(at offset: Int, in data: Data) throws -> UInt8 {
        guard offset >= 0, offset < data.count else {
            throw MMDBError.malformedMetadata("a value ran past the end of the file")
        }
        return data[offset]
    }

    private static func bytes(at offset: Int, count: Int, in data: Data) throws -> [UInt8] {
        guard count >= 0, offset >= 0, offset + count <= data.count else {
            throw MMDBError.malformedMetadata("a value ran past the end of the file")
        }
        guard count > 0 else { return [] }
        return Array(data[offset..<(offset + count)])
    }
}

/// A decoded MMDB value. Deliberately a small closed enum rather than `Any`, so
/// the reader stays `Sendable` and callers have to handle every case.
public enum MMDBValue: Sendable, Equatable {
    case string(String)
    case double(Double)
    case float(Double)
    case bytes([UInt8])
    case uint(UInt64)
    case int(Int32)
    case map([String: MMDBValue])
    case array([MMDBValue])
    case bool(Bool)
    case unsupported(Int)

    // MARK: Typed accessors, for walking a record without pattern-matching noise.

    public subscript(key: String) -> MMDBValue? {
        if case .map(let fields) = self { return fields[key] }
        return nil
    }

    public subscript(index: Int) -> MMDBValue? {
        if case .array(let items) = self, index >= 0, index < items.count { return items[index] }
        return nil
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var doubleValue: Double? {
        switch self {
        case .double(let d), .float(let d): return d
        case .uint(let v): return Double(v)
        case .int(let v): return Double(v)
        default: return nil
        }
    }
}
