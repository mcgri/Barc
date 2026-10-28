# Content blocking memory investigation

Measured on 2026-10-28 using the readable text cache at `~/Library/Application Support/io.github.mcgri.Barc/filter-lists`, without changing that cache or opening the installed application. The compiled-rule store was private and temporary. No normal tests were run.

## Conversion and deduplication

The default catalogue order was used. Rules with identical normalized triggers and actions were eligible for cross-list removal only when both lists had no `ignore-previous-rules` action. Every default list contains exceptions, so the conservative deduplicator removed **0 of 168,095 rules, 0%**. Its helper and tests were deleted instead of integrating an ineffective transformation. Exceptions in one WebKit list cannot cancel another list's blocking actions.

| List | Converted rules | Exception rules | Generic cosmetic rules |
| --- | ---: | ---: | ---: |
| easylist | 82,110 | 746 | 13,290 |
| ublock-ads | 2,379 | 737 | 32 |
| ublock-unbreak | 1,420 | 1,182 | 1 |
| easyprivacy | 56,328 | 851 | 2 |
| ublock-privacy | 978 | 2 | 2 |
| easylist-cookies | 24,742 | 426 | 15,270 |
| ublock-cookies | 138 | 33 | 0 |
| Total | 168,095 | 3,977 | 28,597 |

## WebContent footprint

Reproduce with `BARC_RULELIST_MEMORY_PROBE=1 swift test --scratch-path /tmp/barc-build-a5 --filter RuleListMemoryProbe`.

The probe converts real cached sources, compiles both variants using `WKContentRuleListStore(url:)` beneath a UUID temporary directory, and loads a loopback HTTP page into a fresh non-persistent store per sample. It then awaits five same-origin loopback iframes, waits three seconds, capability-checks `_webProcessIdentifier`, and samples `proc_pid_rusage` `ri_phys_footprint` through `ProcessSampler`. All nine samples used distinct process identifiers. No other application scripts are installed. Same-origin frames share the measured process; cross-origin process allocation is not measured. Download fallback writes only to the temporary directory.

| Round | No lists, bytes | All lists, bytes | Without generic cosmetics, bytes | Generic savings, MiB |
| --- | ---: | ---: | ---: | ---: |
| 1 | 12,845,776 | 33,244,000 | 13,009,712 | 19.30 |
| 2 | 11,567,824 | 33,325,896 | 12,911,408 | 19.47 |
| 3 | 11,584,208 | 33,325,872 | 14,304,096 | 18.14 |
| Median, MiB | 11.05 | 31.78 | 12.41 | |

Every paired saving exceeds 15 MB. Advanced Content Blocking therefore exposes **Hide generic page elements**, default ON. OFF removes only `css-display-none` rules without `if-domain` from built-in and subscribed custom lists. Network rules, exceptions, domain-specific cosmetics and explicit My Rules remain intact. Existing compiled lists stay applied until their replacements are ready. The OFF variant has a stable `.specific-v1` identifier suffix; ON retains existing identifiers. A toggle during compilation rejects stale results and schedules the current variant. Controller updates take effect on navigation, consistent with the existing blocker preferences.

The first probe attempt crashed in AppKit autorelease cleanup while creating a test window. The successful run uses a windowless WKWebView. These are small fixture measurements, not a forecast for every site. The footprint includes charged pages rather than the full size of mapped compiled-list files.

## Script decisions

| Script | Scope and decision |
| --- | --- |
| FormAutofill | Keep all frames for embedded identity/payment forms. Child frames initially install one focus listener; patterns, sets and filler functions initialize on first input/select focus and handle that original event directly. No mutation observer. Install only while identity or card autofill is enabled. Both preference setters notify existing controllers to replace/remove the registered script. |
| PasswordAutofill | Main-frame-only remains unchanged as requested. The mismatch between frame-origin validation and main-only injection needs separate correctness review before enabling cross-origin login frames. |
| SiteBehaviourScripts documentStart | Keep all frames. Media, permissions, clipboard, hostile-behaviour and fingerprinting policies must apply inside embedded documents. Media discovery observers still serve frame-local video controls and are not removed. |
| SiteBehaviourScripts autoplaySweep | Keep all frames. Replace the document-wide subtree observer with one capture-phase play listener, plus the initial sweep. It reads current policy on every play event and pauses disallowed media without user activation. The existing play() wrapper remains. |
| SiteBehaviourScripts referrer / reader | Already main-frame-only; retain. |
| SitePolicy policy payload | Keep all frames; frame-local policy readers need it. No observer or scan. |
| Glance link monitor | Keep all frames. Already a single passive mousedown listener; link lookup and geometry are computed only on that event. No changes needed. |
| Glance focus monitor | Keep all frames for Escape/draft focus decisions. Already event-driven; no document scan or mutation observer. |
| Context menu selection tracker | Keep all frames and its two lightweight event listeners. Selectionchange caches text before the native menu opens; contextmenu refreshes it. Removing pre-menu tracking risks native-menu ordering. No subtree observer or initialization scan exists, so retain both for correctness. |
| Fonts | Already omitted for WebKit defaults; install only custom defaults. Keep all frames so embedded text uses the selected space fonts. Existing install/apply replaces/removes scripts for live controllers. Its startup observer disconnects once the style can be placed. |
| Boosts | Keep all frames so host-matched embedded documents receive their styles/scripts. Add no bootstrap when no enabled boosts exist. Store-change callbacks update existing controllers. Existing host mismatch exits before DOM work. |
| Vim navigation | Keep all frames because key events in a focused iframe do not reach the main document. Already gated by its setting. |
| Link hints | Already injected on demand, with no page-load script. Add a setting check at each invocation, including Vim invocation, so toggles affect existing views immediately. |
| JSON formatting | Already gated and main-frame-only; existing preferencesChanged updates controllers. |
| Element picker | Already injected on demand; no page-load script. |

`ScriptMemoryGatingTests` covers cookie/JSON toggles while preserving unrelated scripts, default/custom font replacement, enabled Boost store changes, Link Hints invocation gating, form autofill toggles on an existing controller, lazy child-frame initialization, generic filtering that preserves exceptions/network/domain rules, and ON/OFF/ON recompilation with a registered controller and private rule store. These tests were compiled, not executed. Only the env-gated memory probe was run.

Final validation: `swift build --build-tests --scratch-path /tmp/barc-build-a5` passed. No new warnings were introduced by the changed code. Existing unrelated warnings remain. `git diff --check` passed.
