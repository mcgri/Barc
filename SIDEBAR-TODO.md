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
