# Sidebar batch findings

2026-10-25. Scope: the five areas in SIDEBAR-TODO.md, plus search. Current source: `59ef390`, including interrupted sidebar motion and display-change context corrections. Current release: **build 243**. Full Arc parity remains unproven.

## Completed fixes

| Area | Changes |
| --- | --- |
| Search position | The opening establishes a fixed top anchor. Changing results grows the panel downward. Resizing clamps the input and leaves room for a result without a later keystroke moving it. Reopening preserves the installed overlay. |
| Search interaction | Existing suggestions remain visible while a query loads, with their actions disabled until fresh results arrive. Return resolves the current typed text during loading. Late results are rejected after a new opening or edit. Marked text stays with the input method. |
| Search ranking | Address-prefix matching uses the destination address rather than the Space-prefixed subtitle. Shared Favorite tab identifiers appear once. Separate pages with the same URL remain separate destinations. |
| Split names | Whole-unit rename and reset use the inline editor. Named splits display one caption and icon. Pane choices remain available through the unit menu. Names and icons follow complete-unit transfers. |
| Favorite names | Rename operates on the captured profile and destination. Compound Favorite names update existing layouts in sibling Spaces. Removed destinations cannot be recreated by a stale callback. |
| Menus | A single split row receives unit actions, including rename, icon, mute, separate, duplicate, move, pin/archive and individual pane actions. Multiple selected rows retain the selection menu. |
| Transfers and keyboard | Cross-Space drags carry an owning-Space identifier and expand complete workspace splits. Cross-profile copies clear opaque page state. Numbered selection counts each visible split once and honors collapsed sections. |
| Appearance | Search sizing, selection and focus are checked in both appearances. Named-unit icons refresh their appearance. Changed controls keep the existing sidebar metrics and motion behavior. |
| Live folders | Option handlers survive menu construction. Pause, refresh and recovery are connected. Old configurations still decode. Results from an obsolete configuration cannot prune current contents. Custom session stores use separate live-folder side tables. |
| GitHub live folders | Signed-in mode reads GitHub pages inside the owning profile's website store. Missing authentication, unknown markup and incomplete responses are errors. Existing contents are preserved on errors. Explicit Arc live-folder markers can be adopted; existing matching pages are reused. |

## Earlier batch verification

- The implementation batch preceded the test phase. Failures found during verification were corrected together, then the combined checks and full suite were rerun.
- Final full suite: **2,315 tests in 364 suites passed**, 90.521 seconds.
- Focused combined search/sidebar checks: 57 tests in 6 suites passed, 3.136 seconds.
- Geometry checks measure the input frame across empty, short and long result lists, repeated openings, resizing, New Tab, Command-L, split chooser and both appearances. Anchored address editing remains covered by its existing native tests.
- A native app check found a split-menu focus issue. Unit actions now wait until menu tracking ends before presenting an editor or popover, and an additional regression test covers the deferred action.
- Other checks exercise actual native menus, split/Favorite ownership, complete-unit transfers, retained option handlers, pause persistence and the actual GitHub extraction script in a local WebKit document.
- The GitHub parser check uses the observed embedded-page format. It does not establish access to a private GitHub account.
- Saved session, preferences, boosts and live-folder files matched their pre-test hashes exactly.
- Arc's windows were left untouched. No social or sharing features were added. Nothing was pushed remotely.

Earlier release: **build 228**, `0.1.64-130-g50f447e`, compiled in 71.53 seconds. Strict signature verification passed. The final bundle is `build/Barc.app`.

The actual browser UI was inspected in separately identified review copies with local sample tabs. Search stayed at the same input position as the list changed between four recent tabs, one result and nine results; light and dark appearances were inspected. The final build's native split-menu Rename opened the focused editor and committed a whole-unit name. Review copies were closed afterward. The real saved session, preferences, boosts and live-folder files still matched their pre-test hashes exactly.

The app review required one menu-focus repair after the initial release check. The final full test run and final build include that repair. Search captures precede that repair; the search implementation was unchanged by it.

## Search follow-up: build 231

