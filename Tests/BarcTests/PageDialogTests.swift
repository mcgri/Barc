import AppKit
import Testing
import WebKit
@testable import Barc

@Suite("Page alert, confirm and prompt dialogs", .serialized)
@MainActor
struct PageDialogTests {
    private let selectors = [
        #selector(WKUIDelegate.webView(_:runJavaScriptAlertPanelWithMessage:initiatedByFrame:completionHandler:)),
        #selector(WKUIDelegate.webView(_:runJavaScriptConfirmPanelWithMessage:initiatedByFrame:completionHandler:)),
        #selector(WKUIDelegate.webView(_:runJavaScriptTextInputPanelWithPrompt:defaultText:initiatedByFrame:completionHandler:))
    ]

    private func page(_ html: String = "<p>Dialog fixture</p>") async throws -> (WKWebView, PageWebCoordinator) {
        let coordinator = PageWebCoordinator()
        let view = try await MemoryTestPage.make(html: html)
        view.uiDelegate = coordinator
        return (view, coordinator)
    }

    @Test("Tabs and glance, Little Arc and web-app pages all answer page dialogs")
    func delegatesAnswer() async throws {
        let session = TestSession.make().0
        let tab = session.newTab(url: URL(string: "about:blank")!)
        defer { tab.unload() }
        for selector in selectors {
            #expect(tab.webView().uiDelegate?.responds(to: selector) == true)
            #expect(PageWebCoordinator().responds(to: selector))
        }
    }

    @Test("confirm() returns what the person chose instead of always Cancel")
    func confirmAnswers() async throws {
        let (view, coordinator) = try await page()
        _ = coordinator
        var shown: NSAlert?
        defer { PageDialogs.testResponder = nil }
        PageDialogs.testResponder = { alert in shown = alert; return .confirmed }
        #expect(try await view.evaluateJavaScript("confirm('Delete this project?')") as? Bool == true)
        #expect(shown?.messageText == "127.0.0.1 says")
        #expect(shown?.informativeText == "Delete this project?")
        #expect(shown?.buttons.map(\.title) == ["OK", "Cancel"])
        PageDialogs.testResponder = { _ in .cancelled }
        #expect(try await view.evaluateJavaScript("confirm('Delete this project?')") as? Bool == false)
    }

    @Test("alert() shows its message and prompt() returns the typed text")
    func alertAndPrompt() async throws {
        let (view, coordinator) = try await page()
        _ = coordinator
        var shown: [NSAlert] = []
        defer { PageDialogs.testResponder = nil }
        PageDialogs.testResponder = { alert in
            shown.append(alert)
            return alert.accessoryView == nil ? .dismissed : .text("Renamed")
        }
        _ = try await view.evaluateJavaScript("alert('Saved'); true")
        #expect(shown.first?.informativeText == "Saved")
        #expect(shown.first?.buttons.map(\.title) == ["OK"])
        #expect(try await view.evaluateJavaScript("prompt('New name', 'Untitled')") as? String == "Renamed")
        #expect((shown.last?.accessoryView as? NSTextField)?.stringValue == "Untitled")
        PageDialogs.testResponder = { _ in .cancelled }
        #expect(try await view.evaluateJavaScript("prompt('New name') === null") as? Bool == true)
    }

    @Test("A dialog from an embedded frame says so")
    func embeddedFrame() async throws {
        let (view, coordinator) = try await page("<iframe srcdoc='<p>Embedded</p>'></iframe>")
        _ = coordinator
        var shown: NSAlert?
        defer { PageDialogs.testResponder = nil }
        PageDialogs.testResponder = { alert in shown = alert; return .dismissed }
        _ = try await view.evaluateJavaScript("document.querySelector('iframe').contentWindow.alert('From the frame'); true")
        #expect(shown?.messageText == "An embedded page at 127.0.0.1 says")
    }

    @Test("From the second dialog the person can silence the page until it navigates")
    func silencing() async throws {
        let (view, coordinator) = try await page()
        _ = coordinator
        var count = 0
        var offeredSilence: [Bool] = []
        defer { PageDialogs.testResponder = nil }
        PageDialogs.testResponder = { alert in
            count += 1
            offeredSilence.append(alert.showsSuppressionButton)
            if alert.showsSuppressionButton { alert.suppressionButton?.state = .on }
            return .confirmed
        }
        #expect(try await view.evaluateJavaScript("confirm('One')") as? Bool == true)
        #expect(try await view.evaluateJavaScript("confirm('Two')") as? Bool == true)
        #expect(try await view.evaluateJavaScript("confirm('Three')") as? Bool == false, "A silenced page gets Cancel without a dialog")
        #expect(count == 2)
        #expect(offeredSilence == [false, true])
        try await MemoryTestPage.load(view, html: "<p>Elsewhere</p>")
        _ = try await view.evaluateJavaScript("history.replaceState(null, '', '/next/'); true")
        #expect(try await view.evaluateJavaScript("confirm('Four')") as? Bool == true, "A new page starts with dialogs allowed")
        #expect(count == 3)
    }
}
