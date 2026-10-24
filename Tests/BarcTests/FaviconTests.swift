// Modified for Barc: application identity, branding and fork configuration, 2026-10-23.
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Barc

// Discovery and ranking are pure logic, so every awkward site shape below is a
// test rather than a page someone has to visit to find out what happens.

@Suite("Favicon discovery")
struct FaviconSourceTests {
    private let page = URL(string: "https://www.example.com/some/deep/page?q=1")!

    @Test("The cache key is the host, lowercased")
    func cacheKeyIsHost() {
        #expect(FaviconSource.cacheKey(for: URL(string: "https://Example.COM/a")!) == "example.com")
        #expect(FaviconSource.cacheKey(for: URL(string: "http://example.com/a")!) == "example.com")
    }

    @Test("Different local development ports keep their own icons")
    func cacheSeparatesPorts() {
        let sales = URL(string: "http://localhost:1000/")!
        let app = URL(string: "http://localhost:3000/")!
        #expect(FaviconSource.cacheKey(for: sales) != FaviconSource.cacheKey(for: app))
        #expect(FaviconSource.cacheKey(for: URL(string: "https://example.com:443/a")!) == "example.com")
    }

    @Test("Pages that cannot have a favicon have no key", arguments: [
        "about:blank",
        "file:///tmp/index.html",
        "data:text/html,hello"
    ])
    func unfetchableSchemesHaveNoKey(address: String) {
        #expect(FaviconSource.cacheKey(for: URL(string: address)!) == nil)
    }

    @Test("The convention URL is /favicon.ico at the page's own origin")
    func conventionURL() {
        #expect(FaviconSource.conventionURL(for: page)?.absoluteString == "https://www.example.com/favicon.ico")
        #expect(
            FaviconSource.conventionURL(for: URL(string: "http://localhost:8080/app")!)?.absoluteString
                == "http://localhost:8080/favicon.ico"
        )
        #expect(FaviconSource.conventionURL(for: URL(string: "about:blank")!) == nil)
    }

    @Test("Declared sizes are read as the largest square offered")
    func declaredSizes() {
        #expect(FaviconSource.largestDeclaredSide(in: "16x16 32x32") == 32)
        #expect(FaviconSource.largestDeclaredSide(in: "180X180") == 180)
        #expect(FaviconSource.largestDeclaredSide(in: "any") == nil)
        #expect(FaviconSource.largestDeclaredSide(in: "") == nil)
    }

    @Test("The size closest to 32 pixels without going under it wins")
    func ranksBySize() {
        let links = [
            FaviconLink(href: "/apple.png", rel: "apple-touch-icon", sizes: "180x180"),
            FaviconLink(href: "/small.png", rel: "icon", sizes: "16x16"),
            FaviconLink(href: "/right.png", rel: "icon", sizes: "32x32"),
            FaviconLink(href: "/unsized.ico", rel: "shortcut icon")
        ]
        #expect(FaviconSource.candidates(pageURL: page, links: links).map(\.path) == [
            "/right.png",    // exactly the target
            "/apple.png",    // larger than the target, so still downscales cleanly
            "/unsized.ico",  // unknown, and probably a multi-size .ico
            "/small.png",    // smaller than the target
            "/favicon.ico"   // the convention, always tried last
        ])
    }

    @Test("Relative hrefs resolve against the page, not the origin")
    func relativeHrefs() {
        let links = [FaviconLink(href: "icon.png", rel: "icon", sizes: "32x32")]
        #expect(
            FaviconSource.candidates(pageURL: page, links: links).first?.absoluteString
                == "https://www.example.com/some/deep/icon.png"
        )
    }

    @Test("SVG icons and pinned-tab stencils are not candidates")
    func rejectsVectorAndStencil() {
        let links = [
            FaviconLink(href: "/icon.svg", rel: "icon"),
            FaviconLink(href: "/vector", rel: "icon", type: "image/svg+xml"),
            FaviconLink(href: "/pinned.svg", rel: "mask-icon"),
            FaviconLink(href: "/inline", rel: "icon", type: "image/svg+xml")
        ]
        #expect(FaviconSource.candidates(pageURL: page, links: links).map(\.path) == ["/favicon.ico"])
    }

    @Test("Non-web icon URLs are skipped")
    func rejectsNonWebURLs() {
        let links = [
            FaviconLink(href: "data:image/png;base64,AAAA", rel: "icon"),
            FaviconLink(href: "  ", rel: "icon")
        ]
        #expect(FaviconSource.candidates(pageURL: page, links: links).map(\.path) == ["/favicon.ico"])
    }

    @Test("A page that declares /favicon.ico itself does not get it twice")
    func deduplicates() {
        let links = [FaviconLink(href: "/favicon.ico", rel: "icon")]
        #expect(FaviconSource.candidates(pageURL: page, links: links).count == 1)
    }

    @Test("A page-declared icon outranks a guessed one")
    func sourceOrdering() {
        #expect(FaviconSourceKind.convention < FaviconSourceKind.dom)
    }
}

