# Safari Side Tabs

Arc-style vertical tabs for Safari on macOS. A sidebar sits flush against the left edge of
your Safari window and lists that window's tabs, each with its favicon and title, with
a list of bookmarks at the top.

Side Tabs is a small menu bar app with a Safari extension inside it. The extension tells
the app about your tabs, and the app draws the sidebar next to Safari's window.

## Features

- **Tabs**: click to switch. Close with the ✕ (shown on the current tab and on hover) or a
  middle-click. Drag to reorder. Right-click for Rename, Add to Bookmarks, Copy Link,
  Duplicate, Reload, Close Other Tabs and Close Tabs Below.
- **Rename**: double-click a tab, or right-click → Rename Tab…. The new name shows only in
  the sidebar; Safari's own tab bar keeps the page title. Clear the name (or choose Reset
  Name) to go back. Names are kept across Safari restarts.
- **Bookmarks**: click + next to *Bookmarks*, or drag a tab or a link onto the list.
  Clicking a bookmark switches to its tab if it's already open in the window (a dot
  marks open ones), otherwise opens it in a new tab. ⌘-click always opens a new tab.
  Drag to reorder; right-click to rename, replace with the current page, or remove.
- **Docking**: the sidebar follows Safari's front window and narrows Safari to make room
  when needed. Hiding the sidebar gives that space back to Safari.
- **Full screen**: Safari's window can't be resized in full screen, so the sidebar hides.
  Move the pointer to the left edge of the screen, or use the toolbar button or its
  shortcut, to slide it out over the page, below Safari's toolbar. To keep the sidebar
  *beside* the page at full height, use Window → Fill (Fn+Control+F) instead of full
  screen.
- **Show/hide**: the Side Tabs button in Safari's toolbar, a keyboard shortcut you assign
  to it, or the menu bar icon.

Settings (menu bar icon → Settings…) cover the sidebar width, when close buttons show,
whether bookmarks show, and opening Side Tabs at login.

## Requirements

- macOS 26 or later; built and tested on macOS 27 with Safari 27.
- Xcode 26 or later to build it.
- An **Apple Development** signing certificate. A free Apple ID works; you don't need a
  paid developer account. Without a certificate, Safari switches the extension off every
  time it restarts.

To get a certificate: Xcode → Settings → Apple Accounts → sign in → select your
**Personal Team** → Manage Certificates… → **+** → **Apple Development**.

## Install

```bash
scripts/install.sh
```

The script builds a Release copy, signs it with your Apple Development certificate,
installs it to `/Applications/Side Tabs.app`, and launches it. Run it again after pulling
changes. `scripts/install.sh --adhoc` builds without a certificate. In that case, enable
Safari → Settings → Developer → Allow Unsigned Extensions again after every Safari
restart.

Builds go to `~/Library/Developer/Xcode/DerivedData/SideTabs-CLI`, not the repository.
Folders synced by iCloud Drive (such as `~/Documents`) add Finder metadata to app
bundles, and codesign rejects bundles that have it.

The first time, the setup window walks you through three steps:

1. **Accessibility access**: System Settings → Privacy & Security → Device Control and
   Data Access (called Accessibility before macOS 27). This lets the sidebar follow
   Safari's window and narrow it to make room. Side Tabs restarts itself once access is
   granted.
2. **Turn on the extension** in Safari → Settings → Extensions.
3. **Allow it on every website**: select Side Tabs → Edit Websites… → set *When visiting
   other websites* to **Allow**. Until you do, Safari hides tab titles and icons from
   the sidebar.

Optional: assign a keyboard shortcut to the Side Tabs toolbar button to show and hide the
sidebar from the keyboard.

### Uninstall

Quit Side Tabs from its menu bar icon, then delete `/Applications/Side Tabs.app`. That
also removes the Safari extension. Saved bookmarks and tab names are in
`~/Library/Application Support/Side Tabs/`.

## How it works

Safari doesn't let extensions add a sidebar or replace the tab bar, so the sidebar is a
separate window that the app keeps attached to Safari's window:

```
 Safari ──tabs API──▶ background.js ──sendNativeMessage──▶ SafariWebExtensionHandler (sandboxed .appex)
                          ▲                                         │ CFMessagePort
                          │ connectNative port                      ▼
                          └──── SFSafariApplication.dispatchMessage ── Side Tabs.app (menu bar app)
                                                                     │ Accessibility API
                                                                     ▼
                                                     sidebar panel docked to Safari's window
```

- `WebExtension/`: the Safari web extension. `background.js` sends windows and tabs to
  the app (with retries, and a heartbeat every 5 seconds so missed updates are noticed)
  and carries out the app's commands: switch, close, open, move, and so on. `content.js`
  reports each page's favicon URL, which Safari's tabs API doesn't provide.
- `SideTabsExtension/`: the extension's native handler. It passes messages to the app
  over a CFMessagePort named after the app group, which is what lets the sandboxed
  extension reach the app.
- `SideTabs/`: the app.
  - `SafariTracker` follows Safari's front window through the Accessibility API.
  - `DockController` positions the panel directly behind Safari's window, narrows Safari
    to fit, and handles full screen.
  - `TabStore` holds tabs, bookmarks and custom names.
  - `FaviconStore` downloads and caches icons.
  - `AccessibilityWatcher` restarts the app once Accessibility access is granted.
  - `Views/` is the SwiftUI sidebar, setup window and settings.
- `scripts/`: `install.sh` builds and installs; `make-icons.swift` regenerates the app
  and toolbar icons.

Bookmarks and tab names are stored in `~/Library/Application Support/Side Tabs/state.json`.

## Limitations

- Safari's own tab bar stays at the top. No extension can remove it.
- In full screen, the sidebar slides out *over* the page rather than beside it.
- In full screen, Safari opens its own sidebar (Tab Groups, Bookmarks…) when the pointer
  reaches the left edge, so it appears alongside Side Tabs. Safari has no setting to turn
  this off.
- After Side Tabs or Safari restarts, the sidebar shows "Connecting to Safari…" for a
  few seconds while the extension reconnects.
- Tabs in private windows appear only if you allow the extension in private browsing
  (Safari → Settings → Extensions).
- Safari's Settings window and other non-browser windows don't get a sidebar.

## Troubleshooting

- **Accessibility is on but no sidebar appears.** In Device Control and Data Access,
  select Side Tabs, click −, then + to add it again. On macOS 27 an entry created by the
  system prompt can be tied to one specific build; re-adding it fixes that.
- **Tab titles and icons are missing.** Allow the extension on every website (setup
  step 3).
- **The build fails with "No signing certificate".** Your Apple Development certificate
  is missing or expired; create a new one as described under Requirements.

To watch live logs from the app and the extension, run the command below. In zsh, plain
`log` is a shell built-in, so use the full path:

```bash
/usr/bin/log stream --info --predicate 'subsystem BEGINSWITH "com.digitaln.sidetabs"'
```

The extension's own console is in Safari → Develop → Web Extension Background Content →
Side Tabs. To show the Develop menu, enable it under Safari → Settings → Advanced.
