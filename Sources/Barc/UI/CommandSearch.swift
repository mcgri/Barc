// Modified for Barc: site searches and engine predictions share one destination contract, 2026-10-25.
import Foundation

enum CommandSearch {
    static func row(query:String,engine:SearchEngine,completion:String? = nil,id:String = "search") -> CommandResult? {
        guard let url = engine.url(for:query) else { return nil }
        return CommandResult(id:id,kind:.search,title:query,subtitle:url.host() ?? engine.name,
            symbolName:"magnifyingglass",action:.openURL(url),score:-1,completionText:completion ?? query)
    }

    static func adding(_ predictions:[String],query:String,engine:SearchEngine,
                       completionPrefix:String = "",to local:[CommandResult]) -> [CommandResult] {
        addingResults(predictions.map(SearchPrediction.query),query:query,engine:engine,completionPrefix:completionPrefix,to:local)
    }

    static func addingResults(_ predictions:[SearchPrediction],query:String,engine:SearchEngine,
                              completionPrefix:String = "",openTabs:[UUID:URL] = [:],to local:[CommandResult]) -> [CommandResult] {
        var seenQueries = Set(local.filter { $0.kind == .search }.map { $0.title.lowercased() })
        seenQueries.insert(query.lowercased())
        var seenDestinations = Set(local.compactMap { result -> String? in
            switch result.action {
            case .openURL(let url):return destinationKey(url)
            case .switchToTab(let id):return openTabs[id].map(destinationKey)
            default:return nil
            }
        })
        let remote = predictions.compactMap { prediction -> CommandResult? in
            switch prediction {
            case .query(let text):
                guard seenQueries.insert(text.lowercased()).inserted else { return nil }
                return row(query:text,engine:engine,completion:completionPrefix+text,id:"prediction:\(engine.id):\(text)")
            case .navigation(let url,let title):
                guard seenDestinations.insert(destinationKey(url)).inserted else { return nil }
                let address = AddressFormatter.display(url)
                return CommandResult(id:"navigation:\(engine.id):\(destinationKey(url))",kind:.address,
                    title:title.isEmpty ? address:title,subtitle:address,symbolName:"globe",action:.openURL(url),score:-1,
                    completionText:AddressFormatter.completion(url,matching:query))
            }
        }
        return local+remote
    }

    private static func destinationKey(_ url:URL) -> String {
        var key = AddressFormatter.completion(url).lowercased()
        if key.hasSuffix("/") { key.removeLast() }
        return key
    }
}
