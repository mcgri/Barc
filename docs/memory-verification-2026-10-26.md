# Memory optimization verification

26 October 2026.

## Implemented behavior

Eligible pages in inactive profiles begin hibernating after one minute, with a separate General setting to change or disable the timeout. Tabs in the current profile keep their existing ordinary background-tab policy. Waking a profile restores only the selected page or visible split.

The implementation retains website data stores and login cookies. It protects edited forms, file selections, uncertain rich editors, calls, capture, uploads, active/resumable downloads, Keep Awake rules, visible content, and automatic-refresh dashboards. Calls and picture-in-picture retain background media permission. Hidden panels have a lifecycle; scratchpads and drafts remain resident.

The other changes restore accurate page visibility, reduce repeated DOM scans, limit preview memory, stop unloaded-tab reload timers, move session encoding/writes to a serial worker, and correct shared-process resource readings. [Behavior and configuration](memory-efficiency.md).

## Completed checks

| Requirement | Evidence |
| --- | --- |
| Whole-project regression coverage | The 2,444-test suite in 387 suites passed with zero failures. Opt-in tests are skipped in the normal invocation. |
| Actual one-minute scheduling | A real-time test verified the page stayed loaded before the minute and was unloaded by the ordinary timer afterwards. The isolated run finished in about 62 seconds. |
| Draft safety | Live web-view tests cover textarea/input changes, property-only changes, rich editors, selected files, child frames, cross-origin frames, and protection under critical memory pressure. |
| Calls and capture | Tests use actual native peer objects and their close lifecycle, native active/muted capture states, capture-track lifecycle, and the background-media exception. Hardware permission dialogs and calls to other people are not part of the tests. |
| Transfers | An unfinished loopback HTTP download remained protected under every automatic trigger, then completed its full file. Upload protection was checked while its request was pending. |
| Authentication and restoration | A real loopback HTTP page restored persistent and session-only cookies in the same store, plus its scroll position. Profile reassignment clears restoration state across identities. |
| Activation and shared state | Tests cover returning during inspection, shared Favorites, transitions between Spaces using one profile, visible panes, and protected hidden splits. |
| Memory release | Weak-reference checks prove unloaded views deallocate. Eight repeated real HTTP restore/unload cycles left no old views retained. |
| Other surfaces and caches | Tests cover quiet hidden panels, retained panel drafts/scratchpads, deleted cache entries, and preview byte limits. |
| Durable session saves | Queued older checkpoints cannot overwrite a later explicit save. Clear drains pending writes. File permissions remain private. Transient progress does not trigger encoding. |
| Resource sampling | Shared PIDs receive identical readings within a sampling interval. Unknown readings are labelled and unloaded tabs receive no invented memory charge. |
| Optimized application | The release bundle built successfully and passed strict signature verification. |

The full-suite log is `_local/memory-final-full-suite.log`. The build log is `_local/memory-release-build.log`; the executable checksum is `_local/memory-release-sha256.txt`.

## Long-run memory check

**Passed.** The separate opt-in soak completed 26 cycles in 1,885.6 seconds, about 31.4 minutes, with no assertion failures.

The workload uses three disposable private profiles, fictional session-only cookies, and a touched 32 MiB allocation in each loaded fixture page. It cycles profiles through 26 real 70-second idle periods. Each cycle checks cookie retention, unloads eligible inactive content, and records old-view retention and the physical footprint of known processes. Previously identified helper PIDs continue to contribute while they remain measurable.

Initial measured footprint was about 312.5 MiB with three fixture pages loaded. The first sleeping cycle left one loaded page and no stale views, at about 117 MiB. Final footprint was 90.8 MiB. After the first two cycles, readings ranged from 86.7 to 92.7 MiB. Every cycle ended with exactly one loaded page and zero retained old views. The test's session-cookie assertions all passed.

This compares loaded and hibernated states in one controlled workload. It is not a general memory-saving percentage or a comparison against the previously installed release. The workload includes touched buffers that make inactive-page allocations visible; actual sites have different allocations and protection reasons.

The authoritative result is `_local/memory-soak-result-2026-10-26.json`, and the terminal test log is `_local/memory-soak.log`.

## Delivery and limits

The updated application is `build/Barc.app`. The installed copy was not replaced or restarted, so ongoing browsing was not interrupted.

WebKit controls process reuse and cache reclamation. Hibernation releases eligible live pages while preserving profile storage. Pages with protected or uncertain work remain awake. The implementation makes no fixed RAM-saving promise for arbitrary websites and no network-dependent wake-time guarantee.

Existing unrelated working changes were preserved. No hosted environment variables, production settings, profile data, or credentials were changed for this work.
