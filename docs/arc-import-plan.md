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
5. Import saved website passwords through Arc's Safe Storage key into Barc's encrypted local vault. Protect the vault's random encryption key with one macOS Keychain item, so unlocking 148 credentials does not require 148 approvals. Namespace records by destination identity, preserve distinct source records, and use that identity for password lookup, saving and management. Keep prior per-login Keychain items untouched, with noninteractive reads only. macOS may request approval for Arc's key; denial must leave the non-secret import available and produce an honest result. Cache successful source-key access only for the current import window and clear it on close or source replacement.
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

All 1,880 tests pass. A focused run of 19 tests also passes with real synthetic Keychain reads and writes, one vault key for 148 encrypted credentials, empty and named usernames, custom ports, profile separation, newer-value preservation and nameless-cookie reporting. The vault release build is in progress. Prior release signatures and bundled LICENSE and NOTICE checks passed.

The native Settings flow has been exercised against private snapshots of the owner's six Arc profiles. Independent checks confirm:

- 61 sidebar tabs, five folders, 20 favourites and 952 archived web tabs, including their source mapping, names, hierarchy, order, colours and selected-tab mapping.
- 105,990 supported history visits, including source visit IDs, URLs, titles and dates, with no duplicate history ledger rows after repeating the import.
- Three saved addresses, 463 download records and 19 shared search shortcuts. Three detected default-search choices were restored; three unresolved choices kept the existing destination setting.
- 28,814 retained local-storage values matched the repeated source snapshot. One different existing value was preserved. Three writes hit WebKit's quota, and 2,249 partitioned or unsupported values were skipped and reported.
- Relaunch preserved all imported tabs, archives, identities, folders, favourites, appearance, search choices and Space order. The original unrelated Space was retained.

The first protected native pass verified 131 password contents and 7,745 supported cookie contents through the destination APIs. All 148 password records independently match the source's host, username, protocol, port and scoped Keychain path. The remaining 17 password readbacks exposed macOS omitting the account attribute for an empty username. A failing native regression test reproduced this, and the corrected reader passes it without confusing empty and named accounts.

After a normal quit, all 5,256 persistent cookies remained on disk with matching source names, domains, paths, Secure/HttpOnly flags and expiry dates. The 2,489 session-only cookies were not written to disk. The importer preserves that lifecycle rather than extending it. Ten nameless source cookies cannot be represented by WebKit's public cookie API; the report now identifies this specific limit.

The corrected per-login reader verified the first four profiles, but macOS's per-item application access controls produced repeated prompts after the executable changed. That run was stopped. Password storage now uses one Keychain-protected encryption key and an authenticated encrypted local file, with profile-scoped records. Tests cover 148 records with one key lookup, restart, cross-instance updates, empty usernames, encryption, tampering, denied access and retained data. Native verification of all 148 password values, the repeated import and reopening with this vault remains required before owner-data acceptance is complete.

Additional regression coverage includes consistent WAL snapshots, source immutability, cookie domain hashes and unsupported encryption, conflicting same-host credentials, shared profile Spaces, unpaired UTF-16 strings, LevelDB manifest replay and tombstones, empty selection, concurrent imports and interrupted writes. Bookmark recovery checks nested folders and exact creation times. Arc's extended-sRGB colours are mapped into the destination gamut, and selected source Space order is preserved across profile-by-profile transfer.