// The decoder is the only thing that touches bytes a website sent us, so these
// tests are as much about what it refuses as what it accepts.

@Suite("Favicon decoding")
struct FaviconDecoderTests {
    @Test("macOS decodes .ico natively, so nothing needs to be written for it")
    func systemSupportsICO() {
        // Verified rather than assumed: this is why Barc carries no ICO parser.
        let identifiers = (CGImageSourceCopyTypeIdentifiers() as? [String]) ?? []
        #expect(identifiers.contains(UTType.ico.identifier))
    }

    @Test("A single-image .ico decodes to a normalised PNG")
    func decodesICO() throws {
        let ico = try ICOFixture.make([(32, .green)])
        let normalized = try FaviconDecoder.normalize(ico)
        let size = try ICOFixture.pixelSize(of: normalized)
        #expect(size == CGSize(width: 32, height: 32))
        #expect(ICOFixture.type(of: normalized) == UTType.png.identifier)
    }

    @Test("The 32-pixel image inside a multi-size .ico is the one used")
    func picksTheRightImageInsideAnICO() throws {
        let ico = try ICOFixture.make([(16, .red), (32, .green), (64, .blue)])
        let normalized = try FaviconDecoder.normalize(ico)
        #expect(try ICOFixture.dominantChannel(of: normalized) == .green)
    }

    @Test("With nothing at or above 32 pixels, the largest below it is used")
    func fallsBackToTheLargestSmallImage() throws {
        // 16 is the smallest image ImageIO will accept inside an .ico:
        // measured, an .ico carrying an 8-pixel entry is rejected outright.
        let ico = try ICOFixture.make([(16, .red), (24, .green)])
        let normalized = try FaviconDecoder.normalize(ico)
        #expect(try ICOFixture.dominantChannel(of: normalized) == .green)
        // A ceiling, not a target: a 24-pixel icon is not blown up to 32.
        #expect(try ICOFixture.pixelSize(of: normalized) == CGSize(width: 24, height: 24))
    }

    @Test("A plain PNG is normalised and shrunk to the icon size")
    func normalisesLargePNG() throws {
        let png = try ICOFixture.png(side: 256, channel: .blue)
        #expect(try ICOFixture.pixelSize(of: FaviconDecoder.normalize(png)) == CGSize(width: 32, height: 32))
    }

    @Test("Size selection prefers the closest size at or above the target")
    func sizePreference() {
        #expect(FaviconDecoder.isBetter(32, than: 64))
        #expect(FaviconDecoder.isBetter(48, than: 16))
        #expect(FaviconDecoder.isBetter(16, than: 8))
        #expect(!FaviconDecoder.isBetter(16, than: 32))
        #expect(!FaviconDecoder.isBetter(64, than: 32))
    }

