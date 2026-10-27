# Idle page retention investigation

27 October 2026.

## Live observations

The initial running build, 253, reported approximately 3.18 GB: ClickUp 1.01 GB, ChatGPT 671 MB, Supabase 576 MB, auxiliary web content 562 MB, Barc 249 MB, networking 97 MB and graphics 62 MB. There were three awake tabs and 65 sleeping tabs. These are process footprints, including WebKit and caches, rather than isolated website allocations.

The auxiliary process was PID 88041. Its footprint was 562 MB, with almost all writable memory swapped out. It had exited by the start of the follow-up investigation. ClickUp's original process had also exited and that tab was asleep. Later browsing changed both the live pages and total memory, so these readings cannot establish a before/after saving attributable to this patch. The original auxiliary page's owner cannot be recovered from the old aggregate reading.

The user confirmed that the remaining ChatGPT and Supabase draft warnings did not correspond to an unsent message or unsaved edit. The exact controls responsible in those live pages were not inspected.

## Reproduced faults and changes

1. A completed background POST arriving during a safety-check reply invalidated the entire audit. A page that repeatedly refreshed in this window could remain awake indefinitely. The guard now distinguishes document/edit revisions from current work activity. Completed requests may finish during the audit; pending requests, calls, navigation, edits and incomplete frame inventories still prevent sleep.
2. A closed Glance, floating page, small browser window or standalone web app could retain its document if an editing panel or another component retained the web view or controller. These close paths now detach the page and use the existing delayed blank-document retirement. A page handed over to a tab or panel is claimed by its new owner and stays live.
3. In a background split, a new draft in an already checked pane could arrive while another pane was being inspected. Each successful audit now grants a revision-bound approval. The suspender verifies every member's approval, ownership, transfer status and eligibility immediately before unloading the group, with no intervening asynchronous operation.
4. Framework input/change events on untouched read-only controls were classified as unsaved work. Those events are now ignored for initially unedited read-only controls. An already edited field remains protected if a site subsequently makes it read-only during a save.
5. The authenticated restoration test also reproduced a scroll race in isolation. Barc successfully applied the saved position of 900, then WebKit restored an older position of 0. The fallback now temporarily holds automatic history scrolling while applying the fresh coordinates, restores the previous policy after paint or a bounded 500 ms backstop, and abandons deferred scrolling on input or navigation. WebKit's [history restoration code](https://github.com/WebKit/WebKit/blob/main/Source/WebCore/loader/HistoryController.cpp) documents restoration attempts at both layout and load completion. The native test now checks that the position remains correct after settling, rather than accepting a briefly correct sample.

The first, second and third faults were demonstrated by failing native-WebKit tests before their fixes. The read-only input, textarea and ARIA textbox cases likewise failed before the correction; the saving-lock draft case stayed protected throughout.

## Memory attribution

The Performance view now lists the surface type, website domain and visibility/closed status for auxiliary content processes. Closed identifies a retired surface, including the short cleanup delay; it does not claim that the whole process has exited. Shared processes are counted once, and any process already charged to normal tabs is excluded from auxiliary totals. Attribution stores neither page titles nor URL paths, query strings, field values or strong web-view references. This makes a future auxiliary spike traceable without opening a developer console.

## Preservation checks

- Completed requests at the reply boundary permit sleep. A request still pending at that same boundary, an unsent edit or a newly opened call prevents it.
- Edits in an earlier split pane preserve the complete split group.
- Closed Glance, floating, small-window and standalone web-app documents are cleared even while their views/controllers are retained externally.
- Promotion/docking into a tab preserves the identical live page and its unsent draft beyond the retirement delay in all three surface types.
- Existing integration coverage checks persistent and session cookies, back/forward history, saved addresses, scroll restoration, cross-origin drafts, uploads, capture tracks, visible tabs and the real one-minute scheduler.
- Deferred viewport tests cover input, same-document navigation, normal painting and a document that does not paint. The temporary history policy is restored in every case.

The fixes preserve drafts by keeping protected documents live. They do not serialize arbitrary application state or infer that a form submission, hidden editor or read-only saving lock proves a successful save.

## Verification results

- A broad run passed 2,470 tests in 394 suites. Real-time scheduler and memory-restoration integration tests were excluded from that run and exercised separately.
- The 59-test preservation run passed, including the real one-minute scheduler. An earlier broad run had timed out that scheduler under concurrent AppKit load; its isolated lifecycle run completed in 62.556 seconds.
- After the final standalone-app and viewport corrections, all 37 targeted tests in eight suites passed in 21.375 seconds. This includes the six memory integration tests, authenticated scroll restoration and all new retention/input/navigation cases.
- The earlier scroll failure also reproduced in isolation, so it was corrected rather than treated as a scheduling-only failure. Temporary scroll probes were removed.
- Both window and embedded Performance presentations were rendered with a disposable auxiliary-memory fixture and checked for readable attribution.
