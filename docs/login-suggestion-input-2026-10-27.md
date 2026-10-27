# Login suggestions and field typing

27 October 2026.

## Cause

Focusing or clicking a login field opened a synchronous `NSMenu.popUp`, including when the profile had no matching saved accounts. The menu entered AppKit's menu-tracking loop and captured keyboard input until dismissed. The regression fixture reproduced that behavior for an empty account list before the correction.

## Change

Empty results show no suggestion UI. Matching accounts use an asynchronous native child panel that cannot become the key or main window. Its buttons do not request keyboard focus. This follows AppKit's [non-activating panel focus contract](https://developer.apple.com/documentation/appkit/nspanel/becomeskeyonlyifneeded).

Ordinary keys dismiss the panel and pass through to the page, including the first typed character. Return passes through until the user explicitly highlights an account with an arrow key. Clicking an account or confirming a highlighted account remains an explicit fill action. Escape, outside clicks, scrolling the page, window movement, resizing, closing and loss of focus dismiss the panel. All observers, event monitors and suspended replies are cleaned up on dismissal or task cancellation.

Each lookup has a document/request token. Editing, leaving the field or leaving the window invalidates the request even if a vault read is still pending. Native validation and the isolated page script both discard stale replies. The field must still be connected, focused, on the original address and unchanged before values are applied. Profile/origin isolation, private-mode exclusions, preference checks and password authorization remain in effect.

## Verification

- The original empty-result regression failed by observing native menu tracking. It now passes without opening a menu.
- Thirteen saved-login tests passed in 1.411 seconds. They include actual WebKit text entry with saved-account suggestions visible, click and keyboard selection, ordinary Return behavior, cancellation and window-close cleanup, delayed reader cancellation, stale replies after editing/field changes/window blur, two-step sign-in and bridge isolation.
- Twenty-four related password, vault, sync, form-fill and context-menu tests passed separately.
- The panel was rendered with fictional accounts and checked for readable labels and visible account rows. No real credentials were used for these fixtures.

## Local installation

The optimized, signature-verified update was installed locally as build 257, version `0.0.4-8-g5971ace`. The prior app and session were backed up. Barc quit normally, and the saved session was unchanged during replacement. All 73 workspace tabs, eight spaces and 1,153 saved address entries were present after reopening.

A live check in the installed browser used a disposable local email form. Clicking the field kept it focused, no empty-result menu appeared, and the complete fictional address typed into the field successfully. The test text was cleared without submitting the form. The temporary tab and local server were closed, and the previous user page was restored.
