import Foundation
import WebKit

/// Serializable per-tab runtime state offloaded to disk (LZ4-compressed via
/// `RustCoreBridge`) right before a tab sleeps or is killed, then rehydrated
/// when the tab wakes up:
/// - `window.sessionStorage` (injected at `.atDocumentStart` before SPA boot)
/// - top-level + nested scrollable container offsets (ClickUp, Gmail, Linear, GitHub)
/// - non-sensitive form inputs, textareas, selects, checkboxes, and contenteditable drafts
///   (passwords, hidden fields, files, and credit-card/OTP fields are never captured)
struct TabRehydrationSnapshot: Codable, Equatable, Sendable {
    struct ScrollEntry: Codable, Equatable, Sendable {
        let selector: String
        let x: Double
        let y: Double
    }

    struct FormEntry: Codable, Equatable, Sendable {
        let selector: String
        let kind: String // "text" | "checkbox" | "select" | "contenteditable"
        let value: String?
        let checked: Bool?
    }

    let url: String
    let origin: String
    let windowX: Double
    let windowY: Double
    let sessionStorage: [String: String]
    let scrolls: [ScrollEntry]
    let forms: [FormEntry]
    let capturedAt: Date
}

/// Persists `TabRehydrationSnapshot` blobs out-of-line on disk, compressed
/// with Rust `lz4_flex` (or Apple LZFSE fallback), so sleeping tabs hold 0 bytes
/// of rehydration data in Swift RAM.
final class TabRehydrationStore: @unchecked Sendable {
    static let shared = TabRehydrationStore()

    /// Cap uncompressed snapshot payload to 2 MB so giant base64 sessionStorage
    /// entries cannot bloat disk or slow wake-up.
    static let maxUncompressedBytes = 2 * 1024 * 1024

    private let directory: URL?
    private let queue = DispatchQueue(label: "barc.tab-rehydration-state", qos: .utility)

    init(directory: URL? = TabRehydrationStore.defaultDirectory) {
        self.directory = directory
    }

    private static var defaultDirectory: URL? {
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        return AppPaths.supportDirectory.appending(path: "TabStates", directoryHint: .isDirectory)
    }

    private func fileURL(forKey key: String) -> URL? {
        guard let directory, !key.isEmpty, !key.contains("/"), !key.contains("..") else { return nil }
        return directory.appending(path: "\(key).pagestate")
    }

    @discardableResult
    func store(_ snapshot: TabRehydrationSnapshot, forKey key: String) -> Bool {
        guard let data = try? JSONEncoder().encode(snapshot),
              !data.isEmpty,
              data.count <= Self.maxUncompressedBytes,
              let url = fileURL(forKey: key) else {
            return false
        }
        let path = url.path
        queue.async {
            let parent = url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(
                at: parent,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            if RustCoreBridge.writeCompressedState(data, to: path) {
                return
            }
            if let compressed = try? (data as NSData).compressed(using: .lzfse) as Data {
                var wrapped = Data([0x42, 0x4C, 0x5A, 0x46]) // "BLZF"
                wrapped.append(compressed)
                try? wrapped.write(to: url, options: [.atomic])
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            }
        }
        return true
    }

    func load(forKey key: String) -> TabRehydrationSnapshot? {
        guard let url = fileURL(forKey: key) else { return nil }
        return queue.sync {
            let path = url.path
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            let rawData: Data?
            if let raw = try? Data(contentsOf: url),
               raw.count >= 4,
               raw[0] == 0x42, raw[1] == 0x4C, raw[2] == 0x5A, raw[3] == 0x46 {
                rawData = try? (raw.dropFirst(4) as NSData).decompressed(using: .lzfse) as Data
            } else {
                rawData = RustCoreBridge.readCompressedState(from: path)
            }
            guard let rawData else { return nil }
            return try? JSONDecoder().decode(TabRehydrationSnapshot.self, from: rawData)
        }
    }

    func remove(forKey key: String) {
        guard let url = fileURL(forKey: key) else { return }
        queue.async {
            try? FileManager.default.removeItem(at: url)
        }
    }

    func prune(keeping validKeys: Set<String>) {
        guard let directory else { return }
        queue.async {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
            for name in names where name.hasSuffix(".pagestate") {
                let key = String(name.dropLast(".pagestate".count))
                if !validKeys.contains(key) {
                    try? FileManager.default.removeItem(at: directory.appending(path: name))
                }
            }
        }
    }

    // MARK: - Capture & Rehydrate JS

    /// Captures live `sessionStorage`, nested scroll offsets, and non-sensitive
    /// form drafts from `webView` for offloading to disk.
    @MainActor
    static func capture(from webView: WKWebView) async -> TabRehydrationSnapshot? {
        guard let url = webView.url,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }
        guard let jsonString = try? await webView.evaluateJavaScript(captureScript, in: nil, contentWorld: .page) as? String,
              let data = jsonString.data(using: .utf8),
              let raw = try? JSONDecoder().decode(RawCapture.self, from: data) else {
            return nil
        }
        return TabRehydrationSnapshot(
            url: raw.url,
            origin: raw.origin,
            windowX: raw.windowX.isFinite ? raw.windowX : 0,
            windowY: raw.windowY.isFinite ? raw.windowY : 0,
            sessionStorage: raw.sessionStorage,
            scrolls: raw.scrolls,
            forms: raw.forms,
            capturedAt: Date()
        )
    }