    @Test("Bytes that are not an image are refused")
    func refusesGarbage() {
        #expect(throws: FaviconDecoder.Failure.unsupportedFormat) {
            try FaviconDecoder.normalize(Data("<!doctype html><title>404</title>".utf8))
        }
        #expect(throws: FaviconDecoder.Failure.unsupportedFormat) {
            try FaviconDecoder.normalize(Data())
        }
    }

    @Test("Oversized payloads are refused before anything parses them")
    func refusesLargePayloads() {
        let oversized = Data(repeating: 0, count: FaviconDecoder.maximumByteCount + 1)
        #expect(throws: FaviconDecoder.Failure.tooLarge) { try FaviconDecoder.normalize(oversized) }
    }

    @Test("An image with absurd dimensions is refused without being decoded")
    func refusesDecompressionBombs() throws {
        // A 2048-pixel PNG of one colour compresses to a few kilobytes, so the
        // byte cap alone would let it through; the pixel cap is what stops it.
        let bomb = try ICOFixture.png(side: FaviconDecoder.maximumSourcePixelSize * 2, channel: .red)
        #expect(bomb.count < FaviconDecoder.maximumByteCount)
        #expect(throws: FaviconDecoder.Failure.noUsableImage) { try FaviconDecoder.normalize(bomb) }
    }

    @Test("SVG is refused, even though NSImage would happily render it")
    func refusesSVG() {
        let svg = Data("<svg xmlns='http://www.w3.org/2000/svg' width='16' height='16'></svg>".utf8)
        #expect(throws: FaviconDecoder.Failure.unsupportedFormat) { try FaviconDecoder.normalize(svg) }
    }
}

