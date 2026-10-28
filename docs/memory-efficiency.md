# Memory efficiency and profile hibernation

Barc hibernates eligible pages after their profile has been out of view for one minute. Change this under Settings → General → **Hibernate inactive profiles after**. Choices are Never, 1 minute, 5 minutes, and 10 minutes. This is separate from the ordinary background-tab timeout, which defaults to 10 minutes.

The clock starts when the profile leaves view. Reading a page for a long time does not use up its background grace period. Switching between Spaces that share a profile keeps that profile active. Shared Favorites are evaluated once. Visible split panes, floating windows, and other visible pages protect their profile.

Checks run on one coalesced timer and on application activation. Sleeping begins after the threshold when the main run loop can service the check; App Nap and a busy interface can defer it. Barc does not prevent App Nap to meet a deadline.

## What stays awake

Automatic hibernation defers for:

- Edited forms and rich editors, selected files, and editing activity whose state is uncertain, including child frames.
- Calls, camera/microphone capture, screen sharing, live connection or capture setup, and picture-in-picture.
- Uploads, active downloads, and failed downloads that still need their original page to resume.
- Keep Awake and never-sleep site rules, locked tabs, and automatic-refresh dashboards.
- Loading documents, document viewers, and pages whose safety check is unavailable or incomplete.

These protections also apply under critical memory pressure. Every loaded pane in a hidden split must qualify before the group is unloaded. A switch back during inspection cancels the stale unload.

Normal background media still follows the existing pause-on-switch behavior. Calls and picture-in-picture have an exception so their audio can continue while another profile is in view.

Form detection keeps edit state in memory and sends activity and protection codes. It does not collect or persist field contents. Existing editable text and controls populated by website scripts are not evidence of a draft. The guard tracks input, change and before-input events, taking a baseline before editing when available. This prevents saved task titles and descriptions from keeping an untouched application awake indefinitely. Unrelated custom events outside an editor do not mark the document as edited. Selected files remain protected without an input event.

A submit event alone does not prove an editor saved its draft. An initially empty composer that is cleared, or a form choice returned to its pre-edit state, can qualify again without navigation. Unfinished and detached drafts, unsaved deletions and uncertain editor state remain protected. A site that changes an editor solely through scripts without delivering editing events cannot be distinguished from a site loading saved data; the existing Keep Awake and per-site rules are available for these applications.

## Sleeping and waking

Hibernation releases a page's live web view while retaining its sidebar entry and WebKit interaction state. It also captures scroll coordinates as a fallback for interaction state that has not yet caught up with a recent scroll. That fallback is restored only to the matching document URL. Changing profile identity clears both kinds of restoration state.

Normally the old view deallocates immediately. System editing panels can retain a view after its tab releases it. A coalesced cleanup checks weak references after two seconds and replaces surviving, detached retired views with a blank document and blank history. The tab's saved restoration state and profile storage stay separate. A handoff to a new owner or reattachment revokes cleanup. If the blank state cannot be prepared, cleanup waits before retrying.

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
- Performance lists the app, networking, graphics, auxiliary content and tab processes separately. Tab process readings include WebKit and caches; an exact engine baseline or tab-only allocation is unavailable. Page details show the latest automatic-sleep protection reason.

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

## Pressure memory-cache cleanup

Warning and critical memory pressure also clear the memory-cache data type in live website data stores. Cleanup runs at most once per 60 seconds, shared across both pressure levels. Cookies and persistent website storage are unaffected.

## Allocator relief and UI layer audit, 2026-10-28

The auxiliary URLSession cache has a 4 MB memory budget in Standard and Reduced disk caching modes, and zero in Minimal caching mode. Standard retains its 500 MB disk budget. WebKit controls its own page memory cache. Reduced disk caching periodically removes disk cache files and does not guarantee zero disk writes. Minimal caching clears existing WebKit caches when applied but cannot prevent subsequent WebKit caching. The old `ramCacheCapacityMB` defaults key remains readable for compatibility; a repository-wide search found no Settings UI control using it.

MemoryRelief listens for warning/critical pressure and application resign-active events. It coalesces requests to once per three minutes and calls allocator pressure relief on a utility queue. It addresses freed-but-dirty pages, not live page objects. The motivating installed-app sample had 230 MB of WebKit Malloc with about 10 MB allocated. Relief is best effort and does not guarantee a particular footprint reduction.

The audit covered Sidebar, UI including CommandBar, Compact, GlanceOverlayView, TabOverview, and Toasts:

