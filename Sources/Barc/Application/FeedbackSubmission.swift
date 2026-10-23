// Modified for Barc: application identity, branding and fork configuration, 2026-10-23.
import AppKit
import Foundation

/// Prepares a GitHub issue draft. Barc has no report-submission server.
enum FeedbackSubmission {
    enum Kind: String, CaseIterable {
        case bug, feature, question, other

        var title: String {
            switch self {
            case .bug: return "Something is broken"
            case .feature: return "A feature idea"
            case .question: return "A question"
            case .other: return "Something else"
            }
        }
    }

    struct Report {
        var kind: Kind = .bug
        var message: String = ""
        var environment: SupportContact.Environment

        var isSendable: Bool {
            message.trimmingCharacters(in: .whitespacesAndNewlines).count >= 10
        }
    }

    enum Outcome: Equatable {
        /// A draft was opened for the user to review, not published.
        case draftOpened
        case failed(String)
    }

    static func draftURL(for report: Report) -> URL? {
        let body = report.message.trimmingCharacters(in: .whitespacesAndNewlines)
            + "\n\n--\n" + report.environment.report + "\n"
        return SupportContact.issueDraft(title: "Barc: \(report.kind.title)", body: body)
    }

    @MainActor
    static func send(_ report: Report) async -> Outcome {
        guard report.isSendable, let url = draftURL(for: report), NSWorkspace.shared.open(url) else {
            return .failed("Could not open the draft. Your report is still here; visit github.com/mcgri/Barc/issues to report it.")
        }
        return .draftOpened
    }
}