@Suite("Arc's cached page icons")
struct ArcFaviconReaderTests {
    @Test("Ranked shortcuts carry their cached icons and older rankings still decode without images")
    func rankedShortcutIcons() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = URL(string: "https://ranked-icons.invalid/")!
        do {
            let db = try SQLiteDatabase(path: directory.appending(path: "Top Sites").path)
            try db.execute("CREATE TABLE top_sites(url TEXT,title TEXT,url_rank INTEGER);")
            try db.run("INSERT INTO top_sites VALUES(?, 'Ranked site', 0);", [.text(url.absoluteString)])
            try db.execute("PRAGMA wal_checkpoint(TRUNCATE);")
            let icons = try SQLiteDatabase(path: directory.appending(path: "Favicons").path)
            try icons.execute("CREATE TABLE icon_mapping(page_url TEXT,icon_id INTEGER); CREATE TABLE favicon_bitmaps(id INTEGER PRIMARY KEY,icon_id INTEGER,image_data BLOB,width INTEGER,height INTEGER);")
            try icons.run("INSERT INTO icon_mapping VALUES(?,1);", [.text(url.absoluteString)])
            try icons.run("INSERT INTO favicon_bitmaps VALUES(1,1,?,32,32);", [.blob(try ICOFixture.png(side: 32, channel: .green))])
            try icons.execute("PRAGMA wal_checkpoint(TRUNCATE);")
        }
        let site = try #require(try ArcProfileReader.topSites(directory).first)
        let icon = try #require(site.favicon)
        #expect(icon.matches(url) && site.title == "Ranked site")
        #expect(try ICOFixture.dominantChannel(of: icon.data) == .green)
        #expect(try JSONDecoder().decode(BrowserTopSite.self, from: JSONEncoder().encode(site)) == site)
        let old = Data("{\"url\":\"https://ranked-icons.invalid/\",\"title\":\"Ranked site\"}".utf8)
        #expect(try JSONDecoder().decode(BrowserTopSite.self, from: old).favicon == nil)
    }

    @Test("Only requested pages are read, and the closest usable bitmap is retained")
    func selectedPages() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "Favicons")
        do {
            let db = try SQLiteDatabase(path: file.path)
            try db.execute("CREATE TABLE icon_mapping (page_url TEXT, icon_id INTEGER); CREATE TABLE favicon_bitmaps (id INTEGER PRIMARY KEY, icon_id INTEGER, image_data BLOB, width INTEGER, height INTEGER); CREATE TABLE favicons (id INTEGER PRIMARY KEY, url TEXT); INSERT INTO favicons VALUES (1, 'https://github.com/favicon.ico'); INSERT INTO favicons VALUES (2, 'https://github.githubassets.com/favicons/favicon-failure.svg');")
            try db.run("INSERT INTO icon_mapping VALUES (?, ?);", [.text("http://localhost:1000/"), .integer(1)])
            try db.run("INSERT INTO icon_mapping VALUES (?, ?);", [.text("http://localhost:3000/"), .integer(2)])
            try db.run("INSERT INTO icon_mapping VALUES (?, ?);", [.text("https://unrelated.invalid/"), .integer(3)])
            for (id, side, channel) in [(1, 16, ICOFixture.Channel.red), (1, 32, .green), (1, 64, .blue), (2, 32, .blue), (3, 32, .red)] {
                try db.run("INSERT INTO favicon_bitmaps(icon_id,image_data,width,height) VALUES(?,?,?,?);",
                    [.integer(Int64(id)), .blob(try ICOFixture.png(side: side, channel: channel)), .integer(Int64(side)), .integer(Int64(side))])
            }
            try db.run("INSERT INTO favicon_bitmaps(icon_id,image_data,width,height) VALUES(1,?,32,32);", [.blob(Data("invalid".utf8))])
            try db.execute("PRAGMA wal_checkpoint(TRUNCATE);")
        }
        let a = URL(string: "http://localhost:1000/#dashboard")!
        let b = URL(string: "http://localhost:3000/")!
        let read = try ArcFaviconReader.read(directory, pages: [a, b])
        #expect(read.icons.count == 2)
        #expect(read.skipped == 1)
        let first = try #require(read.icons[PageFavicon.key(for: a)!])
        let second = try #require(read.icons[PageFavicon.key(for: b)!])
        #expect(try ICOFixture.dominantChannel(of: first) == .green)
        #expect(try ICOFixture.dominantChannel(of: second) == .blue)
        let badge = try #require(try ArcFaviconReader.githubBadge(directory))
        #expect(try ICOFixture.dominantChannel(of: badge) == .green)
    }

    @Test("An icon's page match ignores fragments but keeps paths, queries and ports separate")
    func exactPageMatch() throws {
        let icon = PageFavicon(pageURL: URL(string: "http://localhost:1000/a?q=1#one")!, data: Data([1, 2]))
        #expect(icon.matches(URL(string: "http://localhost:1000/a?q=1#two")!))
        #expect(!icon.matches(URL(string: "http://localhost:3000/a?q=1")!))
        #expect(!icon.matches(URL(string: "http://localhost:1000/b?q=1")!))
        #expect(!icon.matches(URL(string: "http://localhost:1000/a?q=2")!))
        #expect(try JSONDecoder().decode(PageFavicon.self, from: JSONEncoder().encode(icon)) == icon)
    }

    @Test("A repeated import fills a missing icon without adding tabs or replacing an existing icon")
    @MainActor
    func enrichExistingTabs() throws {
        let session = TestSession.make().0
        let id = UUID()
        let url = URL(string: "http://localhost:1000/")!
        let sourceID = "fixture/tab/space/page"
        var incoming = SessionSnapshot.Space(id: id, name: "Imported", tabs: [
            SessionSnapshot.Tab(url: url, importedSourceID: sourceID)
        ], activeTabIndex: 0, identity: .isolated(id))
        _ = try session.applyArcSpaces([incoming])
        let count = session.spaces.flatMap(\.tabs).count
        let icon = PageFavicon(pageURL: url, data: try ICOFixture.png(side: 32, channel: .green))
        incoming.tabs[0].favicon = icon
        _ = try session.applyArcSpaces([incoming])
        let tab = try #require(session.spaces.flatMap(\.tabs).first { $0.importedSourceID == sourceID })
        #expect(tab.restoredFavicon == icon)
        #expect(tab.snapshot().favicon == icon)
        incoming.tabs[0].favicon = PageFavicon(pageURL: url, data: try ICOFixture.png(side: 32, channel: .blue))
        _ = try session.applyArcSpaces([incoming])
        #expect(tab.restoredFavicon == icon)
        #expect(session.spaces.flatMap(\.tabs).count == count)
        tab.load(URL(string: "about:blank")!)
        #expect(tab.snapshot().favicon == nil)
    }

    @Test("Folder badges survive a session round trip and a user-chosen icon removes the old badge")
    @MainActor
    func folderBadges() throws {
        let session = TestSession.make().0
        let data = try ICOFixture.png(side: 32, channel: .green)
        let group = TabGroup(name: "Source folder", symbolName: "folder", badgeIcon: data)
        session.activeSpace.addGroup(group)
        let imported = session.snapshot().spaces[0]
        let restored = try #require(BrowserSession.spaces(from: session.snapshot())?.first?.groups.first)
        #expect(restored.badgeIcon == data)
        restored.setIcon(.emoji("🧪"))
        #expect(restored.badgeIcon == nil)
        group.setIcon(.automatic)
        _ = try session.applyArcSpaces([imported])
        #expect(group.badgeIcon == nil, "A repeated import must respect Remove Icon")
        #expect(BrowserSession.spaces(from: session.snapshot())?.first?.groups.first?.hasUserChosenIcon == true)
    }
}

