// Modified for Barc: conservative live-page hibernation checks, 2026-10-26.
import AppKit
import WebKit

extension Notification.Name {
    static let pageRealtimeActivityDidChange = Notification.Name("barc.pageRealtimeActivityDidChange")
}

/// Checks every registered frame in both content worlds. A missing, busy or
/// unresponsive frame never grants permission to discard its document.
@MainActor
final class PageHibernationGuard: NSObject, WKScriptMessageHandler {
    static let shared = PageHibernationGuard()
    private let controllers = NSHashTable<WKUserContentController>.weakObjects()
    private let pages = NSMapTable<WKWebView, Page>.weakToStrongObjects()

    private final class Page: NSObject {
        var frames: [String: Frame] = [:]
        var mainTokens: [String: String] = [:]
        var generation = 0
        var activityRevision = 0
        var approvedRevision: Int?
        var overflow = false
        var viewport: PageViewport?
        var realtimeFrames: Set<String> = []
        var busyWorkFrames: Set<String> = []
        var protection = "Waiting for page safety check"
        /// Which field or request the refusal is about, for the measurement log.
        var protectionDetail = ""
    }
    private struct Frame {
        let kind: String
        let info: WKFrameInfo
        let token: String
        let world: WKContentWorld
    }

    func attach(_ controller: WKUserContentController) {
        guard !controllers.contains(controller) else { return }
        controllers.add(controller)
        for (name, world, script) in [
            ("barcDraftGuard", WKContentWorld.defaultClient, Self.draftsScript),
            ("barcWorkGuard", WKContentWorld.page, Self.workScript)
        ] {
            controller.add(self, contentWorld: world, name: name)
            controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart,
                                                  forMainFrameOnly: false, in: world))
        }
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let view = message.webView, let body = message.body as? [String: Any],
              let token = body["token"] as? String, token.count < 80,
              let event = body["event"] as? String else { return }
        let page: Page
        if let existing = pages.object(forKey: view) { page = existing }
        else { page = Page(); pages.setObject(page, forKey: view) }
        let wasRealtime = page.overflow || !page.realtimeFrames.isEmpty
        defer {
            if wasRealtime != (page.overflow || !page.realtimeFrames.isEmpty) {
                NotificationCenter.default.post(name:.pageRealtimeActivityDidChange, object:view)
            }
        }
        let name = message.name
        let key = name + token
        if event == "register", message.frameInfo.isMainFrame {
            page.frames = page.frames.filter { !$0.key.hasPrefix(name) }
            page.mainTokens[name] = token
            page.realtimeFrames = page.realtimeFrames.filter { !$0.hasPrefix(name) }
            page.busyWorkFrames = page.busyWorkFrames.filter { !$0.hasPrefix(name) }
            page.overflow = false
        } else if event == "register", let frame = Self.frameID(message.frameInfo) {
            // A child frame has a new document. Its old document says "gone"
            // on pagehide, but that message can be lost (a process swap, a
            // frame torn down mid-navigation); the old entry would then fail
            // its token check against the new document on every sweep and keep
            // the tab awake for good, as GitHub's did for hours.
            for (stale, entry) in page.frames where entry.kind == name && entry.token != token && Self.frameID(entry.info) == frame {
                page.frames[stale] = nil
                page.realtimeFrames.remove(stale)
                page.busyWorkFrames.remove(stale)
            }
        }
        page.activityRevision += 1
        page.approvedRevision = nil
        // Completed background POSTs can arrive during the native round trip.
        // Keep navigation and edits as strict invalidations, but validate work
        // against its current busy state instead of requiring network silence.
        if name != "barcWorkGuard" || event != "change" { page.generation += 1 }
        page.protection = "Page changed since last safety check"
        if event == "gone" {
            page.frames[key] = nil
            page.realtimeFrames.remove(key)
            page.busyWorkFrames.remove(key)
            return
        }
        guard page.frames.count < 256 || page.frames[key] != nil else { page.overflow = true; return }
        if body["realtime"] as? Bool == true { page.realtimeFrames.insert(key) }
        else { page.realtimeFrames.remove(key) }
        if name == "barcWorkGuard" {
            if body["busy"] as? Bool == false { page.busyWorkFrames.remove(key) }
            else { page.busyWorkFrames.insert(key) }
        }
        page.frames[key] = Frame(kind: name, info: message.frameInfo, token: token,
                                world: name == "barcDraftGuard" ? .defaultClient : .page)
    }

    func hasRealtimeActivity(in view:WKWebView) -> Bool {
        guard let page = pages.object(forKey:view) else { return false }
        return page.overflow || !page.realtimeFrames.isEmpty
    }

    static func nativeActivityAllowsSleep(_ view: WKWebView) -> Bool {
        !view.isLoading && view.cameraCaptureState == .none && view.microphoneCaptureState == .none
    }

    /// Which native activity refused, rather than a generic wait.
    static func nativeActivityExplanation(_ view: WKWebView) -> String {
        view.isLoading ? "Page is still loading" : "Camera or microphone is in use"
    }

    func capturedViewport(of view: WKWebView) -> PageViewport? { pages.object(forKey:view)?.viewport }
    func sleepExplanation(for view: WKWebView) -> String {
        pages.object(forKey: view)?.protection ?? "Waiting for page safety check"
    }
    func sleepDetail(for view: WKWebView) -> String {
        pages.object(forKey: view)?.protectionDetail ?? ""
    }

    /// An earlier member of a split can change while another is inspected.
    /// Call immediately before retiring the group, without another suspension.
    func hasCurrentApproval(for view: WKWebView) -> Bool {
        guard let page = pages.object(forKey: view), let approved = page.approvedRevision else { return false }
        return approved == page.activityRevision && page.busyWorkFrames.isEmpty && !page.overflow
            && Self.nativeActivityAllowsSleep(view)
    }

    func permitsHibernation(of view: WKWebView) async -> Bool {
        guard let page = pages.object(forKey: view) else { return false }
        page.approvedRevision = nil
        page.protection = "Waiting for complete frame safety check"
        page.protectionDetail = ""
        guard Self.nativeActivityAllowsSleep(view) else { page.protection = Self.nativeActivityExplanation(view); return false }
        guard !page.overflow else { page.protection = "Too many frames to check"; return false }
        guard page.mainTokens.count == 2, page.mainTokens.allSatisfy({ page.frames[$0.key + $0.value] != nil }) else {
            page.protection = "Page safety scripts have not registered"
            return false
        }
        page.viewport = nil
        var viewport: PageViewport?
        let generation = page.generation
        let frames = Array(page.frames.values)
        var childCounts: [String: Int] = [:]
        var frameCounts: [String: Int] = [:]
        for frame in frames {
            guard !Task.isCancelled else { return false }
            let token = WebNotificationCentre.javaScriptString(frame.token)
            let script = "({stale: !(window.__barcHibernation && window.__barcHibernation.token === \(token)), safe: !!(window.__barcHibernation && window.__barcHibernation.token === \(token) && window.__barcHibernation.isSafe()), reason: window.__barcHibernation && window.__barcHibernation.reason, children: document.querySelectorAll('iframe, frame').length, url: location.href, x: scrollX, y: scrollY, detail: window.__barcHibernation && window.__barcHibernation.detail})"
            guard let inspection = await inspect(script, frame: frame, in: view) else {
                page.protection = frame.info.isMainFrame ? "Page did not answer the safety check" : "A frame did not answer the safety check (\(frame.info.securityOrigin.host))"
                return false
            }
            if inspection.gone || inspection.stale {
                // A stale entry names a document this frame no longer shows;
                // the one it shows now is checked by its own entry or, if it
                // never registered, by the frame inventory below.
                guard !frame.info.isMainFrame else {
                    if inspection.stale { page.protection = "Page changed since its safety check registered" }
                    return false
                }
                let key = frame.kind + frame.token
                page.frames[key] = nil
                page.realtimeFrames.remove(key)
                page.busyWorkFrames.remove(key)
                continue
            }
            guard inspection.safe else {
                page.protection = inspection.reason
                page.protectionDetail = inspection.detail
                return false
            }
            if frame.info.isMainFrame, frame.kind == "barcDraftGuard" { viewport = inspection.viewport }
            childCounts[frame.kind, default: 0] += inspection.children
            frameCounts[frame.kind, default: 0] += 1
        }
        // A frame Barc's scripts never reached makes the inventory incomplete:
        // most often one the content blocker stopped, which keeps an empty
        // document Barc cannot register in. Look such frames up in WebKit's
        // own frame tree and inspect them directly; anything that could hold
        // input, or any frame that cannot be inspected, still refuses.
        if !frameCounts.allSatisfy({ $0.value == 1 + (childCounts[$0.key] ?? 0) }) {
            guard await unregisteredFramesAreInert(in: view, page: page) else {
                page.protection = "An embedded frame could not be checked (\(frameCounts.map { "\($0.key) \($0.value) of \(1 + (childCounts[$0.key] ?? 0))" }.sorted().joined(separator: ", ")))"
                return false
            }
        }
        guard !Task.isCancelled, page.generation == generation else { page.protection = "Page changed during the safety check"; return false }
        guard page.busyWorkFrames.isEmpty else {
            page.protection = "Upload or form request in progress"
            page.protectionDetail = "a frame reported work after its check"
            return false
        }
        guard Self.nativeActivityAllowsSleep(view) else { page.protection = Self.nativeActivityExplanation(view); return false }
        page.viewport = viewport
        page.protection = "Ready to sleep when idle"
        page.approvedRevision = page.activityRevision
        return true
    }

    /// WebKit's identifier for a frame, the same for every report about it.
    private static func frameID(_ info: WKFrameInfo) -> UInt64? {
        guard info.responds(to: Selector(("_handle"))), let handle = info.value(forKey: "_handle") as? NSObject,
              handle.responds(to: Selector(("frameID"))) else { return nil }
        return handle.value(forKey: "frameID") as? UInt64
    }

    /// Every frame in the page, from WebKit, including frames no script reached.
    private static func frameInfos(of view: WKWebView) async -> [WKFrameInfo]? {
        let selector = Selector(("_frames:"))
        guard view.responds(to: selector) else { return nil }
        return await withCheckedContinuation { continuation in
            let reply = FrameTreeReply(continuation)
            let block: @convention(block) (AnyObject?) -> Void = { root in
                var infos: [WKFrameInfo] = []
                func walk(_ node: NSObject) {
                    guard node.responds(to: Selector(("info"))), let info = node.value(forKey: "info") as? WKFrameInfo else { return }
                    infos.append(info)
                    guard node.responds(to: Selector(("childFrames"))) else { return }
                    for child in (node.value(forKey: "childFrames") as? [NSObject]) ?? [] { walk(child) }
                }
                if let root = root as? NSObject { walk(root) }
                reply.finish(root == nil ? nil : infos)
            }
            view.perform(selector, with: block)
        }
    }

    private final class FrameTreeReply: @unchecked Sendable {
        private var continuation: CheckedContinuation<[WKFrameInfo]?, Never>?
        init(_ continuation: CheckedContinuation<[WKFrameInfo]?, Never>) { self.continuation = continuation }
        func finish(_ infos: [WKFrameInfo]?) {
            let continuation = continuation
            self.continuation = nil
            continuation?.resume(returning: infos)
        }
    }

    /// True when every frame missing from either content world holds nothing
    /// to protect: no field, editor or design-mode document, and no script of
    /// its own that could be doing work. Checked from Barc's isolated world,
    /// which runs even where the page's scripts do not.
    private func unregisteredFramesAreInert(in view: WKWebView, page: Page) async -> Bool {
        guard let tree = await Self.frameInfos(of: view) else { return false }
        var registered: [String: Set<UInt64>] = [:]
        for frame in page.frames.values {
            guard let id = Self.frameID(frame.info) else { return false }
            registered[frame.kind, default: []].insert(id)
        }
        let script = "({editable: document.designMode === 'on' || !!document.querySelector('input:not([type=hidden]), textarea, select, [contenteditable]:not([contenteditable=\"false\"]), [role=\"textbox\"]'), scripts: document.scripts.length})"
        for info in tree {
            guard let id = Self.frameID(info) else { return false }
            if registered["barcDraftGuard"]?.contains(id) == true, registered["barcWorkGuard"]?.contains(id) == true { continue }
            guard !info.isMainFrame else { return false }
            let inert: Bool = await withCheckedContinuation { continuation in
                let reply = InertReply(continuation)
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1))
                    reply.finish(false)
                }
                view.evaluateJavaScript(script, in: info, in: .defaultClient) { outcome in
                    switch outcome {
                    case .success(let value):
                        let result = value as? [String: Any]
                        reply.finish(result?["editable"] as? Bool == false && (result?["scripts"] as? Int) == 0)
                    // Left the page while we looked: nothing remains to protect.
                    case .failure(let error) where Self.isFrameGone(error): reply.finish(true)
                    case .failure: reply.finish(false)
                    }
                }
            }
            guard inert else { return false }
        }
        return true
    }

    private final class InertReply: @unchecked Sendable {
        private var continuation: CheckedContinuation<Bool, Never>?
        init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }
        func finish(_ result: Bool) {
            let continuation = continuation
            self.continuation = nil
            continuation?.resume(returning: result)
        }
    }

    private static func exceptionMessage(_ error: Error) -> String? {
        let error = error as NSError
        guard error.domain == WKErrorDomain, error.code == WKError.javaScriptExceptionOccurred.rawValue else { return nil }
        return error.userInfo["WKJavaScriptExceptionMessage"] as? String
    }

    /// WebKit's refusal to run any script in a document whose sandbox forbids it.
    static func isScriptingDisabled(_ error: Error) -> Bool {
        exceptionMessage(error) == "Cannot execute JavaScript in this document"
    }

    /// WebKit's answer for a frame that has left the page.
    static func isFrameGone(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == WKErrorDomain && error.code == WKError.javaScriptInvalidFrameTarget.rawValue
    }

    private struct Inspection {
        let safe: Bool
        let reason: String
        var detail = ""
        let children: Int
        let viewport: PageViewport?
        /// The frame is no longer in the page.
        var gone = false
        /// The frame shows a different document from the one this entry
        /// registered for.
        var stale = false
    }
    private final class Reply {
        var continuation: CheckedContinuation<Inspection?, Never>?
        var timeout: Task<Void, Never>?
        func finish(_ inspection: Inspection?) {
            let continuation = continuation
            self.continuation = nil
            timeout?.cancel()
            timeout = nil
            continuation?.resume(returning: inspection)
        }
    }

    private func inspect(_ script: String, frame: Frame, in view: WKWebView) async -> Inspection? {
        await withCheckedContinuation { continuation in
            let reply = Reply()
            reply.continuation = continuation
            reply.timeout = Task { @MainActor in
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                reply.finish(nil)
            }
            view.evaluateJavaScript(script, in: frame.info, in: frame.world) { result in
                switch result {
                case .success(let value):
                    let result = value as? [String: Any]
                    guard let safe = result?["safe"] as? Bool, let children = result?["children"] as? Int else { reply.finish(nil); return }
                    var viewport: PageViewport?
                    if let address = result?["url"] as? String, let url = URL(string:address),
                       let x = result?["x"] as? Double, let y = result?["y"] as? Double {
                        let position = PageViewport(url:url, x:x, y:y)
                        if position.isValid { viewport = position }
                    }
                    let code = result?["reason"] as? String
                    let reason = switch code {
                    case "draft": "Unfinished form or draft"
                    case "call": "Call or screen sharing in progress"
                    case "upload": "Upload or form request in progress"
                    case "media": "Media is playing"
                    case "unknown": "Page safety check could not hook into this page"
                    default: "Waiting for page safety check"
                    }
                    reply.finish(Inspection(safe:safe, reason:reason, detail:(result?["detail"] as? String).map { String($0.prefix(160)) } ?? "",
                                            children:children, viewport:viewport, stale: result?["stale"] as? Bool == true))
                case .failure(let error):
                    // Page JavaScript is switched off in this document: a
                    // sandboxed frame without allow-scripts, like the blank one
                    // YouTube embeds. Nothing the page runs there can start an
                    // upload, a call or media, so the page-world check has
                    // nothing to find. Drafts are still checked from Barc's own
                    // world, which does run there, and playing media natively.
                    // Any other failure still refuses.
                    if Self.isFrameGone(error) {
                        // Removed without a pagehide Barc could hear, as with a
                        // script-free ad frame. Its document, and any draft in
                        // it, no longer exists.
                        reply.finish(Inspection(safe: true, reason: "", children: 0, viewport: nil, gone: true))
                    } else if frame.kind == "barcWorkGuard", Self.isScriptingDisabled(error) {
                        reply.finish(Inspection(safe: true, reason: "", children: 0, viewport: nil))
                    } else {
                        reply.finish(nil)
                    }
                }
            }
        }
    }

    /// No field values cross the bridge or enter persistence. Protect current
    /// edits, including detached editors, but let untouched application data and
    /// explicitly cleared composers sleep. A submit event does not prove a save.
    static let draftsScript = #"""
    (() => {
      const bridge = window.webkit.messageHandlers.barcDraftGuard;
      const token = globalThis.crypto && crypto.randomUUID ? crypto.randomUUID() : String(Math.random()) + Date.now();
      const edited = new Set(), defaults = new WeakMap();
      let unknownEdit = false;
      const report = event => bridge.postMessage({token, event});
      // Read the real target inside open shadow roots: at the document a
      // component's own text field is retargeted to its host element, which
      // is not an editor and would otherwise make every keystroke "unknown".
      const editorFor = event => {
        const path = typeof event.composedPath === 'function' ? event.composedPath() : [];
        const origin = path.length && path[0] instanceof Element ? path[0] : event.target;
        return origin instanceof Element
          ? origin.closest('input, textarea, select, [contenteditable]:not([contenteditable="false"]), [role="textbox"]') : null;
      };
      const rich = el => !el.matches('input, textarea, select');
      // A query typed into a search or filter box is not unsaved work. Single-
      // page apps keep it in the box indefinitely (a Gmail search, a YouTube
      // query, GitHub's "Go to file" and "Find a branch"), which would
      // otherwise keep the whole tab awake for days.
      const searchWords = /search|query|filter|\bfind\b|\bgo to\b|\bjump to\b/i;
      const isSearchField = el => el.tagName === 'INPUT'
        && (el.type === 'search' || el.getAttribute('role') === 'searchbox'
          || !!el.closest('[role="search"], search')
          || el.name === 'q' || el.id === 'q'
          || [el.name, el.id, el.getAttribute('aria-label'), el.getAttribute('placeholder')]
               .some(value => !!value && searchWords.test(value)));
      const hasContent = el => !!(el.textContent.trim() || el.querySelector('img, video, audio, object, embed, canvas, svg, input[type="file"]'));
      function initialState(el, beforeEdit = false) {
        // An input-only rich-editor event has an unknown original state.
        // Keep even an empty deletion protected without a pre-edit observation.
        if (rich(el)) return beforeEdit && !hasContent(el);
        if (el.tagName === 'SELECT') {
          const selected = Array.from(el.options, (o, i) => (beforeEdit ? o.selected : o.defaultSelected) ? i : -1).filter(i => i >= 0);
          return selected.length || el.multiple ? selected : (el.options.length ? [0] : []);
        }
        if (['checkbox','radio'].includes(el.type)) return beforeEdit ? el.checked : el.defaultChecked;
        return beforeEdit ? el.value : el.defaultValue;
      }
      function rememberBeforeEdit(event) {
        const editor = editorFor(event);
        // A framework can hydrate a field after focus. Refresh its baseline
        // until editing starts, then preserve that original state.
        if (editor && !edited.has(editor)) defaults.set(editor, initialState(editor, true));
      }
      function markEdited(event) {
        const editor = editorFor(event);
        // Application-level custom events are not evidence of text entry.
        // Native editing in an unrecognised control must still fail closed.
        if (!editor && !event.isTrusted) return;
        if (editor && isSearchField(editor)) return;
        // Saved read-only values can emit framework input/change events.
        // A field that already contains an edit stays protected if a save
        // temporarily locks it; becoming read-only is not proof of a save.
        if (editor && !edited.has(editor) && editor.matches('input[readonly], textarea[readonly], [aria-readonly="true"]')) return;
        if (!editor || (edited.size >= 256 && !edited.has(editor))) unknownEdit = true;
        else {
          // Keep the original defaults even if a framework changes them later.
          if (!defaults.has(editor)) defaults.set(editor, initialState(editor));
          edited.add(editor);
        }
        report('change');
      }
      // In a sandboxed document without allow-scripts no listener runs, not
      // even Barc's, so typing there is never observed. Find out once, and
      // in that case compare the fields themselves with their markup at check
      // time: with page scripts off, only the person (or a parent page)
      // changes them. Rich editors there count as drafts, to fail safe.
      let listenersRun = false;
      document.addEventListener('barc-draft-probe', () => { listenersRun = true; }, {once: true});
      document.dispatchEvent(new Event('barc-draft-probe'));
      function unobservedDraft() {
        if (document.designMode === 'on') return true;
        for (const el of document.querySelectorAll('input, textarea, select')) {
          if (el.tagName === 'SELECT') {
            if (Array.from(el.options).some(option => option.selected !== option.defaultSelected)) return true;
          } else if (['checkbox', 'radio'].includes(el.type)) {
            if (el.checked !== el.defaultChecked) return true;
          } else if (el.type === 'file') {
            if (el.files && el.files.length) return true;
          } else if (!['hidden', 'submit', 'button', 'reset', 'image'].includes(el.type) && !isSearchField(el)) {
            if (el.value !== el.defaultValue) return true;
          }
        }
        return Array.from(document.querySelectorAll('[contenteditable]:not([contenteditable="false"]), [role="textbox"]')).some(hasContent);
      }
      document.addEventListener('focusin', rememberBeforeEdit, true);
      document.addEventListener('pointerdown', rememberBeforeEdit, true);
      document.addEventListener('keydown', rememberBeforeEdit, true);
      document.addEventListener('beforeinput', event => { rememberBeforeEdit(event); markEdited(event); }, true);
      document.addEventListener('input', markEdited, true);
      document.addEventListener('change', markEdited, true);
      function hasDraft(el) {
        const initial = defaults.has(el) ? defaults.get(el) : initialState(el);
        if (rich(el)) {
          // Emptying an editor which already contained text can itself be an
          // unsaved deletion. Only an initially empty composer can clear here.
          return !initial || hasContent(el);
        }
        if (el.type === 'file') return !!(el.files && el.files.length);
        if (el.tagName === 'SELECT') {
          const selected = Array.from(el.options, (o, i) => o.selected ? i : -1).filter(i => i >= 0);
          return selected.length !== initial.length || selected.some((value, i) => value !== initial[i]);
        }
        if (['checkbox','radio'].includes(el.type)) return el.checked !== initial;
        return !['hidden','submit','button','reset','image'].includes(el.type) && el.value !== initial;
      }
      // An editor the page has taken out of the document still protects it for
      // a while: a framework can move a field and put it back, and a submit
      // event is no proof of a save. After that it is gone from the person's
      // view for good. Apps unmount the edit box of a sent message, a renamed
      // title or a closed dialog with the text still in it, and holding every
      // such page awake for days cost gigabytes. Read lazily for tests.
      const removedWindow = () => typeof globalThis.__barcTestRemovedDraftMs === 'number' ? globalThis.__barcTestRemovedDraftMs : 120000;
      const removedSince = new WeakMap();
      function abandoned(el) {
        if (el.isConnected) { removedSince.delete(el); return false; }
        if (!removedSince.has(el)) removedSince.set(el, performance.now());
        return performance.now() - removedSince.get(el) >= removedWindow();
      }
      // Which field holds the draft, for Barc's measurement log. Labels and
      // names only: field values never leave the page.
      let detail = '';
      const describe = el => {
        const label = el.getAttribute('aria-label') || el.getAttribute('placeholder') || el.getAttribute('name') || el.id || '';
        return el.tagName.toLowerCase() + (el.tagName === 'INPUT' ? '[' + el.type + ']' : '')
          + (label ? ' "' + String(label).slice(0, 40) + '"' : '') + (el.isConnected ? '' : ' (removed)');
      };
      function isSafe() {
        detail = '';
        if (unknownEdit) { detail = 'edit in a control Barc could not identify'; return false; }
        if (document.designMode === 'on') { detail = 'design mode'; return false; }
        if (!listenersRun && unobservedDraft()) { detail = 'field in a document without scripts'; return false; }
        for (const el of edited) {
          if (hasDraft(el) && !abandoned(el)) { detail = describe(el); return false; }
          edited.delete(el);
        }
        // Saved task titles and descriptions are not drafts just because they
        // contain text or differ from HTML defaults. File selections remain
        // protected even when no editing event was delivered.
        for (const el of document.querySelectorAll('input[type="file"]')) {
          if (el.files && el.files.length) { detail = describe(el); return false; }
        }
        return true;
      }
      Object.defineProperty(window, '__barcHibernation', {value: {token, isSafe, get reason() { return 'draft'; }, get detail() { return detail; }}});
      report('register');
      window.addEventListener('pagehide', () => report('gone'));
      window.addEventListener('pageshow', e => { if (e.persisted) report('register'); });
    })();
    """#

    /// Tracks calls, screen capture and requests carrying uploads in the page
    /// world. Native capture state is checked as well, including muted capture.
    static let workScript = #"""
    (() => {
      const bridge = window.webkit.messageHandlers.barcWorkGuard;
      const token = globalThis.crypto && crypto.randomUUID ? crypto.randomUUID() : String(Math.random()) + Date.now();
      const peers = new Set(), tracks = new Set(), streams = new WeakSet();
      let captureRequests = 0;
      // A peer is a call while it is being set up and once it has someone on
      // the other end. Bot-detection and fingerprinting scripts make peers only
      // to gather local network candidates and never connect them (signed-in
      // ChatGPT keeps one open); after the setup window those no longer keep a
      // tab awake. Read lazily so a test can shorten the window.
      const born = new WeakMap();
      const setupWindow = () => typeof globalThis.__barcTestPeerSetupMs === 'number' ? globalThis.__barcTestPeerSetupMs : 60000;
      const liveCall = peer => !!peer.remoteDescription || ['connecting', 'connected'].includes(peer.connectionState)
        || performance.now() - (born.get(peer) ?? 0) < setupWindow();
      const livePeers = () => Array.from(peers).filter(liveCall).length;
      const realtime = () => livePeers() > 0 || captureRequests > 0 || Array.from(tracks).some(t => t.readyState !== 'ended');
      // Requests that send something. One carrying a file or a lot of data is
      // an upload for as long as it takes. Anything else still open after a
      // minute is a long poll or a stream, not a form waiting to be saved:
      // Gmail keeps one open all day, which used to keep it awake for days.
      const requests = new Map();
      const requestWindow = () => typeof globalThis.__barcTestRequestWindowMs === 'number' ? globalThis.__barcTestRequestWindowMs : 60000;
      const bodySize = body => {
        try {
          if (body == null) return 0;
          if (typeof body === 'string') return body.length;
          if (body instanceof Blob) return body.size;
          if (body instanceof ArrayBuffer || ArrayBuffer.isView(body)) return body.byteLength;
          if (typeof ReadableStream === 'function' && body instanceof ReadableStream) return Infinity;
          if (body instanceof FormData) {
            let size = 0;
            for (const value of body.values()) size += value instanceof Blob ? value.size : String(value).length;
            return size;
          }
          return String(body).length;
        } catch (error) { return Infinity; }
      };
      const target = (method, url) => {
        try { const address = new URL(String(url), location.href); return method + ' ' + address.host + address.pathname.slice(0, 60); }
        catch (error) { return method; }
      };
      const openRequests = () => {
        const now = performance.now();
        return Array.from(requests.values()).filter(r => r.upload || now - r.start < requestWindow());
      };
      let reportedRealtime = false, reportedBusy = false, reason = '', detail = '';
      const busy = () => openRequests().length > 0 || realtime() || !reliable;
      const report = event => {
        reportedRealtime = realtime();
        reportedBusy = busy();
        bridge.postMessage({token, event, realtime: reportedRealtime, busy: reportedBusy});
      };
      let ageCheck = 0;
      const begin = (key, body, label) => {
        // Forget long polls that never finished rather than let them pile up.
        if (requests.size >= 256) {
          for (const [other, request] of requests) {
            if (!request.upload && performance.now() - request.start >= requestWindow()) requests.delete(other);
          }
        }
        requests.set(key, {start: performance.now(), upload: bodySize(body) >= 65536, label});
        report('change');
        // Tell Barc when the request stops counting.
        clearTimeout(ageCheck);
        ageCheck = setTimeout(() => report('change'), requestWindow() + 1);
      };
      const end = key => { if (requests.delete(key)) report('change'); };
      let reliable = true;
      function trackCapture(track) {
        if (tracks.has(track)) return;
        tracks.add(track);
        const ended = () => { tracks.delete(track); report('change'); };
        track.addEventListener('ended', ended, {once:true});
        // Calling MediaStreamTrack.stop() changes readyState without
        // dispatching "ended". Notify the native protection state too.
        const stop = track.stop;
        if (typeof stop === 'function') {
          try {
            track.stop = function() {
              const result = stop.apply(this, arguments);
              if (track.readyState === 'ended') ended();
              return result;
            };
          } catch (error) { reliable = false; }
        }
      }
      function trackStream(stream) {
        streams.add(stream);
        for (const track of stream.getTracks()) trackCapture(track);
      }
      try {
        // Track both track.clone() and stream.clone(), including explicit
        // prototype calls. A stopped original does not end its live clones.
        for (const [type, tracked, register] of [
          [window.MediaStreamTrack, tracks, trackCapture],
          [window.MediaStream, streams, trackStream]
        ]) {
          if (!type || !type.prototype.clone) continue;
          const clone = type.prototype.clone;
          type.prototype.clone = function() {
            const copy = clone.apply(this, arguments);
            const captured = tracked.has(this) || (type === window.MediaStream && this.getTracks().some(track => tracks.has(track)));
            if (captured) { register(copy); report('change'); }
            return copy;
          };
        }
        if (window.RTCPeerConnection) {
          const Original = window.RTCPeerConnection;
          window.RTCPeerConnection = new Proxy(Original, {construct(target, args, newTarget) {
            const peer = Reflect.construct(target, args, newTarget);
            peers.add(peer); born.set(peer, performance.now()); report('change');
            // Tell Barc when an unanswered peer stops counting as a call.
            setTimeout(() => report('change'), setupWindow() + 1);
            peer.addEventListener('signalingstatechange', () => report('change'));
            peer.addEventListener('connectionstatechange', () => {
              if (peer.connectionState === 'closed') peers.delete(peer);
              report('change');
            });
            const close = peer.close;
            peer.close = function() { const result = close.apply(this, arguments); peers.delete(peer); report('change'); return result; };
            return peer;
          }});
          if (window.webkitRTCPeerConnection === Original) window.webkitRTCPeerConnection = window.RTCPeerConnection;
        }
        const devices = navigator.mediaDevices;
        if (devices) for (const name of ['getUserMedia', 'getDisplayMedia']) {
          if (!devices[name]) continue;
          const original = devices[name];
          devices[name] = function() {
            captureRequests++;
            report('change');
            try { return original.apply(this, arguments).then(stream => {
              trackStream(stream);
              return stream;
            }).finally(() => { captureRequests--; report('change'); }); }
            catch (error) { captureRequests--; report('change'); throw error; }
          };
        }
        const fetch = window.fetch;
        window.fetch = function(input, init) {
          const method = String(init && init.method || input && input.method || 'GET').toUpperCase();
          if (['GET','HEAD'].includes(method)) return fetch.apply(this, arguments);
          const key = {};
          begin(key, init && init.body, target(method, input && input.url || input));
          try { return fetch.apply(this, arguments).finally(() => end(key)); }
          catch (error) { end(key); throw error; }
        };
        const open = XMLHttpRequest.prototype.open, send = XMLHttpRequest.prototype.send;
        const methods = new WeakMap(), addresses = new WeakMap();
        XMLHttpRequest.prototype.open = function(method, url) {
          // Opening a request again cancels the one in flight without any
          // event, so it would otherwise count as in progress forever.
          end(this);
          methods.set(this, String(method).toUpperCase());
          addresses.set(this, url);
          return open.apply(this, arguments);
        };
        XMLHttpRequest.prototype.send = function(body) {
          const method = methods.get(this);
          if (body == null && ['GET','HEAD'].includes(method)) return send.apply(this, arguments);
          const request = this;
          begin(request, body, target(method || 'POST', addresses.get(request)));
          request.addEventListener('loadend', () => end(request), {once:true});
          try { return send.apply(this, arguments); } catch (error) { end(request); throw error; }
        };
      } catch (error) { reliable = false; }
      function isSafe() {
        for (const peer of peers) if (peer.signalingState === 'closed') peers.delete(peer);
        for (const track of tracks) if (track.readyState === 'ended') tracks.delete(track);
        // Recheck live state even when a site used a prototype method instead
        // of our instance wrapper, or a request aged out while timers were
        // throttled. Cached bridge state is not a sleep veto.
        if (reportedRealtime !== realtime() || reportedBusy !== busy()) report('change');
        detail = '';
        if (!reliable) { reason = 'unknown'; return false; }
        if (captureRequests > 0 || livePeers() > 0 || tracks.size > 0) { reason = 'call'; return false; }
        const inFlight = openRequests();
        if (inFlight.length) {
          const oldest = inFlight[0];
          reason = 'upload';
          detail = inFlight.length + (inFlight.length === 1 ? ' request, ' : ' requests, oldest ')
            + oldest.label + ' open ' + Math.round((performance.now() - oldest.start) / 1000) + ' s' + (oldest.upload ? ', large body' : '');
          return false;
        }
        // Audible media only. A muted autoplay clip (a news homepage, a feed)
        // is decoration, not something the person is listening to.
        if (Array.from(document.querySelectorAll('audio, video')).some(el => !el.paused && !el.ended && !el.muted && el.volume > 0)) { reason = 'media'; return false; }
        reason = '';
        return true;
      }
      Object.defineProperty(window, '__barcHibernation', {value: {token, isSafe, get reason() { return reason; }, get detail() { return detail; }}});
      report('register');
      window.addEventListener('pagehide', () => report('gone'));
      window.addEventListener('pageshow', e => { if (e.persisted) report('register'); });
    })();
    """#
}
