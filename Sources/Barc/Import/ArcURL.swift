import Foundation

enum ArcURL {
    private static let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~:/?#@!$&'()*+,;=".utf8)
    /// Foundation re-encodes existing percent escapes when it encounters an
    /// invalid character elsewhere in a URL. Escape those characters first,
    /// keeping existing escapes and the meaning of Chromium's query strings.
    static func parse(_ raw: String) -> URL? {
        let bytes = Array(raw.utf8)
        let authorityStart = raw.range(of: "://").map { raw.utf8.distance(from: raw.utf8.startIndex, to: $0.upperBound) }
        let authorityEnd = authorityStart.map { start in
            bytes[start...].firstIndex { [UInt8(47), 63, 35].contains($0) } ?? bytes.count
        }
        let fragment = bytes.firstIndex(of: 35)
        func hexadecimal(_ value: UInt8) -> Bool {
            (48...57).contains(value) || (65...70).contains(value) || (97...102).contains(value)
        }
        var encoded = ""
        for (index, byte) in bytes.enumerated() {
            let escaped = byte == 37 && index + 2 < bytes.count && hexadecimal(bytes[index + 1]) && hexadecimal(bytes[index + 2])
            let bracket = (byte == 91 || byte == 93) && authorityStart.map { index >= $0 && index < (authorityEnd ?? 0) } == true
            let extraFragmentMarker = byte == 35 && fragment != index
            if escaped || bracket || (allowed.contains(byte) && !extraFragmentMarker) {
                encoded.append(Character(UnicodeScalar(byte)))
            } else { encoded += String(format: "%%%02X", byte) }
        }
        return URL(string: encoded, encodingInvalidCharacters: false)
    }
}
