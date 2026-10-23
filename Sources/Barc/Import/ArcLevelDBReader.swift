import Foundation

/// Read-only LevelDB decoding for Chromium local storage. Replays CURRENT's
/// manifest and tombstones instead of resurrecting obsolete .ldb files.
enum ArcLevelDBReader {
    struct Entry: Sendable {
        let sequence: UInt64
        let value: Data?
    }
    struct Cursor {
        let bytes: [UInt8]
        var position = 0
        init(_ data: Data) { bytes = Array(data) }
        var remaining: Int { bytes.count - position }
        mutating func byte() throws -> UInt8 {
            guard position < bytes.count else { throw failure("truncated data") }
            defer { position += 1 }; return bytes[position]
        }
        mutating func take(_ count: Int) throws -> Data {
            guard count >= 0, count <= remaining else { throw failure("truncated record") }
            defer { position += count }; return Data(bytes[position..<(position + count)])
        }
        mutating func varint() throws -> UInt64 {
            var value: UInt64 = 0
            for shift in stride(from: 0, through: 63, by: 7) {
                let next = try byte()
                if shift == 63 && next > 1 { throw failure("invalid integer") }
                value |= UInt64(next & 0x7f) << shift
                if next & 0x80 == 0 { return value }
            }
            throw failure("invalid integer")
        }
        mutating func lengthPrefixed() throws -> Data {
            let length = try varint()
            guard length <= UInt64(remaining) else { throw failure("invalid record length") }
            return try take(Int(length))
        }
    }

