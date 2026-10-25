# Sidebar batch

Scope: the five remaining areas in the status report, plus search. Search stability is the priority. Arc must remain untouched. No sharing/social features or remote push.

Workflow: scan once, implement this batch without intermediate builds or tests, then test the combined result. Record the final findings in SIDEBAR-VERIFICATION.md, including any remaining differences.

## Search
- [x] S1. Keep the input row at a fixed opening position while results grow, shrink, or load; grow the panel downward.
- [x] S2. Keep existing rows visible during a query, but prevent Return or a click from running an obsolete result.
- [x] S3. Reject late results from an older opening, query, Space, or profile; preserve marked text and keyboard focus.
- [x] S4. Stabilize completion, selection, hover, Tab, arrows, Return, Escape, and repeat opening behavior.
- [x] S5. Fix address-prefix ranking of open tabs and remove duplicate cross-Space copies of the same profile Favorite.
- [x] S6. Check compact address, centered New Tab/location, split chooser, small windows, resizing, and both appearances together.

## 1. Split and Favorite naming
- [x] N1. Expose whole-unit rename and reset through native menus and the existing inline editor.
- [x] N2. Render a named workspace split as one named unit while preserving access to all its panes.
- [x] N3. Keep names/icons attached to the correct unit/profile through rename, detach, unpin, reopen, and stale callbacks.

## 2. Menus and interactions
- [x] I1. Give a split row unit actions rather than treating it as an arbitrary multiple-tab selection.
- [x] I2. Make Favorite menus and their name/icon actions operate on the whole destination.
- [x] I3. Audit complete-group drag transfers, cross-Space ownership, and detach/unsplit/restore behavior; fix concrete inconsistencies found in the scan.
- [x] I4. Make numbered keyboard selection count visible split rows once and respect collapsed sections.

## 3. Visual fidelity
- [x] V1. Match the supplied search reference's existing row styling and stable geometry; eliminate resizing-induced movement.
- [x] V2. Preserve measured sidebar spacing and honor reduced motion in changed controls; check light/dark, hover and selection states.

## 4. Search ranking and live folders
- [x] L1. Finish ranking corrections in S5 and connect existing live-folder options, refresh, pause, and recovery actions.
- [x] L2. Audit profile-bound GitHub authentication and imported live folders. Implement supported behavior without substituting anonymous public results for private activity; explicitly record any remaining authentication/import limit.

## 5. Combined verification and real use
- [x] T1. After all implementation changes, run the combined automated checks and fix actual failures as one verification phase.
- [x] T2. Build once, verify its signature, inspect rendered/native behavior in an isolated Barc run, and check saved user data.
- [x] T3. Compile one final findings list with completed fixes and concrete remaining differences. Do not claim exact parity from unit tests alone.

Combined automated checks passed: 2,315 tests in 364 suites, 90.521 seconds. The isolated app review is complete. Remaining source-comparison and account-dependent checks are recorded in SIDEBAR-VERIFICATION.md.

## Search follow-up batch

