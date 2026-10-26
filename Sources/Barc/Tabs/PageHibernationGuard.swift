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

    func permitsHibernation(of view: WKWebView) async -> Bool {
        guard Self.nativeActivityAllowsSleep(view), let page = pages.object(forKey: view),
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
            let script = "({safe: !!(window.__barcHibernation && window.__barcHibernation.token === \(token) && window.__barcHibernation.isSafe()), children: document.querySelectorAll('iframe, frame').length, url: location.href, x: scrollX, y: scrollY})"
            guard let inspection = await inspect(script, frame: frame, in: view) else { return false }
            if frame.info.isMainFrame, frame.kind == "barcDraftGuard" { viewport = inspection.viewport }
            childCounts[frame.kind, default: 0] += inspection.children
            frameCounts[frame.kind, default: 0] += 1
        }
        // A sandboxed or not-yet-registered iframe makes the inventory incomplete.
        guard frameCounts.allSatisfy({ $0.value == 1 + (childCounts[$0.key] ?? 0) }) else { return false }
        guard !Task.isCancelled, page.generation == generation, Self.nativeActivityAllowsSleep(view) else { return false }
        page.viewport = viewport
        return true
    }

    private struct Inspection {
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
                    guard result?["safe"] as? Bool == true, let children = result?["children"] as? Int else { reply.finish(nil); return }
                    var viewport: PageViewport?
                    if let address = result?["url"] as? String, let url = URL(string:address),
                       let x = result?["x"] as? Double, let y = result?["y"] as? Double {
                        let position = PageViewport(url:url, x:x, y:y)
                        if position.isValid { viewport = position }
                    }
                    reply.finish(Inspection(children:children, viewport:viewport))
                case .failure: reply.finish(nil)
                }
            }
        }
    }

    /// No field values cross the bridge or enter persistence. An edit stays
    /// protected until navigation, rather than guessing that a submit saved it.
    static let draftsScript = #"""
    (() => {
      const bridge = window.webkit.messageHandlers.barcDraftGuard;
      const token = globalThis.crypto && crypto.randomUUID ? crypto.randomUUID() : String(Math.random()) + Date.now();
      let edited = false;
      const report = event => bridge.postMessage({token, event});
      function markEdited() { if (!edited) { edited = true; report('change'); } }
      document.addEventListener('beforeinput', markEdited, true);
      document.addEventListener('input', markEdited, true);
      document.addEventListener('change', markEdited, true);
      function isSafe() {
        if (edited) return false;
        // Also catches autofill/property assignment without a DOM event.
        for (const el of document.querySelectorAll('input, textarea, select')) {
          if (el.type === 'file' && el.files && el.files.length) return false;
          if (el.tagName === 'SELECT') {
            const defaults = Array.from(el.options).filter(o => o.defaultSelected);
            const expected = defaults.length ? defaults : (el.multiple ? [] : Array.from(el.options).slice(0,1));
            if (Array.from(el.selectedOptions).length !== expected.length || expected.some(o => !o.selected)) return false;
          } else if (el.type === 'checkbox' || el.type === 'radio') {
            if (el.checked !== el.defaultChecked) return false;
          } else if (!['hidden','submit','button','reset','image'].includes(el.type) && el.value !== el.defaultValue) return false;
        }
        // Rich editors can update their DOM without input events. Retain them
        // conservatively rather than inferring that their content was saved.
        for (const el of document.querySelectorAll('[contenteditable]:not([contenteditable="false"]), [role="textbox"]')) {
          if (el.textContent.trim()) return false;
        }
        return true;
      }
      Object.defineProperty(window, '__barcHibernation', {value: {token, isSafe}});
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
      const peers = new Set(), tracks = new Set();
      let pending = 0, captureRequests = 0;
      const report = event => bridge.postMessage({token, event, realtime: peers.size > 0 || captureRequests > 0 || Array.from(tracks).some(t => t.readyState !== 'ended')});
      const change = delta => { pending += delta; report('change'); };
      let reliable = true;
      try {
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
              for (const track of stream.getTracks()) {
                tracks.add(track);
                track.addEventListener('ended', () => { tracks.delete(track); report('change'); }, {once:true});
              }
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
        if (Array.from(document.querySelectorAll('audio, video')).some(el => !el.paused && !el.ended)) return false;
        return reliable && pending === 0 && peers.size === 0 && tracks.size === 0;
      }
      Object.defineProperty(window, '__barcHibernation', {value: {token, isSafe}});
      report('register');
      window.addEventListener('pagehide', () => report('gone'));
      window.addEventListener('pageshow', e => { if (e.persisted) report('register'); });
    })();
    """#
}
