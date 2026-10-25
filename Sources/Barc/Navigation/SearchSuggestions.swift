// Modified for Barc: selected-engine predictions without profile cookies, 2026-10-25.
import Foundation

enum SearchPrediction:Equatable,Sendable {
    case query(String)
    case navigation(URL,title:String)
    var text:String {
        switch self {
        case .query(let text):text
        case .navigation(let url,_):url.absoluteString
        }
    }
}

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
    static func request(for query:String,engine:SearchEngine,explicitSearch:Bool = false) -> URLRequest? {
        let text = query.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !text.isEmpty,text.utf16.count<=200,
              !text.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains),
              explicitSearch || !isAddressPotentiallyPrivate(text) else { return nil }
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

    /// Mirrors Chromium's distinction between query punctuation and URL parts,
    /// using Barc's navigation classification. Keyword/site mode is an explicit
    /// search, while default-engine suggestions must not disclose private URLs.
    /// https://github.com/chromium/chromium/blob/main/components/omnibox/browser/search_provider.cc
    static func isAddressPotentiallyPrivate(_ text:String) -> Bool {
        if let url = URLResolver.navigationURL(text),
           let parts = URLComponents(url:url,resolvingAgainstBaseURL:false) {
            guard let scheme = parts.scheme?.lowercased(),["http","https","ftp"].contains(scheme) else { return true }
            if parts.user != nil || parts.password != nil || parts.port != nil || parts.query != nil || parts.fragment != nil { return true }
            return scheme == "https" && !parts.percentEncodedPath.isEmpty
        }
        // Do not misclassify ordinary multiword questions such as "why: now?"
        // or "cats & dogs" as URLs merely because they contain punctuation.
        guard !text.contains(where: \.isWhitespace) else {
            return text.contains("://") || ["file:","data:","javascript:","blob:"].contains { text.lowercased().hasPrefix($0) }
        }
        if text.contains("@") || text.hasPrefix("/") || text.hasPrefix("\\") { return true }
        if text.hasPrefix("?"),text.contains("=") { return true }
        // Unknown/custom schemes and incomplete credential-like inputs are local.
        return URLComponents(string:text)?.scheme != nil
    }

    func suggestions(for query:String,engine:SearchEngine,explicitSearch:Bool = false) async -> [String] {
        await results(for:query,engine:engine,explicitSearch:explicitSearch).map(\.text)
    }

    func results(for query:String,engine:SearchEngine,explicitSearch:Bool = false) async -> [SearchPrediction] {
        guard let request = Self.request(for:query,engine:engine,explicitSearch:explicitSearch),!Task.isCancelled else { return [] }
        do {
            let (data,response) = try await session.data(for:request)
            guard !Task.isCancelled,let response = response as? HTTPURLResponse,response.statusCode == 200,
                  response.expectedContentLength<=Self.maximumBytes else { return [] }
            return Self.decodeResults(data,query:query,encodingName:response.textEncodingName)
        } catch { return [] }
    }

    static func decode(_ data:Data,query:String,encodingName:String? = nil) -> [String] {
        decodeResults(data,query:query,encodingName:encodingName).map(\.text)
    }

    static func decodeResults(_ data:Data,query:String,encodingName:String? = nil) -> [SearchPrediction] {
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
        let metadata = payload.count>4 ? payload[4] as? [String:Any]:nil
        let types = metadata?["google:suggesttype"] as? [String] ?? []
        let descriptions = payload.count>2 ? payload[2] as? [String] ?? []:[]
        var seen:Set<String> = [query.trimmingCharacters(in:.whitespacesAndNewlines).lowercased()]
        var seenNavigation:Set<String> = []
        return Array(values.enumerated().compactMap { index,value -> SearchPrediction? in
            let value = value.trimmingCharacters(in:.whitespacesAndNewlines)
            guard !value.isEmpty,value.utf16.count<=200,
                  !value.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains) else { return nil }
            if types.indices.contains(index),["NAVIGATION","PERSONALIZED_NAVIGATION"].contains(types[index]) {
                guard let url = URLResolver.navigationURL(value),["http","https"].contains(url.scheme?.lowercased() ?? ""),
                      let host = url.host(),!host.isEmpty,url.user == nil,url.password == nil,
                      seenNavigation.insert(AddressFormatter.destinationKey(url)).inserted else { return nil }
                let description = descriptions.indices.contains(index) ? descriptions[index]:""
                let title = description.utf16.count<=512 && !description.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains) ? description:""
                return .navigation(url,title:title)
            }
            guard seen.insert(value.lowercased()).inserted else { return nil }
            return .query(value)
        }.prefix(6))
    }
}
