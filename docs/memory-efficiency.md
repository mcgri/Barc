# Memory efficiency and profile hibernation

Barc hibernates eligible pages after their profile has been out of view for one minute. Change this under Settings → General → **Hibernate inactive profiles after**. Choices are Never, 1 minute, 5 minutes, and 10 minutes. This is separate from the ordinary background-tab timeout, which defaults to 10 minutes.

The clock starts when the profile leaves view. Reading a page for a long time does not use up its background grace period. Switching between Spaces that share a profile keeps that profile active. Shared Favorites are evaluated once. Visible split panes, floating windows, and other visible pages protect their profile.

Checks run on one coalesced timer and on application activation. Sleeping begins after the threshold when the main run loop can service the check; App Nap and a busy interface can defer it. Barc does not prevent App Nap to meet a deadline.

## What stays awake

Automatic hibernation defers for:

- Edited forms, selected files, and rich editors whose saved state is uncertain, including child frames.
- Calls, camera/microphone capture, screen sharing, live connection or capture setup, and picture-in-picture.
- Uploads, active downloads, and failed downloads that still need their original page to resume.
- Keep Awake and never-sleep site rules, locked tabs, and automatic-refresh dashboards.
- Loading documents, document viewers, and pages whose safety check is unavailable or incomplete.

These protections also apply under critical memory pressure. Every loaded pane in a hidden split must qualify before the group is unloaded. A switch back during inspection cancels the stale unload.

Normal background media still follows the existing pause-on-switch behavior. Calls and picture-in-picture have an exception so their audio can continue while another profile is in view.

Form detection keeps edit state in memory and sends boolean activity information. It does not collect or persist field contents. A submit event alone does not prove an editor saved its draft, so edit protection remains until navigation. Some pages will consequently stay awake longer. The existing Keep Awake and per-site rules remain available.

## Sleeping and waking

Hibernation releases a page's live web view while retaining its sidebar entry and WebKit interaction state. It also captures scroll coordinates as a fallback for interaction state that has not yet caught up with a recent scroll. That fallback is restored only to the matching document URL. Changing profile identity clears both kinds of restoration state.

Only the selected page or visible split wakes on return. Browser profile storage remains the same object, including private stores and session-only cookies. Hibernation does not delete website data, replace profile identities, clear login storage, or stop WebKit processes.

Hidden side panels use the same safety checks and timeout. Closing the panel UI does not load other panel pages. Eligible cached panel pages unload and restore on demand. Drafts and the scratchpad remain resident. Explicitly removed panel entries are pruned from the cache.

## Other changes

- Website visibility stays accurate, allowing sites and WebKit to reduce background work.
- Video helpers examine added elements rather than rescanning the entire document after mutations. Overlay polling is limited to visible YouTube documents. Autofill uses delegated focus handling.
- Transient loading/progress events update the interface without requesting session serialization.
- Debounced session encoding, hashing, and writes use a serial background queue. Explicit saves and quitting flush queued checkpoints before writing the latest state. Writes remain atomic and private.
- Preview caching is limited by decoded byte cost and image count. Pressure trims previews; closed tabs release theirs; overlapping captures do not repopulate a cleared cache.
- Unloaded tabs have no automatic-reload timer. A configured dashboard remains protected from automatic hibernation.
- Resource sampling reads shared processes once per interval, uses physical footprint consistently, prunes old sampling state, and labels unavailable values. Registered auxiliary pages and detectable networking helpers contribute to measured totals. Shared process allocations are not exact per-tab allocations.

## Verification

The tests exercise real web views and a loopback-only HTTP/download server. Coverage includes form edits, rich editors, file inputs, cross-origin frames, actual WebRTC peer objects, muted native capture state, capture-track lifecycle, upload requests, a real unfinished download, session-only and persistent cookie restoration, scroll restoration, activation races, shared Favorites, protected splits, panel retention, preview budgets, session-write ordering, and old-view deallocation.

The ordinary suite includes a real one-minute scheduler test and repeated restore/unload cycles. Run it with:

```sh
swift test
```

A separate 30-minute soak is opt-in. It uses three disposable private profiles, fictional session cookies, and touched memory buffers. It records known-process physical footprint and live-view counts while cycling through real idle periods. It does not use the installed browser's session. After building tests, run:

```sh
BARC_MEMORY_SOAK=1 swift test --skip-build --filter MemorySoakTests
```

Results are written to `_local/memory-soak-result-2026-10-26.json`. Process caches are managed by WebKit, so a released view need not make its process disappear immediately. The soak measures actual footprint rather than assuming a removed reference equals a particular RAM saving.
