import Foundation

enum ArcSupplementReader {
    struct Contents: Sendable {
        var addresses: [AutofillIdentity] = []
        var searchEngines: [SearchEngine] = []
        var defaultSearchEngineID: String?
        var downloads: [DownloadRecord] = []
        var unsupportedSearches = 0
        var genericFormValues = 0
        var unsupportedAddresses = 0
        var sourceDownloads = 0
    }

    static func read(_ profile: URL, sourceID: String, profileName: String, profileKey: String) throws -> Contents {
        var output = Contents()
        let web = profile.appending(path: "Web Data")
        if FileManager.default.fileExists(atPath: web.path) {
            let db = try SQLiteDatabase(readingOnly: web.path)
            let tables = Set(try db.query("SELECT name FROM sqlite_master WHERE type = 'table';") { $0.text(0) ?? "" })
            if tables.contains("addresses"), tables.contains("address_type_tokens") {
                let columns = Set(try db.query("PRAGMA table_info(addresses);") { $0.text(1) ?? "" })
                let label = columns.contains("label") ? "label" : "''"
                let addresses = try db.query("SELECT guid, \(label) FROM addresses;") { (id: $0.text(0) ?? "", label: $0.text(1) ?? "") }
                let tokens = try db.query("SELECT guid, type, value FROM address_type_tokens;") { (id: $0.text(0) ?? "", kind: Int($0.integer(1)), value: $0.text(2) ?? "") }
                for address in addresses {
                    let values = Dictionary(tokens.filter { $0.id == address.id }.map { ($0.kind, $0.value) }, uniquingKeysWith: { first, _ in first })
                    let lines = (values[77] ?? "").components(separatedBy: .newlines)
                    output.addresses.append(AutofillIdentity(
                        id: ArcImportID.uuid(sourceID + "/address/" + address.id), label: address.label.isEmpty ? "From Arc · " + profileName : address.label,
                        givenName: values[3] ?? values[7] ?? "", familyName: values[5] ?? "", email: values[9] ?? "", phone: values[14] ?? "",
                        organization: values[60] ?? "", street: values[30] ?? lines.first ?? "", street2: values[31] ?? lines.dropFirst().joined(separator: "\n"),
                        city: values[33] ?? "", state: values[34] ?? "", postalCode: values[35] ?? "", country: values[36] ?? ""))
                }
            } else if tables.contains("autofill_profiles") {
                output.unsupportedAddresses = Int(try db.query("SELECT COUNT(*) FROM autofill_profiles;") { $0.integer(0) }.first ?? 0)
            }
            if tables.contains("autofill") {
                output.genericFormValues = Int(try db.query("SELECT COUNT(*) FROM autofill;") { $0.integer(0) }.first ?? 0)
            }
            if tables.contains("keywords") {
                let columns = Set(try db.query("PRAGMA table_info(keywords);") { $0.text(1) ?? "" })
                let post = columns.contains("search_url_post_params") ? "search_url_post_params" : "''"
                let filter = columns.contains("prepopulate_id") && columns.contains("safe_for_autoreplace")
                    ? " WHERE prepopulate_id = 0 AND safe_for_autoreplace = 0" : ""
                for row in try db.query("SELECT short_name, keyword, url, \(post) FROM keywords\(filter);", row: {
                    (name: $0.text(0) ?? "", word: $0.text(1) ?? "", template: $0.text(2) ?? "", post: $0.text(3) ?? "")
                }) {
                    let template = row.template.replacingOccurrences(of: "{searchTerms}", with: "{query}")
                    guard row.post.isEmpty, template.components(separatedBy: "{query}").count == 2,
                          !template.replacingOccurrences(of: "{query}", with: "").contains("{"),
                          let url = URL(string: template.replacingOccurrences(of: "{query}", with: "test")),
                          let scheme = url.scheme, ["http", "https"].contains(scheme), let host = url.host(),
                          let home = URL(string: scheme + "://" + host) else { output.unsupportedSearches += 1; continue }
                    let id = "custom:" + ArcImportID.uuid("search/" + row.name + "/" + row.word + "/" + template).uuidString.lowercased()
                    output.searchEngines.append(SearchEngine(id: id, name: row.name, queryTemplate: template, homeURL: home, keyword: row.word.isEmpty ? nil : row.word))
                }
            }
            // Payment-card tables are deliberately never queried.
        }
        if let data = try? Data(contentsOf: profile.appending(path: "Preferences")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let provider = (json["default_search_provider_data"] as? [String: Any])?["template_url_data"] as? [String: Any],
           let name = provider["short_name"] as? String {
            output.defaultSearchEngineID = (SearchEngine.all + output.searchEngines).first { $0.name.lowercased() == name.lowercased() }?.id
        }
        let history = profile.appending(path: "History")
        if FileManager.default.fileExists(atPath: history.path) {
            let db = try SQLiteDatabase(readingOnly: history.path)
            let tables = Set(try db.query("SELECT name FROM sqlite_master WHERE type = 'table';") { $0.text(0) ?? "" })
            if tables.contains("downloads"), tables.contains("downloads_url_chains") {
                let columns = Set(try db.query("PRAGMA table_info(downloads);") { $0.text(1) ?? "" })
                let guid = columns.contains("guid") ? "guid" : "CAST(id AS TEXT)"
                let chains = try db.query("SELECT id, url FROM downloads_url_chains ORDER BY id, chain_index;") { (id: $0.integer(0), url: $0.text(1) ?? "") }
                var urls: [Int64: String] = [:]
                for row in chains { urls[row.id] = row.url }
                let rows = try db.query("SELECT id, \(guid), target_path, current_path, state, start_time, end_time, received_bytes FROM downloads;") {
                    (id: $0.integer(0), guid: $0.text(1) ?? "", target: $0.text(2) ?? "", current: $0.text(3) ?? "", state: $0.integer(4),
                     start: $0.integer(5), end: $0.integer(6), bytes: $0.integer(7))
                }
                output.sourceDownloads = rows.count
                for row in rows {
                    let path = row.target.isEmpty ? row.current : row.target
                    guard let text = urls[row.id], let url = ArcURL.parse(text), !path.isEmpty,
                          let startedAt = ArcProfileReader.chromeDate(row.start) else { continue }
                    let state: DownloadState = row.state == 1 ? .finished : row.state == 2 ? .cancelled : .failed("Interrupted in Arc")
                    output.downloads.append(DownloadRecord(id: ArcImportID.uuid(sourceID + "/download/" + (row.guid.isEmpty ? String(row.id) : row.guid)), sourceURL: url,
                        destination: URL(fileURLWithPath: path), state: state,
                        startedAt: startedAt,
                        finishedAt: row.end > 0 ? ArcProfileReader.chromeDate(row.end) : nil,
                        byteCount: row.bytes, importedFromArc: true, sourceProfileKey: profileKey, sourceProfileName: profileName))
                }
            }
        }
        return output
    }
}
