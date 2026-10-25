// Modified for Barc: launch the actual browser UI with isolated demonstration data, 2026-10-25.
import AppKit

/// Available only in a separately identified review copy of the bundle. It
/// never restores a user's session or starts import, sync or password services.
@MainActor
enum SidebarReview {
    static var requested:Bool {
        CommandLine.arguments.contains("--sidebar-review")
            && AppPaths.bundleIdentifier.hasPrefix("io.github.mcgri.Barc.Review.")
    }
    static func makeSession() -> BrowserSession {
        let settings = Settings.shared
        settings.restoresSession = false
        let session = BrowserSession(database:nil,settings:settings)
        let page = AppPaths.supportDirectory.appending(path:"review.html")
        settings.customSearchEngines = [.init(id:"custom:review",name:"Review Search",
            queryTemplate:page.absoluteString+"?q={query}",homeURL:page,keyword:"rs")]
        let html = """
        <!doctype html><meta charset="utf-8"><title>Sidebar review</title>
        <style>body{font:22px Georgia;background:#fafafa;color:#202020;margin:40px}h1{font-size:36px}.grid{display:grid;grid-template-columns:1fr 1fr;gap:32px}article{padding:28px;border-top:5px solid #333;background:white}p{line-height:1.5}small{font:14px system-ui;color:#666}</style>
        <h1>Browser sidebar review</h1><div class="grid"><article><h2>A stable place to search</h2><p>Open a new tab and type. The input stays in place while suggestions change underneath it.</p><small>Local demonstration page</small></article><article><h2>Spaces and split views</h2><p>Rename a split, select its panes, and switch Spaces without changing the page data in another profile.</p><small>Isolated review session</small></article></div>
        """
        try? html.write(to:page,atomically:true,encoding:.utf8)
        let favoritePage = AppPaths.supportDirectory.appending(path:"favorite.html")
        try? html.replacingOccurrences(of:"Browser sidebar review",with:"Favorite review page").write(to:favoritePage,atomically:true,encoding:.utf8)
        let owner = session.activeSpace
        owner.addPinnedSite(.init(url:favoritePage,title:"Review Favorite"))
        let secondFavorite = AppPaths.supportDirectory.appending(path:"favorite-two.html")
        try? html.replacingOccurrences(of:"Browser sidebar review",with:"Second Favorite page").write(to:secondFavorite,atomically:true,encoding:.utf8)
        owner.addPinnedSite(.init(url:secondFavorite,title:"Second Favorite"))
        session.rename(owner,to:"Personal")
        let main = session.newTab(url:page);session.rename(main,to:"Sidebar review")
        for (index,name) in ["Example Cloud Sign-in","Instances | Example | region-one","Example Accounts","Sample reporting"].enumerated() {
            let tab = session.newTab(url:URL(string:"https://example.invalid/review/\(index)")!,select:false)
            session.rename(tab,to:name)
        }
        let a = session.newTab(url:page,select:false),b = session.newTab(url:page,select:false)
        session.rename(a,to:"Research");session.rename(b,to:"Notes")
        session.splitTabs([a,b]);session.renameSplit(containing:a.id,in:owner,to:"Research pair")
        session.pin(a)
        for name in ["Work","Projects"] {
            if let profile = session.addProfile(named:name) { _ = session.addSpace(named:name,profile:profile) }
        }
        session.selectSpace(owner);session.selectTab(main)
        return session
    }
}

@MainActor
final class SidebarReviewMenuDelegate:NSObject,NSMenuDelegate { }
