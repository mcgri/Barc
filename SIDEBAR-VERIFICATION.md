# Sidebar batch findings

2026-10-25. Scope: the five areas in SIDEBAR-TODO.md, plus search. Source implementation: `50f447e`, including the batch in `bf46c42`.

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

## Combined verification

- The implementation batch preceded the test phase. Failures found during verification were corrected together, then the combined checks and full suite were rerun.
- Final full suite: **2,315 tests in 364 suites passed**, 90.521 seconds.
- Focused combined search/sidebar checks: 57 tests in 6 suites passed, 3.136 seconds.
- Geometry checks measure the input frame across empty, short and long result lists, repeated openings, resizing, New Tab, Command-L, split chooser and both appearances. Anchored address editing remains covered by its existing native tests.
- A native app check found a split-menu focus issue. Unit actions now wait until menu tracking ends before presenting an editor or popover, and an additional regression test covers the deferred action.
- Other checks exercise actual native menus, split/Favorite ownership, complete-unit transfers, retained option handlers, pause persistence and the actual GitHub extraction script in a local WebKit document.
- The GitHub parser check uses the observed embedded-page format. It does not establish access to a private GitHub account.
- Saved session, preferences, boosts and live-folder files matched their pre-test hashes exactly.
- Arc's windows were left untouched. No social or sharing features were added. Nothing was pushed remotely.

Final release: **build 228**, `0.1.64-130-g50f447e`, compiled in 71.53 seconds. Strict signature verification passed. The final bundle is `build/Barc.app`.

The actual browser UI was inspected in separately identified review copies with local sample tabs. Search stayed at the same input position as the list changed between four recent tabs, one result and nine results; light and dark appearances were inspected. The final build's native split-menu Rename opened the focused editor and committed a whole-unit name. Review copies were closed afterward. The real saved session, preferences, boosts and live-folder files still matched their pre-test hashes exactly.

The app review required one menu-focus repair after the initial release check. The final full test run and final build include that repair. Search captures precede that repair; the search implementation was unchanged by it.

## Remaining to-do list

These are remaining differences or verification gaps, within the requested areas. They are not additional changes included in this batch.

### Search

- [ ] Compare ranking against Arc across a larger saved query set. The local ranker has corrected prefix behavior, but exact Chromium scoring is not established.
- [ ] Decide whether to add remote search predictions. The current search-engine destination and local results do not reproduce a search provider's complete prediction feed.
- [ ] Check Japanese/Chinese composition with a real input method. Marked-text guards are implemented; a human input-method session has not been observed.
- [ ] Compare placement and truncation during full-screen transitions and at unusually large accessibility text sizes. Ordinary resizing and both appearances are covered.

### Names, menus and transfers

- [ ] Compare a named split's precise typography, icon spacing, hover controls and menu ordering against a saved Arc reference. The available reference does not establish every named-unit detail.
- [ ] Complete a physical Option-drag and drag-out comparison for Favorites. Moving a shared Favorite across Spaces through the new workspace-transfer path is deliberately refused; workspace split transfers and copies are supported.
- [ ] Check all modifier-drag combinations and cross-window gestures with the pointer. Model/native drop checks cover ownership and complete-unit behavior, but not every physical gesture.
- [ ] Establish Arc's exact Favorite keyboard-cycle contract. Numbered visible workspace rows are corrected; a claim of identical Favorite traversal needs a reference capture.

### Appearance and motion

- [ ] Compare animation timing, blur/material strength and grain side by side from saved captures. Both appearances render, but exact perceptual parity is not established.
- [ ] Check reduced-motion behavior with the macOS preference enabled during ordinary use. Changed controls use the existing motion implementation; a physical preference-toggle session remains to be observed.

### Live folders

- [ ] Verify a private GitHub folder while signed into the intended profile. This batch verifies parsing, profile routing and failure handling without operating the user's accounts.
- [ ] Recover or reselect the original GitHub filters. Arc's saved sidebar data identifies GitHub live folders but does not contain enough account/filter settings to recreate those choices exactly.
- [ ] Confirm GitHub pagination and error/recovery screens against an authenticated account with multiple pages of results. Unknown or partial data currently preserves existing folder contents and reports an error.
- [ ] Review older imported static GitHub groups individually before enabling live updates. Existing groups expose an explicit enable action rather than acquiring new background behavior on launch.
