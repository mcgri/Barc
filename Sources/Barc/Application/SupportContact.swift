// Modified for Barc: application identity, branding and fork configuration, 2026-10-23.
import AppKit
import Foundation

/// Barc support routes. Reports open editable GitHub drafts and are published
/// only when the user submits them on GitHub.
enum SupportContact {
    static let contactPage = URL(string: "https://github.com/mcgri/Barc/issues")!
    static let issues = contactPage
    static let discussions = contactPage
    static let securityAdvisory = URL(string: "https://github.com/mcgri/Barc/security/advisories/new")!

    // MARK: - What this Mac is

    /// The four facts a bug report needs and nothing more.
    ///
    /// No identifier of any kind: not the serial, not a generated id, not the
    /// hostname, not a single thing that says which Mac this is rather than
    /// what kind. Reproducing a bug needs the version it happened in, the
    /// system it happened on and the shape of the machine; it never needs to
    /// know the machine again later.
    struct Environment: Equatable {
        var version: String
        var build: String
        var system: String
        var model: String

        /// The lines pasted at the foot of a report, ready to read before sending.
        var report: String {
            """
            Barc \(version) (\(build))
            macOS \(system)
            Mac \(model)
            """
        }
    }

    /// Reads this Mac. `hw.model` is the marketing-free model identifier
    /// ("Mac15,3"), which says what the hardware is without saying whose.
    static func currentEnvironment() -> Environment {
        Environment(
            version: AppInfo.version,
            build: AppInfo.build,
            system: systemVersion(),
            model: hardwareModel()
        )
    }

    private static func systemVersion() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    private static func hardwareModel() -> String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 else { return "unknown" }
        // `String(cString:)` is deprecated. Cut at the terminator the same way
        // it did, then decode -- `String(decoding:as:)` repairs malformed bytes
        // exactly as `String(cString:)` did, so this is the same string.
        let utf8 = bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: utf8, as: UTF8.self)
    }

    // MARK: - GitHub drafts

    static func issueDraft(title: String, body: String) -> URL? {
        var components = URLComponents(url: issues.appending(path: "new"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "title", value: title),
            URLQueryItem(name: "body", value: body)
        ]
        // GitHub decodes query strings as form data, where a bare + is a space.
        let encodedQuery = components?.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        components?.percentEncodedQuery = encodedQuery
        return components?.url
    }

    /// The templates. Each one asks for what we would otherwise have to write
    /// back and ask for, so the first reply can be an answer rather than a
    /// question.
    enum Template {
        case bug, feature, crash(String), question

        func subject(_ environment: Environment) -> String {
            switch self {
            case .bug: return "Bug in Barc \(environment.version)"
            case .feature: return "Feature idea for Barc"
            case .crash: return "Barc \(environment.version) crashed"
            case .question: return "Question about Barc \(environment.version)"
            }
        }

        func body(_ environment: Environment) -> String {
            let prompt: String
            switch self {
            case .bug:
                prompt = """
                    What happened:


                    What you expected instead:


                    Steps to reproduce it:
                    1.
                    2.
                    3.

                    Which site, if it is one site:

                    """
            case .feature:
                prompt = """
                    What you would like Barc to do:


                    What you are doing when you want it:


                    How you work around it today:

                    """
            case .crash(let report):
                prompt = """
                    What you were doing when it crashed:


                    ---- crash report ----
                    \(report)
                    ---- end of crash report ----

                    """
            case .question:
                prompt = """
                    Your question:

                    """
            }
            return prompt + "\n--\n" + environment.report + "\n"
        }
    }

    /// An editable draft, never a direct submission.
    static func url(for template: Template, environment: Environment) -> URL? {
        issueDraft(title: template.subject(environment), body: template.body(environment))
    }

    /// The head of a crash report, short enough to survive a `mailto:` URL.
    ///
    /// A whole report is a hundred and twenty frames of backtrace, and a URL
    /// that long is rejected or silently cut by the mail client -- which would
    /// lose the top of the stack, the only part that names the bug. The first
    /// frames are the ones that matter, so those are what goes in the draft,
    /// with a line saying plainly that there is more and where it is.
    static func excerpt(of report: String, maxLines: Int = 40, maxCharacters: Int = 3000) -> String {
        let lines = report.split(separator: "\n", omittingEmptySubsequences: false)
        var kept: [Substring] = []
        var characters = 0
        for line in lines.prefix(maxLines) {
            if characters + line.count + 1 > maxCharacters { break }
            kept.append(line)
            characters += line.count + 1
        }
        let text = kept.joined(separator: "\n")
        guard kept.count < lines.count else { return text }
        return text + "\n[\(lines.count - kept.count) more lines in the saved report]"
    }

    // MARK: - Opening

    /// Opens a draft for review. This does not publish an issue.
    @MainActor
    @discardableResult
    static func compose(_ template: Template) -> Bool {
        NSWorkspace.shared.open(url(for: template, environment: currentEnvironment()) ?? contactPage)
    }
}
