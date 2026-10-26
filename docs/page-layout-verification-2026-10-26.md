# Page height stability

26 October 2026.

## Reproduction and cause

The reported ClickUp screenshot shows the page occupying only the upper part of a full-height browser card. A read-only check of the running browser subsequently showed a normally sized page.

A disposable native-WebKit test reproduced an oscillating page height with the developer console docked below it. Barc pinned the web view to all four edges of its parent while WebKit resized that same view to reserve space for the console. Forcing another layout stretched the page over the console; WebKit then shrank it again. The unchanged test window produced a 500-point difference between successive page-height readings.

The console had been opened during the earlier memory investigation, making it a likely trigger for the reported screenshot. The original event was not replayed on the user's page. WebKit's [native docking implementation](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/Inspector/mac/WebInspectorUIProxyMac.mm) positions the console as a sibling and manages the page's frame.

## Fix and coverage

Normal browser tabs and split panes now let the native web view resize through its frame and autoresizing mask. The surrounding page card continues to use its existing layout.

The regression test opens the real native console over a quiet fixture, docks it, and checks that page and console do not overlap and page height remains stable. It repeats the check at three window sizes in both normal and split hosts, then closes the console and checks that the page fills the available height again. A second test exercises six sleep/wake cycles through the real content controller and verifies page sizing after window changes.

The tests use a disposable website data store and isolated inspector configuration. No user page or private page content is needed to reproduce the problem.

## Verification results

- The original native-console reproduction failed with overlapping page/console frames and a 500-point height oscillation. Both normal and split hosts pass after the correction.
- The focused run passed 95 tests in 11 suites.
- The final wider run passed 2,463 tests in 392 suites. The six memory integration tests, including authenticated scroll restoration, passed separately. The native console test has a three-minute wall-clock limit to accommodate scheduling delays in the full AppKit run; it completes in seconds when run on its own.
- The optimized local app built successfully and passed strict signature verification.