The preceding batch is verified in build 228. This batch closes remaining search differences using the saved Arc captures and [Arc's site-search instructions](https://resources.arc.net/hc/en-us/articles/20855018192791-Site-Search-Directly-Search-any-Website). Arc's windows remain untouched.

- [x] Q1. Keep the fixed input while retaining a scrollable full result list, with keyboard and accessibility access to matches below the viewport.
- [x] Q2. Show more local matches rather than cutting the candidate list at eight.
- [x] Q3. Fetch predictions from the selected supported engine after local results appear; preserve selection and discard cancelled, composed, closed or foreign-Space results.
- [x] Q4. Enter a configured site's search mode with keyword + Tab; show the active site, search that site on Return, and leave the mode with Backspace from an empty field.
- [x] Q5. Route typed keyword quick searches through their configured engine even when a suggestion is selected.
- [x] Q6. Close every command-bar mode when its owning Space/profile changes.
- [x] Q7. Run one combined verification phase after implementation, including actual native marked-text composition, scrolling, delayed predictions, site mode and ownership; then inspect a built app and update the remaining list.

Search follow-up combined suite passed: 2,329 tests in 366 suites, 94.566 seconds. Live anonymous endpoint checks passed for DuckDuckGo, Google and Bing; Google's declared Latin-1 responses are decoded correctly. Native release review is complete in build 231. Confirmed follow-up differences are consolidated in SIDEBAR-VERIFICATION.md.

## Search interaction batch

Scan complete. Implement these together before running the combined suite and owned app review. Arc remains untouched.

- [x] R1. Let native sidebar pointer clicks reach their controls while search is open. Dismiss before normal event dispatch, preserving the original click and context-menu/drag behavior.
- [x] R2. Keep search rows and the query preview as magnifying glasses after an engine favicon has been cached; preserve actual page favicons.
- [x] R3. Accept punctuation in ordinary question predictions. Keep address credentials, secure paths and local schemes out of default-engine requests; recognize an explicitly chosen site/keyword search.
- [x] R4. Run one combined automated/native review, check input stability and saved data, and consolidate remaining differences.

Final search-interaction verification: 2,334 tests in 367 suites passed in 94.434 seconds. Build 234, `0.1.64-136-g5db18d7`, passed strict signature verification. Native review confirmed the compact click correction in both a populated Personal Space and an empty Work Space. The same consolidated remaining list is maintained in SIDEBAR-VERIFICATION.md.

## Sidebar navigation and search destinations

Scan complete against saved query captures, native source evidence and Arc's published keyboard documentation. Implement this collected batch before testing.

- [x] D1. Cycle through sidebar visual order, including one destination per split and open Favorite tile; preserve escape from collapsed Pinned entries.
- [x] D2. Use the same visible destination order for numbered menus and their actions. Include Favorites by default, with a Shortcuts preference to exclude them.
- [x] D3. Match documented Command-Option-Up/Down tab traversal; separate Space traversal onto the horizontal arrow pair.
- [x] D4. Decode provider navigation suggestions as validated web destinations, retain provider descriptions, and deduplicate against existing local destinations. Query predictions remain searches with magnifying glasses.
- [x] D5. Match the saved Space-focus action wording, offer the current Space when named, and prioritize a matching Space action as observed in the source capture.
- [x] D6. After all implementation, run the combined tests and inspect one built app, then update the consolidated remaining list.

Sidebar destination verification: the combined suite passed 2,344 tests in 369 suites in 96.072 seconds. After the final modifier-mask normalization, all 39 shortcut/sidebar regression checks passed in 0.635 seconds. Build 237, `0.1.64-139-g3fefe81`, passed strict signature verification and the native keyboard, numbered split, Space-focus and provider-navigation checks. Remaining differences stay consolidated in SIDEBAR-VERIFICATION.md.

## Favorite drag and transfer batch

Scan complete. Arc documents dragging a Favorite into Pinned/Today to unfavorite it, and Option-drag duplication. Current tile sources do not start native drags; sidebar moves reject Favorites and the strip only reads the first selected tab. Implement this batch before verification.

- [x] F1. Add stable, owner-scoped native Favorite tile drag sources with click/drag separation and normal copy/move masks.
- [x] F2. Accept Favorite drops into Pinned, Today, folders and compatible split rows, preserving complete units and their name/icon/layout.
- [x] F3. Convert shared Favorites to workspace pages for a move; preserve the Favorite for a copy and maintain profile boundaries when crossing profiles.
- [x] F4. Handle Favorite reorder and complete multi-row drops into the Favorites strip, respecting source masks and validating the entire payload before mutation.
- [x] F5. Run combined model/native delegate checks and release pointer review, audit saved data and consolidate the remaining differences. Do not claim a physical Option-drag unless the tool can actually hold that modifier during a drag.

Favorite transfer verification: **2,360 tests in 370 suites passed**, 93.478 seconds. After a final self-split preflight guard, all **17 Favorite drag regression tests passed**, 0.344 seconds; the broader suite was not rerun after that guard. Build **239**, `0.1.64-141-gd5aa8bf`, compiled in 75.12 seconds and passed strict signature verification. Native pointer review confirmed tile reordering, click activation, single Favorite → Pinned, complete split → Today, complete multi-row → Favorites, and a cross-profile Space-icon move. Physical Option-drag remains unverified; native delegate checks cover copy semantics. Saved user data remained byte-for-byte unchanged. Remaining checks are consolidated in SIDEBAR-VERIFICATION.md.

## Address classification and destination identity batch

Scan complete. Compare Chromium's published omnibox/parser behavior while keeping Arc windows untouched. Implement all changes before combined verification. Leading-question-mark behavior remains unchanged until a version-matched Arc reference establishes it.

- [x] A1. Recognize valid bracketed IPv6 destinations, including ports, and use HTTP for local IPv6 ranges.
- [x] A2. Normalize pasted protocol-relative and incomplete explicit HTTP/HTTPS addresses without treating malformed authorities as navigable.
- [x] A3. Preserve spaces in URL paths/queries while rejecting whitespace in authorities; recognize explicitly slash-qualified intranet hosts and valid internationalized host labels.
- [x] A4. Apply the same corrected resolution to direct Return, ranked address rows and private-address prediction filtering.
- [x] A5. Preserve case-sensitive paths, query values and meaningful trailing slashes during local/provider destination deduplication, while retaining the existing web host/scheme aliases.
- [x] A6. Run the combined suite once implementation is complete, inspect one release app, audit saved data and consolidate remaining differences.

Address classification verification: **2,370 tests in 372 suites passed**, 94.576 seconds. After the final empty-port/custom-scheme correction, **90 affected search/address tests in 11 suites passed**, 0.809 seconds. The broader suite was not rerun after that final boundary correction. Build **241**, `0.1.64-143-gb1772a0`, compiled in 74.32 seconds and passed strict signature verification. Native release review confirmed pasted URL navigation, path-space encoding, an IPv6 address result and fixed input placement across four, two and seven results. Saved user data remained byte-for-byte unchanged. Remaining checks stay consolidated in SIDEBAR-VERIFICATION.md.

## Sidebar motion transition batch

The frozen unnamed-split measurements already match row height, inset, caption height and caption placement; named-split reference coverage remains incomplete. Scan found concrete reduced-motion transition defects. Implement the collected motion fixes before combined testing.

- [x] M1. Suppress native table insertion/removal movement as well as cell entrance springs when Reduce Motion is enabled.
- [x] M2. Reset a displaced or animating Space sidebar immediately on a reduced-motion preference notification or cancelled gesture; preserve the selected Space and its pages.
- [x] M3. Stop dock magnification and rebuild its resting sizes on a preference change, including changes during an active interpolation.
- [x] M4. Clear stale presence transforms when an arrival, slide or departure resolves without motion.
- [x] M5. Verify the changed transition paths and full suite together, review one built app, audit user data and update the consolidated remaining list. Keep a real macOS preference-toggle session distinct from tests that override the setting.

Motion transition verification: **2,379 tests in 373 suites passed**, 91.327 seconds, including every source correction in this batch. Build **243**, `0.1.64-145-g59ef390`, compiled in 74.02 seconds and passed strict signature verification. The isolated release review verified ordinary Space switching/return, New Tab, local navigation and tab insertion/removal. Reduced-motion transitions use native views and native workspace notifications with a test setting override; an actual macOS preference-toggle session remains unverified. Saved user data remained byte-for-byte unchanged. Remaining source comparisons and manual checks stay consolidated in SIDEBAR-VERIFICATION.md.