- The result list now scrolls. It retains up to fifteen local matches plus the literal search and engine predictions; keyboard selection can reach rows below the viewport without moving the input or changing the selected destination on resize.
- DuckDuckGo, Google and Bing predictions arrive after local results. Existing local rows and their selection remain in place. The selected engine supplies the destination; private Spaces keep predictions local, and cancelled or stale results cannot replace current text.
- Keyword + Tab enters a named site-search mode. Return uses that site's query template, and Backspace leaves an empty mode. Plain keyword searches such as `g cats` also use the configured engine when a result is selected. A Site Search command opens the Search settings pane.
- Every opening is bound to its Space/profile. Switching Spaces closes an open New Tab launcher as well as the existing URL/split modes.
- Ordinary web searches no longer select unrelated commands through scattered letters in their descriptions. Commands use word/phrase prefixes and explicit aliases; the existing `ntb` alias remains available.
- Google responses honor their declared character set. A live accented query returned Latin-1 bytes, and the corrected native app displayed the accented predictions.

Final combined suite: **2,329 tests in 366 suites passed**, 94.566 seconds. Final release compilation: 71.94 seconds. Version: `0.1.64-133-g548a04b`. Strict signature verification passed.

Native sample-data inspection verified predictions from all three supported engines, 22 accessible rows in a long list, keyboard access to the final row, site-mode entry and navigation, Backspace exit, a real search destination on Return, Space-change closure, and dark appearance. Native marked-text composition, delayed prediction ownership and private-mode request suppression are covered by the combined tests. Source windows were not operated, and saved session/preferences/boost/live-folder files still match the pre-batch hashes exactly.

