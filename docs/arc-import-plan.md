# Arc import update

Status: built-in import implemented; final owner-data verification in progress.

## Goal

Provide a built-in, profile-aware Arc import in Settings → Import. A user chooses their Arc folder, reviews the detected profiles and data categories, and imports into Barc without running migration scripts or changing Arc.

The previous manual migration is reference material for Arc's actual file formats and the conversion limits. Personal data and test snapshots stay in ignored local files, never in the repository.

## Behaviour

1. Read a consistent private snapshot of the selected Arc folder. Include SQLite write-ahead logs, validate the copied databases, and fail clearly if files keep changing. Never open Arc databases for writing.
2. Detect all local Chromium profiles using `User Data/Local State` and Arc's Space-to-profile bindings. Parse Arc's alternating key/value arrays, nested folders, pinned tabs, ordinary tabs, per-profile favourites, Space order, names, colours, icons and archived tabs. Ignore stale sync replicas when the current local sidebar exists. Reject an unrecognised sidebar instead of returning an empty success.
3. Preview profiles and counts before importing. Create distinct destination identities for different Arc profiles. Preserve any shared profile relationship between Arc Spaces. Profiles without a sidebar Space still receive a destination Space. Preserve existing Barc Spaces and avoid duplicate imports on a second run.
4. Import complete history visit records and bookmarks, preserving dates and folders. Keep imported profile history separate in history views and suggestions. Do not use the generic importer's 20,000-page convenience limit.
5. Import saved website passwords through Arc's Safe Storage key and Barc's own Keychain APIs. Namespace them by destination identity, preserve distinct source records, and use that identity for password lookup, saving and management. macOS may request approval for Arc's key; denial must leave the non-secret import available and produce an honest result.
6. Import cookies into the matching live WebKit stores, preserving expiry, session status, Secure, HttpOnly and SameSite where WebKit supports them. Validate encrypted cookie domain hashes. Never combine different profiles or silently turn partitioned cookies into ordinary cookies. Count expired and unsupported records separately and verify the stored result.
7. Import supported local storage using a native reader and WebKit's own storage APIs. Import saved addresses, compatible search shortcuts and download records using the existing native models. Payment cards are excluded.
8. Produce a persistent result with per-profile counts, verification, skipped categories and reasons. Distinguish saved passwords from signed-in website sessions. Explain that server-bound sessions can require signing in again. Preserve Arc's original IndexedDB, tab-scoped storage, passkeys and extension data; report data that cannot be translated reliably rather than copying incompatible engine files or claiming it worked.
9. Keep the UI responsive, show progress, prevent concurrent imports, and persist the destination session before reporting completion. Cancellation before committing creates no imported Spaces. If a selected category fails after a partial import, retain the valid imported data and provide a retryable report without duplication.

## Implementation sequence

1. Source snapshot, inventory and sidebar parser with synthetic format fixtures.
2. Destination mapping, repeat-import handling and history/password isolation.
3. Profile readers, native cookie/local-storage conversion and supplementary data.
4. Preview, selection, progress and result UI in the existing Import pane.
5. Unit and integration tests, then import a fresh snapshot of the owner's Arc into Barc and verify the actual native result and relaunch persistence.

## Acceptance checks

- The owner's six Arc profiles are detected and mapped without mixing identities.
- Sidebar tabs, folders, favourites, archived tabs, names and ordering match an independent source inventory.
- Full history counts, saved password contents and supported cookie contents match source records, with values never written to logs or test fixtures.
- Two profiles with conflicting credentials/cookies for the same host remain separate. Shared Arc profile Spaces keep their intended shared identity, including after removing one of those Spaces.
- Repeating an import does not duplicate previously imported tabs, visits or saved password records, overwrite newer destination sessions, or change unrelated Barc data.
- Unsupported/encrypted formats, denied Keychain access, malformed metadata, WAL-backed databases and an interrupted import have explicit tested outcomes.
- The product flow works through native Settings, not just a test-only entry point. The imported session survives relaunch. Arc source files remain unchanged by the importer.
- Existing tests and the release app build pass. Legal notices remain included in the bundle.

## Verification in progress

The native Settings flow detects the owner's six profiles and has imported tabs, folders, favourites, archives, complete supported history, website data and supplementary records. Personal snapshots and aggregate audit results are kept in ignored local files.

The first native pass exposed two issues now covered by regression tests. Local builds need a login-Keychain fallback when their signing identity cannot use iCloud Keychain, and macOS requires reading login-Keychain passwords individually. Arc URLs also need careful escaping to preserve existing encoded query values. The corrected native retry is waiting for macOS approval to read Arc Safe Storage.

Additional tests cover WAL snapshots, source immutability, cookie domain hashes and unsupported encryption, same-host credential isolation, shared profile Spaces, unpaired UTF-16 strings, LevelDB manifest replay and tombstones, interrupted writes, empty selection, concurrent imports and repeat-import preservation.