- Unchanged after review: CommandBar, compact sidebar plate, and toast shadows retain their original alpha-derived shapes. The proposed circular rounded shadow paths were reverted. CommandBar changes size during presentation; a static model-layer path would not track animated bounds. Compact changes width during reveal/layout, so keeping its original shadow avoids path/geometry synchronization risks. Toast appearance uses a layer transform rather than a bounds animation, but its backdrop, like the compact plate and CommandBar, uses continuous corners. A circular rounded path is not an exact match, and no visual comparison established that the difference was imperceptible. Retaining the original shadows preserves appearance and removes the new path construction entirely, including at empty or undersized bounds.
- Fixed: the overview removes its cards and tab references after dismissal, releasing card-owned decoded thumbnails even when its controller stays alive. Its backdrop was already detached on dismissal.
- Unchanged: sidebar transition stills are removed and released by `discardStill` and `discardNeighbourStill`. Full-window images are transient animation assets, not a persistent image cache.
- Unchanged: Glance already updates its card shadow path and detaches embedded pages. Its small confirmation-button shadow is not a large resizing surface.
- Unchanged: ToastPresenter already removes and releases dismissed toast views, including their visual-effect backdrops.
- Unchanged: compact mode reparents the real sidebar into a material plate; that hierarchy supports hover reveal and transition animation. Rebuilding it for every hide would affect focus, constraints and animation. The sidebar content is removed from the plate and returned to its normal slot when compact presentation ends; the empty overlay is hidden.
- Unchanged: CommandBar clears result rows on close but retains its small panel/control hierarchy for focus and anchor positioning. Removing its material independently would require rebuilding constraints during presentation. Sidebar popovers retain at most the most recent editor per category, with no full-window image cache.
- Unchanged: content containers, row highlights and reorder shadows already have paths. Layer-backed containers support clipping, tint and animation. Removing their layers could change rendering.
- Unchanged: TabSnapshotStore already captures at 480 points wide and limits decoded images to 24 MB and 30 entries. Overview cards can temporarily own images beyond that shared cache; dismissal now drops those owners.

Session loading reads the JSON Data and decodes a snapshot while those input bytes remain alive. The Data is local to SessionStore.load and is not retained by BrowserSession. A small autorelease pool now drains temporary decoder objects before constructing tab models. This does not eliminate the inherent input-plus-output overlap or change the persistence format. No measured saving is claimed for this change.

### Disposable launch measurement

A debug executable built under `/tmp/barc-build-a2` was packaged under `/tmp/barc-a2-app/Barc.app` with the distinct bundle identifier `io.github.mcgri.Barc.MemoryA2`. HOME and CFFIXED_USER_HOME pointed to `/tmp/barc-a2-app/home`. The synthetic JSON held 70 `about:blank` tabs, no interactionState blobs, and was 7,024 bytes after application checkpointing. This used no installed-app profile. MallocStackLogging was enabled; its instrumentation changes memory use and these values are not a release-build benchmark.

The first vmmap sample during launch reported 290.7 MB physical footprint and 432.6 MB peak. The WebKit malloc zone had 101.1 MB allocated and 144.3 MB dirty. At approximately 42 seconds its live allocation had fallen to 353 KB. At 2 minutes 3 seconds, vmmap reported 272.9 MB footprint, 432.6 MB peak, 353 KB live in WebKit Malloc and 20.4 MB dirty in that zone. The separate footprint tool reported 273 MB at that time. DefaultMallocZone had 230 KB allocated and about 9.3 MB dirty; stack logging routes much of the ordinary heap into its instrumentation zone, so that default-zone number cannot be compared directly with an uninstrumented run. The heap sample at about 24 seconds found 35.6 MB live across zones.

Seven compiled filter-list artifacts appeared under the disposable profile's WebKit ContentRuleLists directory. ContentBlocker starts all active lists, converts each source into rules, encodes JSON and passes it to WKContentRuleListStore compilation. This is a strong startup-peak candidate: a large WebKit allocation burst occurred even with a tiny session and no state blobs. The measurement does not isolate compilation from other WebKit initialization, so it is not proof of exclusive attribution. ContentBlocking was left to its owning workstream. Arc import, existing history/favicon databases and installed extensions were not exercised by this fresh-profile run. The autorelease-pool change was compiled after the measured executable was copied; no before/after saving is claimed.

Raw measurement files and the synthetic profile remain under `/tmp/barc-a2-app`; the disposable app was terminated after sampling. Both app and test-target compilation passed using `/tmp/barc-build-a2`; no test suite was run.

## Background memory limits

Settings → General → **Background tab memory limit** offers Off, 1 GB, 2 GB and 4 GB, defaulting to 2 GB. Each sweep counts measured background processes once and checks eligible tabs heaviest first, breaking ties by least recent visibility. Unknown attribution adds no memory charge and follows measured tabs in least-recently-used order. Budget sleeping waits at least two minutes after last visibility and stops once the remaining measured footprint is within budget. Protected pages and complete split groups retain the existing safety checks.

A background tab with an unshared process using at least 500 MiB can sleep after three minutes when its ordinary timeout is longer. Shared or unavailable measurements do not trigger this shorter timeout. Sampling uses the existing resource monitor during the coalesced sweep; no additional sampling timer is created.
