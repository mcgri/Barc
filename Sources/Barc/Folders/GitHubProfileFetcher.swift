// Modified for Barc: GitHub live folders use their owning profile's WebKit session, 2026-10-25.
import Foundation
import WebKit

/// Reads GitHub's own search pages in the owning browser store. Cookies never
/// leave WebKit and no token is copied into the anonymous feed client.
@MainActor
enum GitHubProfileFetcher {
    struct Page:Decodable {
        var login:String
        var authenticated:Bool
        var valid:Bool
        var resultCount:Int
        var pageCount:Int
        var items:[Item]
        struct Item:Decodable {
            var id:String;var title:String;var url:URL;var author:String?;var date:String?;var draft:Bool
        }
    }
    static func fetch(_ config:GitHubLiveFolderProvider.Configuration,identity:Space.Identity) async -> LiveFolderFetch {
        let loader = PageLoader(identity:identity)
        do {
            let account = try await loader.load(URL(string:"https://github.com/pulls")!)
            guard account.authenticated,!account.login.isEmpty,
                  config.login.isEmpty || config.login.caseInsensitiveCompare(account.login) == .orderedSame else {
                return .blocked(.authenticationRequired)
            }
            let login = account.login
            var qualifiers:[String] = []
            if config.authorMe { qualifiers.append("author:\(login)") }
            if config.assignedMe { qualifiers.append("assignee:\(login)") }
            if config.scope == .pullRequests,config.reviewRequested { qualifiers.append("review-requested:\(login)") }
            guard !qualifiers.isEmpty else { return .blocked(.noFilterSelected) }
            var found:[String:LiveFolderItem] = [:]
            for qualifier in qualifiers {
                var pageNumber = 1,lastPage = 1
                repeat {
                    guard !Task.isCancelled else { return .blocked(.network("Cancelled")) }
                    var components = URLComponents(string:"https://github.com/search")!
                    var query = "is:open is:\(config.scope == .pullRequests ? "pr":"issue") \(qualifier)"
                    if config.scope == .pullRequests,!config.includeDrafts { query += " draft:false" }
                    components.queryItems = [.init(name:"q",value:query),.init(name:"type",value:config.scope == .pullRequests ? "pullrequests":"issues"),.init(name:"p",value:String(pageNumber))]
                    guard let url = components.url else { return .blocked(.malformedResponse) }
                    let page = try await loader.load(url)
                    guard page.authenticated,page.login.caseInsensitiveCompare(login) == .orderedSame else { return .blocked(.authenticationRequired) }
                    guard page.valid,page.resultCount>=0,page.pageCount>=0,
                          page.resultCount == 0 || (!page.items.isEmpty && page.pageCount>0) else { return .blocked(.malformedResponse) }
                    // A partial response must never masquerade as the full set
                    // and cause existing private items to be pruned.
                    guard page.pageCount<=10 else { return .blocked(.incompleteResults) }
                    lastPage = max(1,page.pageCount)
                    for item in page.items {
                        let repository = item.id.split(separator:"#").first.map(String.init) ?? ""
                        guard !config.excludedRepositories.contains(repository),config.includeDrafts || !item.draft else { continue }
                        found[item.id] = .init(id:item.id,title:item.title,url:item.url,subtitle:item.author,date:FeedDate.parse(item.date ?? ""))
                    }
                    pageNumber += 1
                } while pageNumber<=lastPage
            }
            return .items(found.values.sorted { ($0.date ?? .distantPast)>($1.date ?? .distantPast) })
        } catch let issue as FetchIssue { return .blocked(issue.issue) }
        catch { return .blocked(.network((error as NSError).localizedDescription)) }
    }
    private struct FetchIssue:Error { let issue:LiveFolderIssue }

