# Web process release probe

28 October 2026. Disposable loopback HTTP fixture, independent nonpersistent stores, detached views, macOS WebKit. No installed application or user profile was accessed.

Run with `BARC_PROCESS_CACHE_PROBE=1 swift test --scratch-path /tmp/barc-build-a4 --filter WebProcessReleaseProbe`.

| Release strategy | PID | Loaded physical footprint, bytes | Immediately after release, bytes | At 10–60 seconds |
| --- | --- | --- | --- | --- |
| Plain release | 94994 | 11,010,816 | 11,010,816 | PID absent, 0 bytes |
| Empty HTML, then release | 95514 | 11,453,136 | 11,600,592 | PID absent, 0 bytes |

Each strategy was observed for 60 seconds, sampling every ten seconds with `kill(pid, 0)` and `ProcessSampler.read`, which uses `proc_pid_rusage` physical footprint. The private process-identifier selector is capability checked. Empty HTML loading was bounded to five seconds and checked for about:blank before release. The opt-in probe passed in 125.910 seconds.

These initial results do not establish whether blanking helps. The loopback IP has no registrable domain and cannot exercise the non-shared process cache path. The public-domain persistent-store measurements below supersede this comparison.

No hibernation or closed-tab retirement behavior was changed. Existing interaction-state capture, scroll fallback, history handling, handoff cancellation and retained-view cleanup remain in place. New retirement preservation tests are therefore unnecessary for this workstream; the conditional behavior change was not made.

`WebEnvironment.makeConfiguration` explicitly selects `.suspend` for inactive scheduling. The installed SDK documents that this applies when idle and detached, and excludes playing media and loading pages. `Tab.applyMediaSuspension` continues to exempt picture-in-picture, camera/microphone capture and realtime activity from forced media pausing. No media suspension logic was changed. Background realtime connections without playing media remain subject to WebKit's scheduling decisions and were not independently measured here.

Initial builds encountered concurrent edits in CacheMode.swift, TabSuspender.swift and MemoryReliefTests.swift. Those files were not modified by this workstream. Only the opt-in probe was executed; the ordinary suite was not run.

## Upstream eligibility, checked 28 October

[WebProcessCache.cpp on WebKit main](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/WebProcessCache.cpp) requires:

- Process eligibility flag, nonzero capacity, a registrable site domain unless shared, a surviving store not removing data, no memory pressure, and no near-process-limit condition.
- No pages, provisional pages, suspended pages or service workers; a successful asynchronous responsiveness check, followed by another eligibility check.
- Cache support compiled in, navigation process swaps and cache use enabled, PrimaryWebBrowser cache model, and single-process mode disabled. Overrides can set capacity; otherwise RAM below 2 GiB disables caching, and macOS capacity is min(RAM / 256 MiB, 32).

There is no explicit persistent/ephemeral rejection in these methods. Destroying a session clears its entries. Same-site replacement and capacity eviction can remove entries. Cocoa lifetime is 30 minutes; suspension starts after 30 seconds. Resigning active starts a five-minute clearing timer when cache entries exist; activation stops it. Activity is not an admission condition.

[WebProcessProxy.cpp](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/WebProcessProxy.cpp) additionally excludes print processes, service workers, cross-origin isolation and inspector pools. Shutdown waits for page/frame references and shutdown-prevention scopes to disappear and for pool termination permission. These are current upstream rules, not a claim that the installed framework has identical internals.

## Persistent-store public-domain rerun

The revised probe uses a fresh `WKWebsiteDataStore(forIdentifier: UUID())` for each trial. Its configuration stays in the trial scope while the view is released and sampled. Each trial returns before `WKWebsiteDataStore.remove(forIdentifier:)` runs; all eight removals succeeded. Public documents passed the complete-ready-state and nonempty-body checks. Empty HTML finished loading before release. Only the opt-in probe ran, passing in 1022.971 seconds.

All samples are bytes of physical footprint. At zero seconds each PID existed. At 5, 10, 30, 60 and 120 seconds every PID was absent and its reading was zero. The observation window was shortened to 120 seconds; 300 seconds was not measured.

| Requested activity | Page | Release | PID | Loaded bytes | Zero-second bytes |
| --- | --- | --- | --- | --- | --- |
| Active | example.com | Plain | 97949 | 13,353,800 | 13,386,568 |
| Active | example.com | Blank | 99016 | 13,501,208 | 13,697,816 |
| Active | Wikipedia WebKit | Plain | 99725 | 44,630,880 | 44,647,264 |
| Active | Wikipedia WebKit | Blank | 1185 | 44,499,808 | 44,745,568 |
| Inactive | example.com | Plain | 1935 | 13,566,792 | 13,566,792 |
| Inactive | example.com | Blank | 2878 | 13,402,952 | 13,665,096 |
| Inactive | Wikipedia WebKit | Plain | 4082 | 44,401,504 | 44,434,272 |
| Inactive | Wikipedia WebKit | Blank | 4524 | 47,596,384 | 48,350,048 |

Activation was attempted with regular activation policy and `activate(ignoringOtherApps:)`, followed by `hide` for the second pass. The runner reported `isActive == false` at both pass boundaries and in every trial. A genuine active-app comparison was therefore unavailable. This is two inactive passes, not evidence about active-app caching. Memory pressure, internal cache capacity/model and actual cache admission were not observable through the public API. No long-lived cached process was reproduced, even with persistent stores and registrable public domains. Blanking showed no measurable advantage at five-second resolution under the observed conditions. Hibernation and closed-tab behavior remain unchanged; these results do not establish a general absence of benefit.

The installed SDK header gives no default value for `inactiveSchedulingPolicy`. A fresh `WKPreferences` in this runtime returned raw value 0, `.suspend`; the explicit assignment preserves that observed default. [The upstream getter](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/API/Cocoa/WKPreferences.mm) derives the value from internal throttling preferences, so this observation should not be generalized to every OS release. The code comment now explicitly says the policy affects detached views only.
