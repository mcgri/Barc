// Modified for Barc: literal page, Space and folder matching from Arc's URL popup, 2026-10-24.
import Foundation
import Testing
@testable import Barc

@Suite("URL popup local matching")
struct URLPopupMatchingTests {
    private let unrelated = "Status items; link check; end steps; test evidence; release"
    private func tab(_ title:String,_ path:String)->TabCandidate {
        .init(id:UUID(),title:title,address:path,url:URL(string:"https://"+path)!,isActive:false)
    }

    @Test("Scattered letters cannot produce unrelated tabs, history, bookmarks, Spaces or folders")
    func scatteredLettersAreNotPageMatches() {
        let intended = tab("Silvermere","docs.example/project")
        let titleNoise = tab(unrelated,"board.example/project")
        let urlNoise = tab("Project","board.example/card/s7i4l9v2e3r8m5e4r1e")
        let history = HistoryCandidate(url:URL(string:"https://history.example/project")!,title:unrelated,key:"history.example/project",visitCount:999)
        let bookmark = BookmarkCandidate(url:URL(string:"https://saved.example/project")!,title:unrelated,key:"saved.example/project")
        let rows = CommandRanker.rank(query:"silvermere",tabs:[intended,titleNoise,urlNoise],
            spaces:[.init(id:UUID(),name:unrelated,isActive:false)],
            folders:[.init(id:UUID(),spaceID:UUID(),name:unrelated,path:"Work / "+unrelated)],
            history:[history],bookmarks:[bookmark],
            search:.init(engineName:"Search",url:URL(string:"https://search.example/?q=silvermere")!))
        #expect(rows.map(\.kind) == [.openTab,.search])
        #expect(rows.first?.action == .switchToTab(intended.id))
    }

    @Test("Arc matches a contiguous prefix or substring, but not abbreviations or spelling deletions")
    func observedNameQueries() {
        let page = tab("Silvermere","docs.example/project")
        for query in ["silvermere","silve","lvermere","SÍLVÉRMERE"] {
            #expect(CommandRanker.rank(query:query,tabs:[page],history:[]).contains { $0.action == .switchToTab(page.id) })
        }
        for query in ["slch","silvrmere","silvemere","sil ver","s ilvermere","vermere sil"] {
            #expect(CommandRanker.rank(query:query,tabs:[page],history:[]).isEmpty)
        }
    }

    @Test("Page names require a contiguous phrase even when all query words appear in the title")
    func pagePhrases() {
        let page = tab("What is example package?","board.example/project")
        #expect(CommandRanker.rank(query:"example package",tabs:[page],history:[]).first?.action == .switchToTab(page.id))
        for query in ["package example","examp pack","ample ackage"] {
            #expect(CommandRanker.rank(query:query,tabs:[page],history:[]).isEmpty)
        }
    }

    @Test("Folder names use the same literal rule while complete path prefixes remain searchable")
    func observedFolderQueries() {
        let folder = FolderCandidate(id:UUID(),spaceID:UUID(),name:"Pull Requests",path:"Work / Pull Requests")
        for query in ["pull req","requests","Work / Pull","ull re","requests pull","pull pull","requests requests","open requests","requests open","requests pull open"] {
            #expect(CommandRanker.rank(query:query,tabs:[],folders:[folder],history:[]).first?.action == .openFolder(spaceID:folder.spaceID,folderID:folder.id))
        }
        for query in ["plrq","pr","pullreq","req pull","req pul","requests pu","requests pul","requests pullx","pu requests","pull reqx"] {
            #expect(CommandRanker.rank(query:query,tabs:[],folders:[folder],history:[]).isEmpty)
        }
    }

    @Test("Intentional command abbreviations keep their action and keyboard shortcut")
    func commandAbbreviationsRemainSeparate() {
        let command = CommandCandidate(id:"new-tab",title:"New Tab",symbolName:"plus",shortcut:"⌘T")
        let rows = CommandRanker.rank(query:"ntb",tabs:[],commands:[command],history:[])
        #expect(rows.first?.action == .runCommand("new-tab") && rows.first?.shortcut == "⌘T")
    }

    @Test("Address normalization and real match tiers remain unchanged")
    func addressTiers() {
        #expect(CommandRanker.score(query:"https://www.example.com/",title:"Page",address:"example.com/docs") == CommandRanker.Tier.addressPrefix)
        #expect(CommandRanker.score(query:"example.com",title:"Page",address:"example.com/docs") == CommandRanker.Tier.exactHost)
        #expect(CommandRanker.score(query:"docs",title:"Page",address:"example.com/docs") == CommandRanker.Tier.wordPrefix)
    }
}
