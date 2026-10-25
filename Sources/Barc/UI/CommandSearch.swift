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
        var seen = Set(local.map { $0.title.lowercased() })
        seen.insert(query.lowercased())
        let remote = predictions.compactMap { text -> CommandResult? in
            guard seen.insert(text.lowercased()).inserted else { return nil }
            return row(query:text,engine:engine,completion:completionPrefix+text,id:"prediction:\(engine.id):\(text)")
        }
        // Local actions retain their order and keyboard positions while the
        // network finishes. Predictions extend the list rather than reshuffle it.
        return local+remote
    }
}
