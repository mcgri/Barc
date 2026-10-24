// Modified for Barc: application identity, branding and fork configuration, 2026-10-23.
import Foundation
import Testing
@testable import Barc

@Suite("Tab renaming")
@MainActor
struct NamingTests {
    private func url(_ string: String) -> URL { URL(string: string)! }

    @Test("Whitespace is collapsed, not merely trimmed")
    func normalisationCollapsesWhitespace() {
        #expect(TabNaming.normalized("  Release   notes \n") == "Release notes")
        #expect(TabNaming.normalized("Docs") == "Docs")
    }

    @Test("An empty or blank value is not a name")
    func blankIsNotAName() {
        #expect(TabNaming.normalized("") == nil)
        #expect(TabNaming.normalized("   \t\n ") == nil)
    }

    @Test("A pasted paragraph is capped rather than stored whole")
    func longNamesAreCapped() {
        let name = TabNaming.normalized(String(repeating: "a", count: 500))
        #expect(name?.count == TabNaming.maximumLength)
    }

    @Test("A custom name wins over the page title")
    func customNameWins() {
        let title = TabNaming.displayTitle(
            customName: "Release notes",
            pageTitle: "(3) Pull requests · example/app",
            url: url("https://github.com/example/app/pulls")
        )
        #expect(title == "Release notes")
    }

    @Test("Without a name the ladder falls back exactly as the sidebar did")
    func fallbackLadder() {
        #expect(TabNaming.displayTitle(customName: nil, pageTitle: "Example", url: url("https://example.com")) == "Example")
        // An empty page title is not a title: WebKit reports one for a page
        // that has not set `<title>` at all.
        #expect(TabNaming.displayTitle(customName: nil, pageTitle: "", url: url("https://www.example.com")) == "example.com")
        #expect(TabNaming.displayTitle(customName: nil, pageTitle: nil, url: url("https://www.example.com/a")) == "example.com")
        #expect(TabNaming.displayTitle(customName: nil, pageTitle: nil, url: url("about:blank")) == "about:blank")
    }

    @Test("Observed service decoration is removed only from its own page captions")
    func compactServiceCaptions() {
        let cases: [(String, String, String)] = [
            ("https://docs.google.com/document/d/fixture/edit", "Silvermere - Google Docs", "Silvermere"),
            ("https://www.google.com/maps/place/fixture", "EXAMPLE CAFE - Google Maps", "EXAMPLE CAFE"),
            ("https://maps.google.com/", "EXAMPLE CAFE - Google Maps", "EXAMPLE CAFE"),
            ("https://github.com/mcgri/Barc", "GitHub - mocky/Browser: This is a sample browser · GitHub", "mocky/Browser: This is a sample browser"),
            ("https://www.google.com/search?q=maps", "Example - Google Maps", "Example - Google Maps"),
            ("https://example.invalid/maps/", "Example - Google Maps", "Example - Google Maps"),
            ("https://docs.google.com.example.invalid/", "Example - Google Docs", "Example - Google Docs"),
            ("https://example.invalid/", "GitHub - Project · GitHub", "GitHub - Project · GitHub"),
            ("https://github.com/mcgri/Barc", "Project · GitHub", "Project · GitHub"),
            ("https://docs.google.com/", " - Google Docs", " - Google Docs"),
            ("https://github.com/", "GitHub -  · GitHub", "GitHub -  · GitHub")
        ]
        for (address, raw, expected) in cases {
            #expect(TabNaming.displayTitle(customName:nil,pageTitle:raw,url:url(address)) == expected)
            #expect(TabNaming.displayTitle(customName:raw,pageTitle:raw,url:url(address)) == raw,
                    "A chosen name is never formatted as a service title")
        }
    }

    @Test("Compact restored labels keep the full page title and chosen name in the saved session")
    func compactCaptionSnapshot() {
        let raw = "Fixture - Google Docs"
        let snapshot = SessionSnapshot.Tab(url:url("https://docs.google.com/document/d/fixture/edit"),title:raw)
        let tab = Tab(restoring:snapshot,identity:.standard)
        #expect(tab.displayTitle == "Fixture" && tab.pageTitle == raw)
        #expect(tab.snapshot().title == raw && tab.snapshot().customName == nil)
        TabNameStore.shared.restore("Chosen - Google Docs",for:tab.id)
        defer { TabNameStore.shared.forget(tab.id) }
        #expect(tab.displayTitle == "Chosen - Google Docs")
        #expect(tab.snapshot().title == raw && tab.snapshot().customName == "Chosen - Google Docs")
    }

    @Test("Renaming records the name and reports what happened")
    func renameStoresName() {
        let store = TabNameStore()
        let id = UUID()

        #expect(store.rename(id, to: "  Release  notes ") == .named("Release notes"))
        #expect(store.name(for: id) == "Release notes")
        // Committing the same text again is not a change, so nothing is announced.
        #expect(store.rename(id, to: "Release notes") == .unchanged)
    }

    @Test("Committing an empty field clears the name and restores the page title")
    func clearingRestoresTheTitle() {
        let store = TabNameStore()
        let id = UUID()
        store.rename(id, to: "Release notes")

        #expect(store.rename(id, to: "   ") == .cleared)
        #expect(store.name(for: id) == nil)
        #expect(
            TabNaming.displayTitle(customName: store.name(for: id), pageTitle: "Pull requests", url: url("https://github.com"))
                == "Pull requests"
        )
    }

    @Test("Clearing a tab that never had a name changes nothing")
    func clearingAnUnnamedTab() {
        let store = TabNameStore()
        #expect(store.rename(UUID(), to: "") == .unchanged)
    }

    @Test("Names are per tab, and a closed tab takes its name with it")
    func namesAreScopedToATab() {
        let store = TabNameStore()
        let first = UUID()
        let second = UUID()
        store.rename(first, to: "Work")
        store.rename(second, to: "Home")

        #expect(store.name(for: first) == "Work")
        store.forget(first)
        #expect(store.name(for: first) == nil)
        #expect(store.name(for: second) == "Home")
    }

    @Test("A restored name is taken as written, without being re-normalised")
    func restoringDoesNotRename() {
        let store = TabNameStore()
        let id = UUID()
        store.restore("Release notes", for: id)
        #expect(store.name(for: id) == "Release notes")

        store.restore(nil, for: id)
        #expect(store.isEmpty)
    }

    @Test("A rename is announced; an unchanged commit is not")
    func renameToasts() {
        #expect(Toast.rename(.named("Work"), restoredTitle: "Example")?.message == "Renamed to “Work”")
        #expect(Toast.rename(.cleared, restoredTitle: "Example")?.message == "Name cleared — showing “Example”")
        #expect(Toast.rename(.unchanged, restoredTitle: "Example") == nil)
    }
}