    /// Marker prefix so one-shot rehydration user scripts can be cleanly removed
    /// once a tab navigates away or finishes rehydrating.
    static let scriptPrefix = "/*barc-rehydrate-v1*/"

    /// Builds a one-shot `.atDocumentStart` script that restores `sessionStorage`
    /// synchronously before page scripts execute, scoped strictly to `snapshot.origin`.
    @MainActor
    static func documentStartScript(for snapshot: TabRehydrationSnapshot) -> WKUserScript? {
        guard !snapshot.sessionStorage.isEmpty,
              let payloadData = try? JSONEncoder().encode(snapshot.sessionStorage),
              let payloadJSON = String(data: payloadData, encoding: .utf8) else {
            return nil
        }
        let originJS = WebNotificationCentre.javaScriptString(snapshot.origin)
        let source = """
        \(scriptPrefix)
        (() => {
          try {
            if (window.__barcRehydratedSession) return;
            if (location.origin !== \(originJS)) return;
            window.__barcRehydratedSession = true;
            const entries = \(payloadJSON);
            for (const [k, v] of Object.entries(entries)) {
              try {
                if (window.sessionStorage.getItem(k) === null) {
                  window.sessionStorage.setItem(k, v);
                }
              } catch (e) {}
            }
          } catch (e) {}
        })();
        """
        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true)
    }

    /// Re-applies nested scroll offsets and non-sensitive form drafts after `didFinish`,
    /// retrying briefly as async SPA views (ClickUp, Linear, Gmail) mount, and
    /// cancelling immediately on any user wheel/touch/pointer/keyboard input.
    @MainActor
    static func restoreDOMState(_ snapshot: TabRehydrationSnapshot, in webView: WKWebView) {
        guard !snapshot.scrolls.isEmpty || !snapshot.forms.isEmpty || snapshot.windowX != 0 || snapshot.windowY != 0 else {
            return
        }
        struct DOMPayload: Encodable {
            let url: String
            let windowX: Double
            let windowY: Double
            let scrolls: [TabRehydrationSnapshot.ScrollEntry]
            let forms: [TabRehydrationSnapshot.FormEntry]
        }
        let payload = DOMPayload(
            url: snapshot.url,
            windowX: snapshot.windowX,
            windowY: snapshot.windowY,
            scrolls: snapshot.scrolls,
            forms: snapshot.forms
        )
        guard let data = try? JSONEncoder().encode(payload),
              let json = String(data: data, encoding: .utf8) else {
            return
        }
        let script = """
        (() => {
          const snap = \(json);
          if (location.href !== snap.url) return;
          let cancelled = false;
          const inputs = ['wheel', 'touchstart', 'pointerdown', 'keydown'];
          const timers = [];
          const cleanup = () => {
            timers.forEach(clearTimeout);
            inputs.forEach(ev => document.removeEventListener(ev, cancel, true));
          };
          const cancel = () => { cancelled = true; cleanup(); };
          inputs.forEach(ev => document.addEventListener(ev, cancel, { capture: true, passive: true }));

          const setNativeValue = (el, val) => {
            const proto = el.tagName === 'TEXTAREA'
              ? HTMLTextAreaElement.prototype
              : (el.tagName === 'SELECT' ? HTMLSelectElement.prototype : HTMLInputElement.prototype);
            const desc = Object.getOwnPropertyDescriptor(proto, 'value');
            if (desc && desc.set) desc.set.call(el, val);
            else el.value = val;
            el.dispatchEvent(new Event('input', { bubbles: true }));
            el.dispatchEvent(new Event('change', { bubbles: true }));
          };

          const restoredForms = new Set();
          const restoredScrolls = new Set();

          const applyPass = () => {
            if (cancelled || location.href !== snap.url) { cleanup(); return; }
            if (snap.windowX || snap.windowY) {
              window.scrollTo({ left: snap.windowX, top: snap.windowY, behavior: 'instant' });
            }
            for (let i = 0; i < snap.scrolls.length; i++) {
              if (restoredScrolls.has(i)) continue;
              const s = snap.scrolls[i];
              try {
                const el = document.querySelector(s.selector);
                if (!el) continue;
                const canScrollY = el.scrollHeight > el.clientHeight + 4;
                const canScrollX = el.scrollWidth > el.clientWidth + 4;
                if ((s.y > 0 && canScrollY) || (s.x > 0 && canScrollX)) {
                  el.scrollLeft = s.x;
                  el.scrollTop = s.y;
                  if (Math.abs(el.scrollTop - s.y) <= 8 && Math.abs(el.scrollLeft - s.x) <= 8) {
                    restoredScrolls.add(i);
                  }
                }
              } catch (e) {}
            }
            for (let i = 0; i < snap.forms.length; i++) {
              if (restoredForms.has(i)) continue;
              const f = snap.forms[i];
              try {
                const el = document.querySelector(f.selector);
                if (!el) continue;
                if (f.kind === 'checkbox' && typeof f.checked === 'boolean') {
                  if (el.checked !== f.checked) {
                    el.checked = f.checked;
                    el.dispatchEvent(new Event('change', { bubbles: true }));
                  }
                  restoredForms.add(i);
                } else if (f.kind === 'contenteditable' && typeof f.value === 'string') {
                  if (!el.textContent || el.textContent.trim().length === 0) {
                    el.textContent = f.value;
                    el.dispatchEvent(new Event('input', { bubbles: true }));
                  }
                  restoredForms.add(i);
                } else if (typeof f.value === 'string') {
                  if (!el.value || el.value.length === 0) {
                    setNativeValue(el, f.value);
                  }
                  restoredForms.add(i);
                }
              } catch (e) {}
            }
          };

          applyPass();
          [120, 400, 900, 1800].forEach(ms => timers.push(setTimeout(applyPass, ms)));
          timers.push(setTimeout(cleanup, 2200));
        })();
        """
        webView.evaluateJavaScript(script, in: nil, in: .page) { _ in }
    }

    private struct RawCapture: Decodable {
        let url: String
        let origin: String
        let windowX: Double
        let windowY: Double
        let sessionStorage: [String: String]
        let scrolls: [TabRehydrationSnapshot.ScrollEntry]
        let forms: [TabRehydrationSnapshot.FormEntry]
    }

    private static let captureScript = #"""
    (() => {
      const MAX_SS_BYTES = 1024 * 1024;
      const MAX_SCROLLS = 16;
      const MAX_FORMS = 32;
      const MAX_FIELD_CHARS = 32 * 1024;

      const cssEscape = (s) => (window.CSS && CSS.escape) ? CSS.escape(s) : String(s).replace(/([^\w-])/g, '\\$1');

      const stableSelector = (el) => {
        if (!el || el.nodeType !== 1) return null;
        if (el.id && document.querySelectorAll('#' + cssEscape(el.id)).length === 1) {
          return '#' + cssEscape(el.id);
        }
        const testId = el.getAttribute('data-testid') || el.getAttribute('data-test-id') || el.getAttribute('data-cy');
        if (testId) {
          const sel = el.tagName.toLowerCase() + '[data-testid="' + cssEscape(testId) + '"]';
          if (el.getAttribute('data-testid') && document.querySelectorAll(sel).length === 1) return sel;
        }
        const name = el.getAttribute('name');
        if (name && (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA' || el.tagName === 'SELECT')) {
          const sel = el.tagName.toLowerCase() + '[name="' + cssEscape(name) + '"]';
          if (document.querySelectorAll(sel).length === 1) return sel;
        }
        const parts = [];
        let cur = el;
        let depth = 0;
        while (cur && cur.nodeType === 1 && cur !== document.documentElement && depth < 10) {
          if (cur.id && document.querySelectorAll('#' + cssEscape(cur.id)).length === 1) {
            parts.unshift('#' + cssEscape(cur.id));
            break;
          }
          let tag = cur.tagName.toLowerCase();
          let nth = 1;
          let sib = cur.previousElementSibling;
          while (sib) {
            if (sib.tagName === cur.tagName) nth++;
            sib = sib.previousElementSibling;
          }
          parts.unshift(tag + ':nth-of-type(' + nth + ')');
          cur = cur.parentElement;
          depth++;
        }
        return parts.length ? parts.join(' > ') : null;
      };

      const ss = {};
      let ssBytes = 0;
      try {
        for (let i = 0; i < window.sessionStorage.length; i++) {
          const k = window.sessionStorage.key(i);
          if (k === null) continue;
          const v = window.sessionStorage.getItem(k);
          if (v === null) continue;
          if (ssBytes + k.length + v.length > MAX_SS_BYTES) break;
          ss[k] = v;
          ssBytes += k.length + v.length;
        }
      } catch (e) {}

      const scrolls = [];
      try {
        // Scan container tags (capped at 3,000 nodes) so periodic checkpoints stay
        // <2 ms even on 15,000+ node ClickUp/Linear boards.
        const containers = document.querySelectorAll('main, section, div, aside, article, ul, ol, nav, tbody, pre');
        const limit = Math.min(containers.length, 3000);
        for (let i = 0; i < limit && scrolls.length < MAX_SCROLLS; i++) {
          const el = containers[i];
          if ((el.scrollTop > 4 || el.scrollLeft > 4) && (el.scrollHeight > el.clientHeight + 4 || el.scrollWidth > el.clientWidth + 4)) {
            const sel = stableSelector(el);
            if (sel) scrolls.push({ selector: sel, x: el.scrollLeft, y: el.scrollTop });
          }
        }
      } catch (e) {}

      const sensitiveAutocomplete = /password|cc-|one-time-code|credit-card|cvc|cvv/i;
      const forms = [];
      try {
        const fields = document.querySelectorAll('input, textarea, select, [contenteditable="true"], [contenteditable=""]');
        for (let i = 0; i < fields.length && forms.length < MAX_FORMS; i++) {
          const el = fields[i];
          const ac = (el.getAttribute('autocomplete') || '') + ' ' + (el.getAttribute('name') || '');
          if (sensitiveAutocomplete.test(ac)) continue;
          if (el.isContentEditable) {
            const txt = el.textContent || '';
            if (txt.trim().length > 0 && txt.length <= MAX_FIELD_CHARS) {
              const sel = stableSelector(el);
              if (sel) forms.push({ selector: sel, kind: 'contenteditable', value: txt, checked: null });
            }
            continue;
          }
          const tag = el.tagName;
          if (tag === 'INPUT') {
            const t = (el.type || 'text').toLowerCase();
            if (t === 'password' || t === 'hidden' || t === 'file' || t === 'submit' || t === 'button' || t === 'reset') continue;
            if (t === 'checkbox' || t === 'radio') {
              if (el.checked !== el.defaultChecked) {
                const sel = stableSelector(el);
                if (sel) forms.push({ selector: sel, kind: 'checkbox', value: null, checked: !!el.checked });
              }
            } else if (el.value && el.value !== el.defaultValue && el.value.length <= MAX_FIELD_CHARS) {
              const sel = stableSelector(el);
              if (sel) forms.push({ selector: sel, kind: 'text', value: el.value, checked: null });
            }
          } else if (tag === 'TEXTAREA') {
            if (el.value && el.value !== el.defaultValue && el.value.length <= MAX_FIELD_CHARS) {
              const sel = stableSelector(el);
              if (sel) forms.push({ selector: sel, kind: 'text', value: el.value, checked: null });
            }
          } else if (tag === 'SELECT') {
            if (el.value) {
              const sel = stableSelector(el);
              if (sel) forms.push({ selector: sel, kind: 'select', value: el.value, checked: null });
            }
          }
        }
      } catch (e) {}

      return JSON.stringify({
        url: location.href,
        origin: location.origin,
        windowX: window.scrollX || 0,
        windowY: window.scrollY || 0,
        sessionStorage: ss,
        scrolls: scrolls,
        forms: forms
      });
    })();
    """#
}
