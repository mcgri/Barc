// Modified for Barc: application identity, branding and fork configuration, 2026-10-23.
import Foundation
import Testing
@testable import Barc

@Suite("Barc reports are editable GitHub drafts")
struct FeedbackSubmissionTests {
    private let environment = SupportContact.Environment(
        version: "0.1.0", build: "1", system: "26.6.0", model: "Mac15,3"
    )

    @Test("Draft targets Barc and preserves the message and displayed diagnostics")
    func draftContents() throws {
        let message = "a & b = c + d?e#f\nsecond line 100% sure"
        let report = FeedbackSubmission.Report(kind: .bug, message: message, environment: environment)
        let url = try #require(FeedbackSubmission.draftURL(for: report))
        #expect(url.scheme == "https")
        #expect(url.host == "github.com")
        #expect(url.path == "/mcgri/Barc/issues/new")
        #expect(url.absoluteString.contains("%2B"))
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.first { $0.name == "title" }?.value == "Barc: Something is broken")
        #expect(items.first { $0.name == "body" }?.value == message + "\n\n--\n" + environment.report + "\n")
        #expect(Set(items.map(\.name)) == ["title", "body"])
    }

    @Test("Empty or short reports cannot open a draft")
    func sendableFloor() {
        for message in ["", "  \n ", "too short"] {
            #expect(!FeedbackSubmission.Report(message: message, environment: environment).isSendable)
        }
        #expect(FeedbackSubmission.Report(message: "this is long enough", environment: environment).isSendable)
    }

    @Test("An invalid report fails before opening an external application")
    @MainActor
    func invalidReport() async {
        let report = FeedbackSubmission.Report(message: "", environment: environment)
        guard case .failed = await FeedbackSubmission.send(report) else {
            Issue.record("An empty report must not open a draft")
            return
        }
    }
}