    private final class PageLoader:NSObject,WKNavigationDelegate {
        private let webView:WKWebView
        private var pending:CheckedContinuation<Page,Error>?
        private var timeout:Task<Void,Never>?
        init(identity:Space.Identity) {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = WebEnvironment.shared.dataStore(for:identity)
            webView = WKWebView(frame:NSRect(x:0,y:0,width:900,height:700),configuration:configuration)
            super.init();webView.navigationDelegate = self
        }
        func load(_ url:URL) async throws -> Page {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    pending = continuation
                    timeout = Task { [weak self] in
                        do { try await Task.sleep(for:.seconds(20)) } catch { return }
                        self?.finish(.failure(FetchIssue(issue:.network("GitHub timed out"))))
                    }
                    webView.load(URLRequest(url:url))
                }
            } onCancel: { Task { @MainActor [weak self] in self?.finish(.failure(CancellationError())) } }
        }
        private func finish(_ result:Result<Page,Error>) {
            guard let pending else { return };self.pending = nil
            timeout?.cancel();timeout = nil;webView.stopLoading();pending.resume(with:result)
        }
        func webView(_ webView:WKWebView,didFinish navigation:WKNavigation!) {
            Task { [weak self] in
                guard let self else { return }
                do {
                    guard let text = try await webView.evaluateJavaScript(GitHubProfileFetcher.extractionScript) as? String,
                          let data = text.data(using:.utf8) else { throw FetchIssue(issue:.malformedResponse) }
                    finish(.success(try JSONDecoder().decode(Page.self,from:data)))
                } catch { finish(.failure(error)) }
            }
        }
        func webView(_ webView:WKWebView,didFail navigation:WKNavigation!,withError error:Error) { finish(.failure(error)) }
        func webView(_ webView:WKWebView,didFailProvisionalNavigation navigation:WKNavigation!,withError error:Error) { finish(.failure(error)) }
        func webView(_ webView:WKWebView,decidePolicyFor navigationAction:WKNavigationAction,decisionHandler:@escaping @MainActor @Sendable (WKNavigationActionPolicy)->Void) {
            if navigationAction.targetFrame?.isMainFrame != false,
               navigationAction.request.url.map({ $0.scheme != "https" || $0.host() != "github.com" }) != false {
                decisionHandler(.cancel);finish(.failure(FetchIssue(issue:.authenticationRequired)));return
            }
            decisionHandler(.allow)
        }
    }

        // The current GitHub page embeds the authoritative search payload.
        // Unknown markup is a failure, never an authoritative empty folder.
    static let extractionScript = #"""
        (() => {
          const login = document.querySelector('meta[name="user-login"]')?.content || '';
          let route = null;
          for (const script of document.querySelectorAll('script[data-target="react-app.embeddedData"]')) {
            try {
              const data = JSON.parse(script.textContent);
              const candidate = data.payload?.blackbirdSearchRoute || data.payload;
              if (candidate && Array.isArray(candidate.results) && typeof candidate.result_count === 'number') route = candidate;
            } catch (_) {}
          }
          const text = value => { const div = document.createElement('div'); div.innerHTML = String(value || ''); return div.textContent || ''; };
          const items = [];
          if (route) for (const item of route.results) {
            const repo = item.repo?.repository;
            if (!repo || !/^[\w.-]+$/.test(repo.owner_login) || !/^[\w.-]+$/.test(repo.name) || !Number.isInteger(item.number)) continue;
            const pull = !!item.issue?.issue?.pull_request_id;
            const repository = repo.owner_login + '/' + repo.name;
            items.push({id:repository+'#'+item.number,title:text(item.hl_title || item.title),
              url:'https://github.com/'+repository+'/'+(pull?'pull':'issues')+'/'+item.number,
              author:item.author_name || null,date:item.updated_at || item.created || null,
              draft:item.draft === true || item.reviewable_state === 'draft'});
          }
          return JSON.stringify({login,authenticated:!!login && (!route || route.logged_in === true),
            valid:!!route && (!route.errors || route.errors.length === 0) && items.length === route.results.length,
            resultCount:route?.result_count || 0,pageCount:route?.page_count || 0,items});
        })()
        """#
}
