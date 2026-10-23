<!-- Modified for Barc: application identity, branding and fork configuration, 2026-10-23. -->
# Native messaging

An extension cannot start a program. That is the whole reason this exists: a
password manager's extension is a front end, the vault lives in an app, and the
only way the two can talk is for the browser to start the app's helper and pass
messages between them. Chrome defined the arrangement, Firefox copied it, and
every extension that depends on a desktop app — 1Password, Bitwarden,
KeePassXC, iCloud Passwords, Zotero — uses it.

Barc supports both halves of the API:

| Extension calls | What Barc does |
| --- | --- |
| `chrome.runtime.sendNativeMessage(host, message, callback)` | Starts the host, writes one message, reads one reply, stops the host. |
| `chrome.runtime.connectNative(host)` | Starts the host and keeps it running. Messages cross in both directions until the extension disconnects, the page goes away, the host exits, or Barc quits. |

The extension must ask for the `nativeMessaging` permission in its manifest.

## Where Barc looks for hosts

An app makes itself reachable by writing a small JSON manifest into a folder the
browser reads. Barc reads these, in this order, and the first manifest with a
given name wins:

1. `~/Library/Application Support/Barc/NativeMessagingHosts/`
2. `~/Library/Application Support/io.github.mcgri.Barc/NativeMessagingHosts/`
3. `/Library/Application Support/Barc/NativeMessagingHosts/` (and the
   bundle-named spelling of it)
4. Google Chrome's folders, then Chromium's, Edge's, Brave's, Vivaldi's,
   Opera's and Arc's
5. Firefox's folders, which use `allowed_extensions` instead of
   `allowed_origins`

Reading other browsers' folders is deliberate, and it is what makes a password
manager work on the day it is installed: almost no vendor ships a manifest
named for Barc. It widens the set of hosts Barc can *see*; it does not
widen who may *use* them, because the manifest's own allow-list still decides
that. Settings ▸ Extensions ▸ **Include apps that set themselves up for another
browser** turns it off.

## Writing a host for Barc

The manifest, named after the host it describes:

```json
{
  "name": "com.example.helper",
  "description": "What this program is for",
  "path": "/Applications/Example.app/Contents/MacOS/helper",
  "type": "stdio",
  "allowed_origins": ["chrome-extension://aaaabbbbccccddddeeeeffffgggghhhh/"]
}
```

- `name` must match the file name (`com.example.helper.json`) and may hold only
  letters, digits, underscores and dots. A manifest claiming a name that is not
  its own is refused.
- `path` may be absolute or relative to the manifest.
- `type` must be `stdio`.
- `allowed_origins` are Chrome-style extension origins. A Firefox-style
  manifest uses `allowed_extensions` with `name@vendor.example` identifiers
  instead; both are understood.

The protocol on the pipes: each message is a 32-bit little-endian length
followed by that many bytes of UTF-8 JSON. Barc refuses a single message
larger than 64 MB in either direction.

The host is started the way the browser its manifest came from would start it:
a Chrome-style host gets the calling extension's origin as its one argument, a
Firefox-style host gets the manifest path and the add-on's identifier. Its
working directory is the folder the program lives in.

## Which extension is which

WebKit's extension engine knows an extension by an identifier Barc gave it; a
host's manifest names extensions the way Chrome does. Barc matches the two
from evidence the extension cannot forge:

- the Chrome Web Store ID it was downloaded under,
- the identifier derived from the `key` in its own manifest, the same SHA-256
  of the public key that Chrome uses,
- the Firefox identifier in `browser_specific_settings.gecko.id`,
- and the identifier the engine knows it by, which is what a host written for
  Barc would list.

## What Barc refuses

Every launch has to pass all of these, in order:

1. Native messaging is on in Settings ▸ Extensions.
2. Your organisation allows it — see `NativeMessagingDisabled` and
   `NativeMessagingHostAllowlist` in
   [enterprise-policies.md](enterprise-policies.md).
3. The host is not switched off by name in Settings.
4. The extension asked for the `nativeMessaging` permission.
5. A manifest with that name exists and is well formed.
6. The manifest names this extension.
7. The program is there, is executable, and is not writable by everyone on the
   Mac — a program anyone can replace is a program Barc will not run.

A refusal reaches the extension in Chrome's own words (`Specified native
messaging host not found.`, `Access to the specified native messaging host is
forbidden.`) so extensions that branch on the message behave as they do
elsewhere. The reason in plainer English is in Settings and, with
`BARC_EXTENSION_LOG=1`, in the log.

One rough edge worth knowing: when `connectNative` is refused, WebKit hands the
extension a port that closed without a stated reason — `runtime.lastError` is
empty in `onDisconnect`. `sendNativeMessage` does carry the message.

## When something does not work

Settings ▸ Extensions ▸ **Apps found** lists every manifest Barc read, where
it came from, and the program it names. A manifest that was refused is listed
in red with the reason: the wrong name inside, nothing to run at that path, a
program that is not executable, one that anyone can write to, or a protocol
Barc does not speak. That list is the first place to look when an extension
says it cannot reach its app.

Hosts are stopped when the extension disconnects and when Barc quits; none
are left running behind the browser.