/// Builds real `.ico` and PNG bytes in memory, so the decoder is exercised
/// against the actual container format rather than a stand-in.
private enum ICOFixture {
    enum Channel: Int { case red = 0, green = 1, blue = 2 }

    struct MissingImage: Error {}

    static func png(side: Int, channel: Channel) throws -> Data {
        let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        guard let context else { throw MissingImage() }
        var components: [CGFloat] = [0, 0, 0, 1]
        components[channel.rawValue] = 1
        context.setFillColor(CGColor(red: components[0], green: components[1], blue: components[2], alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))

        guard let image = context.makeImage() else { throw MissingImage() }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.png.identifier as CFString, 1, nil
        ) else { throw MissingImage() }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw MissingImage() }
        return output as Data
    }

    /// An ICO directory wrapping PNG payloads, which is the modern form of the
    /// format and the one `news.ycombinator.com` serves.
    static func make(_ images: [(side: Int, channel: Channel)]) throws -> Data {
        let payloads = try images.map { try png(side: $0.side, channel: $0.channel) }
        var data = Data()
        data.append(contentsOf: [0, 0, 1, 0])
        data.append(contentsOf: withUnsafeBytes(of: UInt16(images.count).littleEndian, Array.init))

        var offset = 6 + 16 * images.count
        for (index, payload) in payloads.enumerated() {
            let side = images[index].side
            data.append(contentsOf: [UInt8(side % 256), UInt8(side % 256), 0, 0])
            data.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian, Array.init))
            data.append(contentsOf: withUnsafeBytes(of: UInt16(32).littleEndian, Array.init))
            data.append(contentsOf: withUnsafeBytes(of: UInt32(payload.count).littleEndian, Array.init))
            data.append(contentsOf: withUnsafeBytes(of: UInt32(offset).littleEndian, Array.init))
            offset += payload.count
        }
        for payload in payloads { data.append(payload) }
        return data
    }

    static func type(of data: Data) -> String? {
        CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceGetType($0) as String? }
    }

    static func pixelSize(of data: Data) throws -> CGSize {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw MissingImage() }
        return CGSize(width: image.width, height: image.height)
    }

    /// Which of red, green or blue dominates the decoded image — the only way
    /// to tell which image inside a multi-size `.ico` was actually chosen.
    static func dominantChannel(of data: Data) throws -> Channel {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw MissingImage() }
        var pixel: [UInt8] = [0, 0, 0, 0]
        let context = pixel.withUnsafeMutableBytes { buffer in
            CGContext(
                data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        }
        guard let context else { throw MissingImage() }
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let channels = pixel.prefix(3)
        guard let index = channels.indices.max(by: { channels[$0] < channels[$1] }),
              let channel = Channel(rawValue: index) else { throw MissingImage() }
        return channel
    }
}
