// Modified for Barc: selected-engine predictions without profile cookies, 2026-10-25.
import Foundation

/// Uses the engines' public OpenSearch-style endpoints. Local matches are
/// presented first; this request is cancelled with the command-bar query.
actor SearchSuggestions {
    static let shared = SearchSuggestions()
    static let maximumBytes = 64 * 1024
    private let session:URLSession

    init(session:URLSession? = nil) {
        if let session { self.session = session;return }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 1.2
        configuration.timeoutIntervalForResource = 2
        configuration.waitsForConnectivity = false
        self.session = URLSession(configuration:configuration)
    }

    /// Endpoint definitions follow the public engine definitions at
    /// https://chromium.googlesource.com/external/search_engines_data/+/refs/heads/main/definitions/prepopulated_engines.json
    static func request(for query:String,engine:SearchEngine) -> URLRequest? {
        let text = query.trimmingCharacters(in:.whitespacesAndNewlines)
        // Address paths, credentials and pasted multi-line material stay local.
        guard !text.isEmpty,text.utf16.count<=200,
              !text.contains(where:{ "@/\\:?&#=".contains($0) }),
              !text.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains) else { return nil }
        let base:String,key:String
        switch engine.id {
        case SearchEngine.duckDuckGo.id:base = "https://duckduckgo.com/ac/";key = "q"
        case SearchEngine.google.id:base = "https://www.google.com/complete/search";key = "q"
        case SearchEngine.bing.id:base = "https://www.bing.com/osjson.aspx";key = "query"
        default:return nil
        }
        var components = URLComponents(string:base)!
        components.queryItems = [.init(name:key,value:text)]
        if engine.id == SearchEngine.duckDuckGo.id { components.queryItems?.append(.init(name:"type",value:"list")) }
        if engine.id == SearchEngine.google.id { components.queryItems?.append(.init(name:"client",value:"chrome")) }
        guard let url = components.url else { return nil }
        var request = URLRequest(url:url)
        request.httpShouldHandleCookies = false
        request.setValue("application/json",forHTTPHeaderField:"Accept")
        return request
    }

    func suggestions(for query:String,engine:SearchEngine) async -> [String] {
        guard let request = Self.request(for:query,engine:engine),!Task.isCancelled else { return [] }
        do {
            let (data,response) = try await session.data(for:request)
            guard !Task.isCancelled,let response = response as? HTTPURLResponse,response.statusCode == 200,
                  response.expectedContentLength<=Self.maximumBytes else { return [] }
            return Self.decode(data,query:query,encodingName:response.textEncodingName)
        } catch { return [] }
    }

    static func decode(_ data:Data,query:String,encodingName:String? = nil) -> [String] {
        var encoding = String.Encoding.utf8
        if let encodingName {
            let value = CFStringConvertIANACharSetNameToEncoding(encodingName as CFString)
            if value != kCFStringEncodingInvalidId { encoding = String.Encoding(rawValue:CFStringConvertEncodingToNSStringEncoding(value)) }
        }
        guard data.count<=maximumBytes,var text = String(data:data,encoding:encoding) else { return [] }
        if text.hasPrefix(")]}'") { text = String(text.dropFirst(4)).trimmingCharacters(in:.whitespacesAndNewlines) }
        guard let json = text.data(using:.utf8),
              let payload = try? JSONSerialization.jsonObject(with:json) as? [Any],payload.count>=2,
              let echo = payload[0] as? String,
              echo.trimmingCharacters(in:.whitespacesAndNewlines).caseInsensitiveCompare(query.trimmingCharacters(in:.whitespacesAndNewlines)) == .orderedSame,
              let values = payload[1] as? [String] else { return [] }
        var seen:Set<String> = [query.trimmingCharacters(in:.whitespacesAndNewlines).lowercased()]
        return Array(values.compactMap { value -> String? in
            let value = value.trimmingCharacters(in:.whitespacesAndNewlines)
            guard !value.isEmpty,value.utf16.count<=200,
                  !value.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains),
                  seen.insert(value.lowercased()).inserted else { return nil }
            return value
        }.prefix(6))
    }
}