The implementation follows the [documented Arc site-search shortcut](https://resources.arc.net/hc/en-us/articles/20855018192791-Site-Search-Directly-Search-any-Website). Built-in prediction endpoints are checked against the [public engine definitions](https://chromium.googlesource.com/external/search_engines_data/+/refs/heads/main/definitions/prepopulated_engines.json). The actual app review found a command-ranking problem; the final suite/build include that correction.

## Search interactions: build 234

- One physical sidebar click now dismisses search before AppKit dispatches the original event. New Tab opens immediately, a Space button switches immediately, and a tab's context menu opens from the first right-click. Clicks inside the panel stay with the editor; page clicks keep their existing dismissal behavior.
- Compact mode keeps the sidebar available during the click handoff, then releases the temporary hold. This fixes the additional native-review failure where dismissing search started hiding its intended click target.
- Literal searches, engine predictions and their input previews keep magnifying glasses after an engine's page favicon has loaded. Actual page/tab suggestions retain favicons.
- Ordinary queries such as `weather?`, `cats & dogs`, `why: now?` and `C# tutorial` are eligible for predictions. Default-engine requests exclude credentials, URL queries/fragments/ports, secure paths and local schemes. A selected keyword/site mode explicitly searches its term through that engine. This uses [Chromium's published privacy distinction](https://github.com/chromium/chromium/blob/main/components/omnibox/browser/search_provider.cc) with Barc's navigation classification; it does not claim Chromium's complete input parser.

Final combined suite: **2,334 tests in 367 suites passed**, 94.434 seconds. The suite includes input-position checks, original pointer event routing, panel/page/foreign-window boundaries, the real compact-window New Tab target, available engine icons and punctuation/address eligibility. A boundary failure found during verification was corrected by intersecting native visible rectangles with actual sidebar bounds.

Final release: **build 234**, `0.1.64-136-g5db18d7`, compiled in 71.47 seconds. Strict signature verification passed. The bundle is `build/Barc.app`.

Native review in build 233 confirmed one-click expanded New Tab, an immediate sidebar context menu, a physical Space switch, predictions for questions/ampersands, and magnifying glasses after the DuckDuckGo page favicon loaded. Both appearances were inspected. That review exposed the compact handoff issue; build 234 corrects it, and its one-click New Tab was then verified with the pointer in both populated Personal and empty Work Spaces. Search input remained at its opening position as result counts changed. The search rendering and prediction changes are unchanged between these two builds.

All review copies are closed. Saved session, preferences, boosts and live-folder files still match the pre-batch hashes exactly. Arc's windows were untouched. No social/sharing features, remote push or hosted environment changes were made.

## Sidebar navigation and search destinations: build 237

- Next/previous tab now uses sidebar visual order rather than creation/storage order. Open Favorite tiles come first, each workspace split occupies one destination, and a named split retains its name in the numbered menu. Collapsed Pinned entries retain a path back into the visible list.
- Numbered menus and their actions use the same list. Favorites are included by default; a Shortcuts checkbox can exclude them. Explicit numbered selection can open an unopened Favorite, while ordinary cycling visits open destinations. This follows the default inclusion described in [Arc's October 6, 2022 notes](https://resources.arc.net/hc/en-us/articles/20498417809815-Arc-for-macOS-2022-Release-Notes).
- Command-Option-Up/Down traverses tabs, matching [Arc's documented sidebar-order shortcut](https://resources.arc.net/hc/en-us/articles/25619402657303-How-Do-You-Switch-Between-Tabs-Quickly-on-Arc-Desktop). Space traversal uses the horizontal arrow pair. The dispatcher handles these before page key handling, ignores native Function/Numeric Pad/Caps Lock flags, and respects remapped, cleared and chord bindings. Horizontal Space-arrow fidelity still needs a source reference.
- Google `NAVIGATION` and `PERSONALIZED_NAVIGATION` suggestions now become validated HTTP/HTTPS destinations, with their optional descriptions. The list avoids repeating a destination already represented by a local tab/history row. Query predictions remain searches with magnifying glasses. The protocol distinction is documented in [Chromium's suggestion parser](https://github.com/chromium/chromium/blob/main/components/omnibox/browser/search_suggestion_parser.cc).
- Space suggestions now say `Focus on …`, remain available for the current Space, and precede a similarly named website in the saved source case. The current-Space behavior and priority follow the existing frozen source evidence; they do not establish complete Chromium ranking parity.

Combined suite: **2,344 tests in 369 suites passed**, 96.072 seconds. The final modifier-mask normalization was then checked with **39 shortcut/sidebar tests in 9 suites**, 0.635 seconds. These cover native arrow flags and remaps, visual order, split units, numbered menu labels/selection, unopened Favorites, the Shortcuts preference, provider descriptions, unsafe navigation rejection, deduplication and direct Return destinations. The broader suite was not rerun after that final normalization; the focused suite covers its changed shortcut path.

Final release: **build 237**, `0.1.64-139-g3fefe81`, compiled in 71.78 seconds. Strict signature verification passed. The bundle is `build/Barc.app`.

Native review found that menu traversal worked while modified arrows did not act with page focus. The dispatcher correction is included in the final build. Build 237 then verified Command-1 opening a Favorite, Command-Option-Down moving to the first workspace row, Up returning to the Favorite, Right/Left switching Work/Personal, Command-7 selecting the named split, and one Down press wrapping from that complete split to the Favorite. The final Google website suggestion displayed a globe, previewed `github.com`, and Return opened GitHub directly. Typing the current Space name selected `Focus on Personal` first. The rendered result list was inspected.

Both owned review copies are closed. Saved session, preferences, boosts and live-folder files still match their pre-batch hashes exactly. Arc's windows were untouched. No social/sharing features, remote push or hosted environment changes were made.

## Favorite drag and transfer: build 239

- Favorite tiles now start native drags using a stable Favorite identifier and owning Space. Pointer clicks activate on release; crossing the drag threshold starts a drag. A drag holds the compact sidebar open.
- A Favorite can move into Pinned, Today, a folder or a compatible split. Complete split units retain their name, icon, layout and remembered pane. Moving removes the shared Favorite; copying keeps it and creates independent workspace pages.
- Cross-profile transfers recreate pages in the destination profile and clear opaque page state. Unopened Favorites can transfer from their saved metadata without loading their pages. Stale identifiers, protected destinations, invalid selections and self-split targets are rejected before mutation.
- The Favorites strip accepts complete multi-row selections, expands split units, validates capacity before changing anything and supports native tile reordering. Space icons accept complete Favorite/workspace drops; the dock currently switches Spaces after a 300 ms drag hover. Exact Arc hover timing and default drop placement remain unverified.
- The interaction follows Arc's documented [Favorite drag-out behavior](https://resources.arc.net/hc/en-us/articles/19230755904151-Favorites-Top-Tabs-Across-Every-Space) and [Option-drag duplication](https://resources.arc.net/hc/en-us/articles/19231060187159-Pinned-Tabs-Tabs-you-want-to-stick-around). Favorite tiles use a dedicated native payload; legacy ordinary-tab payloads still refuse Favorite pages.

Combined suite: **2,360 tests in 370 suites passed**, 93.478 seconds. Verification corrected a reorder boundary error and a fixture that assumed invalid legacy records stayed Favorites; existing normalization preserves those records as workspace pages. A final preflight guard prevents dropping a Favorite into its own pane from removing its tile. All **17 Favorite drag regression tests passed** afterward in 0.344 seconds. The broader suite was not rerun after that final guard; the focused suite covers the changed path.

Final release: **build 239**, `0.1.64-141-gd5aa8bf`, compiled in 75.12 seconds. Strict signature verification passed. The bundle is `build/Barc.app`.

Native pointer review confirmed tile reordering, ordinary tile activation, a single Favorite dragged into Pinned, a complete named split dragged into Today, two selected workspace units dropped into Favorites, and a Favorite moved through a Space icon into a separate profile. These checks used local sample pages in a separately identified review copy. The tool rejected a modifier-only hold, and a concurrent Option-key chord did not establish a copy. **Physical Option-drag is unverified**; copy masks, source preservation and complete-unit copying passed the native delegate tests.

The review process is closed. Saved session, preferences, boosts and live-folder files still match the pre-batch hashes exactly. Arc's windows were untouched. No sharing/social features, remote push or hosted environment changes were made.

## Address classification and destination identity: build 241

- Bracketed IPv6 addresses now navigate, including ports. Loopback, unique-local, link-local and locally mapped IPv4 addresses use HTTP by default; an explicitly supplied scheme wins. IPv6 validation uses the system address parser.
- Pasted protocol-relative addresses and HTTP/HTTPS addresses with omitted slashes are normalized. URL path/query spaces are encoded while whitespace in the authority, invalid ports and malformed hosts are rejected. Slash-qualified intranet names, named local servers with ports and internationalized host labels are recognized. A bare email remains a search.
- Direct Return and ranked address rows use the same resolution. Default-engine prediction filtering recognizes the corrected private URL forms; explicit site/keyword searches retain their existing contract. A verification failure caught `file:/…` being mistaken for a slash-qualified intranet host. Known local schemes now retain their scheme before host classification.
- Local/provider deduplication shares one destination key. It preserves case in paths, query values and fragments, and preserves meaningful non-root trailing slashes. It retains the existing scheme/www web-display aliases and normalizes default ports and the root slash. Provider parsing no longer discards a second website solely because its path differs in capitalization.

These classification changes follow the published [Chromium input classifier](https://github.com/chromium/chromium/blob/main/components/omnibox/browser/autocomplete_input.cc), [URL fixup implementation](https://github.com/chromium/chromium/blob/main/components/url_formatter/url_fixer.cc) and [prediction privacy rules](https://github.com/chromium/chromium/blob/main/components/omnibox/browser/search_provider.cc). The resource-case correction follows [URI case-normalization rules](https://www.rfc-editor.org/rfc/rfc3986.html#section-6.2.2.1). This is an inference about Arc's Chromium behavior, not a version-matched Arc runtime comparison. Historical leading-`?` forced-query handling is deprecated in current Chromium; Barc's behavior remains unchanged pending a matching Arc reference.

Combined suite: **2,370 tests in 372 suites passed**, 94.576 seconds. A final boundary correction keeps an empty web port valid without treating an unknown custom path scheme as an intranet address. All **90 affected search/address tests in 11 suites passed** afterward, 0.809 seconds. These include actual window result routing, direct Return, unchanged input geometry, provider navigation, private URL filtering and destination identity. The broader suite was not rerun after that final correction.

Final release: **build 241**, `0.1.64-143-gb1772a0`, compiled in 74.32 seconds. Strict signature verification passed. The bundle is `build/Barc.app`.

Native review verified that `https:/example.com/a b` becomes the actual `https://example.com/a%20b` destination, an IPv6 input receives a globe/navigation result, and the input stays at the same position as four recent rows become two address/search rows and then seven query/prediction rows. The review used a separately identified copy with sample data, then closed it. Saved session, preferences, boosts and live-folder files still match the pre-batch hashes exactly. Arc's windows were untouched. No sharing/social features, remote push or hosted environment changes were made.

## Sidebar motion transitions: build 243

- Reduced motion now suppresses native table insertion/removal movement as well as cell entrance springs. A structure change still updates the list and selection immediately.
- The sidebar and dock observe the workspace's display-option notification through an observation object that unregisters with its owner. Enabling reduced motion cancels an active sidebar journey, removes its snapshots, resets its displacement and clears the switch/watchdog state. Cancelled or subsequent swipe events also restore rest immediately.
- Dock interpolation rebuilds its targets at resting size when motion becomes reduced. A stationary hovered icon also resets on notification; re-enabling motion retains the same click targets and pointer position.
- Reduced presence operations remove their earlier presence animation and reset the model transform before applying the requested final visibility. Arrival/departure callbacks still complete.
- A preference-only redraw preserves scroll position, multi-row selection and the active page. Combined verification exposed that table reload cleared selection; restoration now suppresses page-selection side effects and refreshes the row appearance afterward.

The observation uses Apple's documented [workspace display notification](https://developer.apple.com/documentation/appkit/nsworkspace/accessibilitydisplayoptionsdidchangenotification) and [Reduce Motion property](https://developer.apple.com/documentation/appkit/nsworkspace/accessibilitydisplayshouldreducemotion). The automated checks post the native notification and use a test override for the setting. They do not establish that a real system preference toggle has been exercised.

The existing frozen unnamed-split comparison supports the current row-height, inset and caption-placement choices. Its one-pixel inner-corner threshold difference and incomplete named-split reference remain explicit; this batch makes no new exact-pixel or source-animation-timing claim.

Combined suite: **2,379 tests in 373 suites passed**, 91.327 seconds. All source changes and the selection correction are included. Checks cover observer lifetime, interrupted presence operations, a moving and stationary dock, cancelled/subsequent swipe events, an in-flight Space switch, viewport/multi-selection preservation and reduced row insertion/removal. A failing fixture was also corrected to compare the original tab identities rather than assume the fixture began empty.

Final release: **build 243**, `0.1.64-145-g59ef390`, compiled in 74.02 seconds. Strict signature verification passed. The bundle is `build/Barc.app`.

Native release review verified ordinary Space switching and return, New Tab with a local site-search destination, tab insertion/removal and the settled sidebar rendering. It used a separately identified copy with local sample pages; that copy is closed. Saved session, preferences, boosts and live-folder files still match the pre-batch hashes exactly. Arc's windows were untouched. No sharing/social features, remote push or hosted environment changes were made.

## Remaining to-do list

These are remaining differences or verification gaps within the requested areas. They are not claims of completed parity.

### Search

- [ ] Compare ranking against Arc across a larger saved query set. The local ranker has corrected prefix behavior, but exact Chromium scoring is not established.
- [ ] Compare remaining partial URL classification against a version-matched Arc reference. IPv6, pasted web-scheme fixup, path/query spaces, internationalized hosts, email intent and private URL filtering now have regression coverage. Unknown-TLD heuristics, external schemes, every intermediate input and the source's leading-question-mark behavior remain unverified.
- [ ] Compare richer provider result types and ranking metadata with Arc. Plain query and typed website predictions are implemented. Exact Chromium scoring, rich entity/answer annotations, complete provider metadata and source-specific URL-label formatting are not reproduced.
- [ ] Check Japanese/Chinese composition with a real input method. Native marked-text composition is now exercised with real AppKit text-input APIs; a human input-method session has not been observed.
- [ ] Compare placement and truncation during full-screen transitions and at unusually large accessibility text sizes. Ordinary resizing and both appearances are covered.

### Names, menus and transfers

- [ ] Compare a named split's precise typography, icon spacing, hover controls and menu ordering against a saved Arc reference. The available reference does not establish every named-unit detail.
- [ ] Complete a physical Option-drag comparison for Favorites, including source cursor, drag image and motion. Native pointer review now covers Favorite drag-out moves, and native delegate tests cover copy behavior and profile isolation.
- [ ] Check remaining modifier-drag combinations and cross-window gestures with the pointer. Common Favorite moves, complete multi-row drops and a cross-profile Space-icon drop are verified; every modifier/window combination is not.
- [ ] Compare the source's Space-icon hover delay and default drop placement from saved evidence. Barc currently switches after 300 ms and places a dock transfer in Today; exact source equivalence is unverified.
- [ ] Compare the remaining per-shortcut Favorite-inclusion and ninth-item options against the source. The documented default inclusion, visual-order cycle, named-unit numbering and actual modified-arrow dispatch are implemented and verified.
- [ ] Verify the source's Space-arrow defaults from a saved reference. Barc uses horizontal Space traversal to keep the documented vertical tab pair distinct; exact source-default equivalence for the horizontal pair is not yet established.

### Appearance and motion

- [ ] Compare animation timing, blur/material strength and grain side by side from saved captures. Both appearances render, but exact perceptual parity is not established.
- [ ] Check reduced-motion behavior with the macOS preference enabled during ordinary use. Build 243 covers interrupted motion, native notification delivery, row updates and context preservation in automated native-view checks. An actual system preference-toggle session remains unverified.

### Live folders

- [ ] Verify a private GitHub folder while signed into the intended profile. This batch verifies parsing, profile routing and failure handling without operating the user's accounts.
- [ ] Recover or reselect the original GitHub filters. Arc's saved sidebar data identifies GitHub live folders but does not contain enough account/filter settings to recreate those choices exactly.
- [ ] Confirm GitHub pagination and error/recovery screens against an authenticated account with multiple pages of results. Unknown or partial data currently preserves existing folder contents and reports an error.
- [ ] Review older imported static GitHub groups individually before enabling live updates. Existing groups expose an explicit enable action rather than acquiring new background behavior on launch.
