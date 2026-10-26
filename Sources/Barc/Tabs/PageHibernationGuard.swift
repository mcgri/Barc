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
        var overflow = false
        var viewport: PageViewport?
        var realtimeFrames: Set<String> = []
        var protection = "Waiting for page safety check"
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
            page.overflow = false
        }
        page.generation += 1
        page.protection = "Page changed since last safety check"
        if event == "gone" { page.frames[key] = nil; page.realtimeFrames.remove(key); return }
        guard page.frames.count < 256 || page.frames[key] != nil else { page.overflow = true; return }
        if body["realtime"] as? Bool == true { page.realtimeFrames.insert(key) }
        else { page.realtimeFrames.remove(key) }
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

    func capturedViewport(of view: WKWebView) -> PageViewport? { pages.object(forKey:view)?.viewport }
    func sleepExplanation(for view: WKWebView) -> String {
        pages.object(forKey: view)?.protection ?? "Waiting for page safety check"
    }

    func permitsHibernation(of view: WKWebView) async -> Bool {
        guard let page = pages.object(forKey: view) else { return false }
        page.protection = "Waiting for complete frame safety check"
        guard Self.nativeActivityAllowsSleep(view),
              page.mainTokens.count == 2, page.mainTokens.allSatisfy({ page.frames[$0.key + $0.value] != nil }), !page.overflow else { return false }
        page.viewport = nil
        var viewport: PageViewport?
        let generation = page.generation
        let frames = Array(page.frames.values)
        var childCounts: [String: Int] = [:]
        var frameCounts: [String: Int] = [:]
        for frame in frames {
            guard !Task.isCancelled else { return false }
            let token = WebNotificationCentre.javaScriptString(frame.token)
            let script = "({safe: !!(window.__barcHibernation && window.__barcHibernation.token === \(token) && window.__barcHibernation.isSafe()), reason: window.__barcHibernation && window.__barcHibernation.reason, children: document.querySelectorAll('iframe, frame').length, url: location.href, x: scrollX, y: scrollY})"
            guard let inspection = await inspect(script, frame: frame, in: view) else { return false }
            guard inspection.safe else {
                page.protection = inspection.reason
                return false
            }
            if frame.info.isMainFrame, frame.kind == "barcDraftGuard" { viewport = inspection.viewport }
            childCounts[frame.kind, default: 0] += inspection.children
            frameCounts[frame.kind, default: 0] += 1
        }
        // A sandboxed or not-yet-registered iframe makes the inventory incomplete.
        guard frameCounts.allSatisfy({ $0.value == 1 + (childCounts[$0.key] ?? 0) }) else { return false }
        guard !Task.isCancelled, page.generation == generation, Self.nativeActivityAllowsSleep(view) else { return false }
        page.viewport = viewport
        page.protection = "Ready to sleep when idle"
        return true
    }

    private struct Inspection {
        let safe: Bool
        let reason: String
        let children: Int
        let viewport: PageViewport?
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
                    default: "Waiting for page safety check"
                    }
                    reply.finish(Inspection(safe:safe, reason:reason, children:children, viewport:viewport))
                case .failure: reply.finish(nil)
                }
            }
        }
    }

    /// No field values cross the bridge or enter persistence. Protect current
    /// drafts, including detached editors, but let explicitly cleared editors
    /// sleep. A submit event alone is never evidence that work was saved.
    static let draftsScript = #"""
    (() => {
      const bridge = window.webkit.messageHandlers.barcDraftGuard;
      const token = globalThis.crypto && crypto.randomUUID ? crypto.randomUUID() : String(Math.random()) + Date.now();
      const edited = new Set(), defaults = new WeakMap();
      let unknownEdit = false;
      const report = event => bridge.postMessage({token, event});
      const rich = el => !el.matches('input, textarea, select');
      const hasContent = el => !!(el.textContent.trim() || el.querySelector('img, video, audio, object, embed, canvas, svg, input[type="file"]'));
      function initialState(el) {
        if (rich(el)) return !hasContent(el);
        if (el.tagName === 'SELECT') {
          const selected = Array.from(el.options, (o, i) => o.defaultSelected ? i : -1).filter(i => i >= 0);
          return selected.length || el.multiple ? selected : (el.options.length ? [0] : []);
        }
        return ['checkbox','radio'].includes(el.type) ? el.defaultChecked : el.defaultValue;
      }
      function markEdited(event) {
        const target = event.target instanceof Element ? event.target : null;
        const editor = target && target.closest('input, textarea, select, [contenteditable]:not([contenteditable="false"]), [role="textbox"]');
        if (!editor || edited.size >= 256) unknownEdit = true;
        else {
          // Keep the original defaults even if a framework changes them later.
          if (!defaults.has(editor)) defaults.set(editor, initialState(editor));
          edited.add(editor);
        }
        report('change');
      }
      document.addEventListener('beforeinput', markEdited, true);
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
      function isSafe() {
        if (unknownEdit || document.designMode === 'on') return false;
        for (const el of edited) {
          // A removed editor can still hold unsaved work. Do not interpret
          // removal or a submit event as proof that a message was sent.
          if (hasDraft(el)) return false;
          edited.delete(el);
        }
        // Also catches autofill and rich-editor changes without input events.
        for (const el of document.querySelectorAll('input, textarea, select, [contenteditable]:not([contenteditable="false"]), [role="textbox"]')) {
          if (hasDraft(el)) return false;
        }
        return true;
      }
      Object.defineProperty(window, '__barcHibernation', {value: {token, isSafe, get reason() { return 'draft'; }}});
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
      let pending = 0, captureRequests = 0;
      const realtime = () => peers.size > 0 || captureRequests > 0 || Array.from(tracks).some(t => t.readyState !== 'ended');
      let reportedRealtime = false, reason = '';
      const report = event => {
        reportedRealtime = realtime();
        bridge.postMessage({token, event, realtime: reportedRealtime});
      };
      const change = delta => { pending += delta; report('change'); };
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
            peers.add(peer); report('change');
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
            change(1);
            try { return original.apply(this, arguments).then(stream => {
              trackStream(stream);
              return stream;
            }).finally(() => { captureRequests--; change(-1); }); }
            catch (error) { captureRequests--; change(-1); throw error; }
          };
        }
        const fetch = window.fetch;
        window.fetch = function(input, init) {
          const method = String(init && init.method || input && input.method || 'GET').toUpperCase();
          const uploading = !['GET','HEAD'].includes(method);
          if (!uploading) return fetch.apply(this, arguments);
          change(1);
          try { return fetch.apply(this, arguments).finally(() => change(-1)); }
          catch (error) { change(-1); throw error; }
        };
        const open = XMLHttpRequest.prototype.open, send = XMLHttpRequest.prototype.send;
        const methods = new WeakMap();
        XMLHttpRequest.prototype.open = function(method) { methods.set(this, String(method).toUpperCase()); return open.apply(this, arguments); };
        XMLHttpRequest.prototype.send = function(body) {
          if (body == null && ['GET','HEAD'].includes(methods.get(this))) return send.apply(this, arguments);
          change(1);
          let done = false;
          const finish = () => { if (!done) { done = true; change(-1); } };
          this.addEventListener('loadend', finish, {once:true});
          try { return send.apply(this, arguments); } catch (error) { finish(); throw error; }
        };
      } catch (error) { reliable = false; }
      function isSafe() {
        for (const peer of peers) if (peer.signalingState === 'closed') peers.delete(peer);
        for (const track of tracks) if (track.readyState === 'ended') tracks.delete(track);
        // Recheck live state even when a site used a prototype method instead
        // of our instance wrapper. Cached bridge state is not a sleep veto.
        if (reportedRealtime !== realtime()) report('change');
        if (!reliable) { reason = 'unknown'; return false; }
        if (captureRequests > 0 || peers.size > 0 || tracks.size > 0) { reason = 'call'; return false; }
        if (pending !== 0) { reason = 'upload'; return false; }
        if (Array.from(document.querySelectorAll('audio, video')).some(el => !el.paused && !el.ended)) { reason = 'media'; return false; }
        reason = '';
        return true;
      }
      Object.defineProperty(window, '__barcHibernation', {value: {token, isSafe, get reason() { return reason; }}});
      report('register');
      window.addEventListener('pagehide', () => report('gone'));
      window.addEventListener('pageshow', e => { if (e.persisted) report('register'); });
    })();
    """#
}