    private static func failure(_ reason: String) -> ArcImportFailure { .unsupportedStorage(reason) }
    private static func little(_ data: Data) -> UInt64 {
        data.enumerated().reduce(0) { $0 | (UInt64($1.element) << ($1.offset * 8)) }
    }
    private static let crcTable: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 { crc = crc & 1 == 0 ? crc >> 1 : (crc >> 1) ^ 0x82f63b78 }
        return crc
    }
    static func maskedCRC(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for byte in data { crc = crcTable[Int((crc ^ UInt32(byte)) & 0xff)] ^ (crc >> 8) }
        crc = ~crc
        return ((crc >> 15) | (crc << 17)) &+ 0xa282ead8
    }

    static func logRecords(_ data: Data) throws -> [Data] {
        let bytes = Array(data)
        var position = 0
        var fragments = Data()
        var active = false
        var result: [Data] = []
        while position + 7 <= bytes.count {
            let blockRemaining = 32768 - position % 32768
            if blockRemaining < 7 { position += blockRemaining; continue }
            let length = Int(bytes[position + 4]) | (Int(bytes[position + 5]) << 8)
            let type = bytes[position + 6]
            if length == 0 && type == 0 { position += blockRemaining; continue }
            guard length + 7 <= blockRemaining else { throw failure("invalid log block") }
            guard position + 7 + length <= bytes.count else { break } // uncommitted tail
            let payload = Data(bytes[(position + 7)..<(position + 7 + length)])
            let expected = UInt32(little(Data(bytes[position..<(position + 4)])))
            guard maskedCRC(Data([type]) + payload) == expected else { throw failure("log checksum mismatch") }
            switch type {
            case 1: guard !active else { throw failure("incomplete log record") }; result.append(payload)
            case 2: guard !active else { throw failure("overlapping log records") }; fragments = payload; active = true
            case 3: guard active else { throw failure("missing log fragment") }; fragments.append(payload)
            case 4: guard active else { throw failure("missing log fragment") }; fragments.append(payload); result.append(fragments); fragments = Data(); active = false
            default: throw failure("unknown log record")
            }
            position += 7 + length
        }
        return result
    }

    static func snappy(_ data: Data) throws -> Data {
        var input = Cursor(data)
        let length = try input.varint()
        guard length <= 64 * 1024 * 1024 else { throw failure("storage block is too large") }
        var output: [UInt8] = []
        output.reserveCapacity(Int(length))
        while input.remaining > 0 && output.count < length {
            let tag = try input.byte()
            switch tag & 3 {
            case 0:
                var count = Int(tag >> 2)
                if count < 60 { count += 1 }
                else { count = Int(little(try input.take(count - 59))) + 1 }
                guard count <= Int(length) - output.count else { throw failure("invalid compressed literal") }
                output += try input.take(count)
            case 1, 2, 3:
                let kind = tag & 3
                let count: Int
                let offset: Int
                if kind == 1 {
                    count = Int((tag >> 2) & 7) + 4
                    offset = (Int(tag & 0xe0) << 3) | Int(try input.byte())
                } else {
                    count = Int(tag >> 2) + 1
                    offset = Int(little(try input.take(kind == 2 ? 2 : 4)))
                }
                guard offset > 0, offset <= output.count, count <= Int(length) - output.count else { throw failure("invalid compressed copy") }
                for _ in 0..<count { output.append(output[output.count - offset]) }
            default: throw failure("invalid compression tag")
            }
        }
        guard output.count == length, input.remaining == 0 else { throw failure("incomplete compressed block") }
        return Data(output)
    }

    private static func block(_ file: Data, offset: UInt64, size: UInt64) throws -> Data {
        guard offset <= UInt64(file.count), size <= UInt64(file.count) - offset,
              offset + size + 5 <= file.count else { throw failure("invalid table block") }
        let start = Int(offset), end = Int(offset + size)
        let payload = Data(file[start..<end])
        let compression = file[end]
        let expected = UInt32(little(Data(file[(end + 1)..<(end + 5)])))
        guard maskedCRC(payload + Data([compression])) == expected else { throw failure("table checksum mismatch") }
        switch compression {
        case 0: return payload
        case 1: return try snappy(payload)
        default: throw failure("unsupported table compression")
        }
    }

    private static func entries(_ data: Data) throws -> [(Data, Data)] {
        guard data.count >= 4 else { throw failure("invalid table entries") }
        let restarts = Int(little(Data(data.suffix(4))))
        guard restarts <= (data.count - 4) / 4 else { throw failure("invalid table restart array") }
        let length = data.count - (restarts + 1) * 4
        var reader = Cursor(Data(data.prefix(length)))
        var previous = Data()
        var output: [(Data, Data)] = []
        while reader.remaining > 0 {
            let shared = try reader.varint(), added = try reader.varint(), valueLength = try reader.varint()
            guard shared <= previous.count, added <= reader.remaining, valueLength <= UInt64(reader.remaining) - added else {
                throw failure("invalid table entry")
            }
            let key = Data(previous.prefix(Int(shared))) + (try reader.take(Int(added)))
            let value = try reader.take(Int(valueLength))
            output.append((key, value)); previous = key
        }
        return output
    }

    private static func table(_ path: URL) throws -> [(Data, Data)] {
        let file = try Data(contentsOf: path, options: .mappedIfSafe)
        guard file.count >= 48, little(Data(file.suffix(8))) == 0xdb4775248b80fb57 else { throw failure("unknown table format") }
        var footer = Cursor(Data(file.suffix(48).prefix(40)))
        _ = try footer.varint(); _ = try footer.varint() // meta-index
        let offset = try footer.varint(), size = try footer.varint()
        let index = try entries(block(file, offset: offset, size: size))
        var output: [(Data, Data)] = []
        for (_, handle) in index {
            var reader = Cursor(handle)
            let offset = try reader.varint(), size = try reader.varint()
            output += try entries(block(file, offset: offset, size: size))
        }
        return output
    }

    static func read(_ directory: URL) throws -> [Data: Entry] {
        let current = try String(contentsOf: directory.appending(path: "CURRENT"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard current.hasPrefix("MANIFEST-"), ArcSourceSnapshotter.validProfileName(current) else { throw failure("invalid storage manifest") }
        let edits = try logRecords(Data(contentsOf: directory.appending(path: current)))
        var files: Set<UInt64> = []
        var logNumber: UInt64 = 0
        var previousLog: UInt64 = 0
        for edit in edits {
            var reader = Cursor(edit)
            while reader.remaining > 0 {
                switch try reader.varint() {
                case 1: _ = try reader.lengthPrefixed()
                case 2: logNumber = try reader.varint()
                case 3, 4: _ = try reader.varint()
                case 5: _ = try reader.varint(); _ = try reader.lengthPrefixed()
                case 6: _ = try reader.varint(); files.remove(try reader.varint())
                case 7:
                    _ = try reader.varint(); files.insert(try reader.varint()); _ = try reader.varint()
                    _ = try reader.lengthPrefixed(); _ = try reader.lengthPrefixed()
                case 9: previousLog = try reader.varint()
                default: throw failure("unsupported storage manifest")
                }
            }
        }
        var latest: [Data: Entry] = [:]
        func apply(_ key: Data, value: Data?, sequence: UInt64) {
            if let old = latest[key], old.sequence >= sequence { return }
            latest[key] = Entry(sequence: sequence, value: value)
        }
        let directoryFiles = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        var found: Set<UInt64> = []
        for path in directoryFiles where ["ldb", "sst"].contains(path.pathExtension) {
            guard let number = UInt64(path.deletingPathExtension().lastPathComponent), files.contains(number) else { continue }
            found.insert(number)
            for (internalKey, value) in try table(path) {
                guard internalKey.count >= 8 else { throw failure("invalid internal storage key") }
                let tag = little(Data(internalKey.suffix(8)))
                guard tag & 0xff <= 1 else { throw failure("unsupported storage record") }
                apply(Data(internalKey.dropLast(8)), value: tag & 0xff == 1 ? value : nil, sequence: tag >> 8)
            }
        }
        guard found == files else { throw failure("storage table is missing") }
        for path in directoryFiles where path.pathExtension == "log" {
            guard let number = UInt64(path.deletingPathExtension().lastPathComponent), number >= logNumber || number == previousLog else { continue }
            for batch in try logRecords(Data(contentsOf: path)) {
                guard batch.count >= 12 else { throw failure("invalid write batch") }
                let sequence = little(Data(batch.prefix(8)))
                let count = little(Data(batch.dropFirst(8).prefix(4)))
                var reader = Cursor(Data(batch.dropFirst(12)))
                guard count <= UInt64(reader.remaining / 2) else { throw failure("invalid write batch count") }
                let maximumSequence: UInt64 = 0x00ff_ffff_ffff_ffff
                guard sequence <= maximumSequence, count == 0 || count - 1 <= maximumSequence - sequence else {
                    throw failure("invalid write batch sequence")
                }
                for index in 0..<count {
                    let type = try reader.byte(), key = try reader.lengthPrefixed()
                    guard type <= 1 else { throw failure("unsupported write batch") }
                    apply(key, value: type == 1 ? try reader.lengthPrefixed() : nil, sequence: sequence + index)
                }
                guard reader.remaining == 0 else { throw failure("unexpected write batch data") }
            }
        }
        return latest
    }
}
