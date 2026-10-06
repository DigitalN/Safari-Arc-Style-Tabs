# Side Tabs for Safari

Arc-style vertical tabs for Safari on the Mac. A sidebar sits against the left edge of
your Safari window and lists that window's tabs, each with its icon and title, with your
favorite sites pinned at the top.

**[⬇︎ Download the latest version](https://github.com/DigitalN/Safari-Arc-Style-Tabs/releases/latest)**
(free, for macOS 26 or later)

## Install

1. **Download** `Side-Tabs-….dmg` from the
   [latest release](https://github.com/DigitalN/Safari-Arc-Style-Tabs/releases/latest)
   and open it.
2. **Drag Side Tabs into Applications**, as the arrow shows.
3. **Open Side Tabs** from Applications. It walks you through the rest of setup.

The first time you open it, macOS may say it can't verify Side Tabs. Click **Done**, then
go to **System Settings → Privacy & Security**, scroll down, and click **Open Anyway**. You
only do this once. It's needed because Side Tabs is free and isn't distributed through Apple, so Apple
hasn't checked it; all of its code is on this page.

### Updating

Side Tabs updates itself. Each time Safari starts, it checks GitHub for a newer version
and downloads it in the background. It installs it the next time you leave your Mac alone
for a few seconds, and the sidebar disappears for a moment while it restarts. There's nothing to download or drag, and macOS doesn't ask you to approve it
again. **Check for Updates…** in the menu bar icon updates right away, and
Settings → *Update automatically* turns this off.

If the sidebar doesn't come back after an update, see *The sidebar doesn't appear* under
Troubleshooting.

### Uninstall

Quit Side Tabs from its icon in the menu bar, then drag it from Applications to the
Trash. That removes the Safari extension too. Your saved bookmarks and tab names are in
`~/Library/Application Support/Side Tabs/` if you want to delete those as well.

## Features

- **Address bar**: the top of the sidebar shows the current site, with ↻ to reload it.
  Click the site to jump into Safari's own address bar (the same as ⌘L), so you keep
  Safari's autocomplete, history and search suggestions.
- **Tabs**: click to switch. Close with the ✕ (shown on the current tab and on hover) or a
  middle-click. Right-click for Rename, Add to Bookmarks, Copy Link, Duplicate, Reload,
  Close Other Tabs and Close Tabs Below.
- **Drag to reorder**: drag a tab or bookmark and the other rows slide apart to show where
  it will land. Drag a tab up into Bookmarks to bookmark it at that spot; the tab stays
  open.
- **Rename tabs**: double-click a tab, or right-click → Rename Tab…. The new name shows
  only in the sidebar; Safari's own tab bar keeps the page title. Clear the name (or choose
  Reset Name) to go back. Names are kept across Safari restarts.
- **Bookmarks**: click + next to *Bookmarks*, drag a tab up into the list, or drop a link
  from a web page onto it. Clicking a bookmark switches to its tab if it's already open
  (a dot marks open ones), otherwise opens it in a new tab. ⌘-click always opens a new
  tab. Right-click to rename, replace with the current page, or remove. Dropping a link
  onto *Tabs* opens it in a new tab.
- **Stays out of the way**: the sidebar follows Safari's front window and narrows Safari
  to make room. Clicking the sidebar from another app brings Safari forward. Hiding the
  sidebar gives the space back to Safari.
- **Full screen**: Safari's window can't be resized in full screen, so the sidebar hides.
  Move the pointer to the left edge of the screen, or use the toolbar button, to slide it
  out over the page. It stays hidden during full-screen videos. To keep the sidebar
  *beside* the page at full height, use Window → Fill (Fn+Control+F) instead of full
  screen.
- **Show or hide** the sidebar with the Side Tabs button in Safari's toolbar or the menu
  bar icon.

Settings (menu bar icon → Settings…) cover the sidebar width, when close buttons show,
whether bookmarks show, opening Side Tabs at login, and updating automatically (both on
by default).

## Troubleshooting

- **macOS won't open Side Tabs.** Go to System Settings → Privacy & Security, scroll
  down, and click **Open Anyway** (see Install). If macOS says the app *is damaged*, open Terminal, paste the
  command below, and press Return:
  ```bash
  xattr -dr com.apple.quarantine "/Applications/Side Tabs.app"
  ```
- **Side Tabs asks to move itself to Applications.** Click **Move to Applications**.
  Side Tabs has to run from your Applications folder: opened from the disk image or
  Downloads, Safari can't find its extension.
- **The sidebar doesn't appear.** Open System Settings → Privacy & Security → *Device
  Control and Data Access* (*Accessibility* on macOS 26). If Side Tabs is listed, select
  it and click **−**, then click **+** and choose Side Tabs from Applications. macOS
  sometimes keeps an old entry after an update. Side Tabs restarts itself once access
  works.
- **Side Tabs isn't in Safari's Extensions list.** Make sure Side Tabs is in Applications
  and has been opened once, then quit and reopen Safari.
- **Safari turns the extension off whenever it restarts.** In Safari → Settings →
  Advanced, turn on *Show features for web developers*. Then, in the new Developer tab,
  turn on *Allow unsigned extensions*. You'll have to redo this after each Safari restart.
  Please also [open an issue](https://github.com/DigitalN/Safari-Arc-Style-Tabs/issues) so
  it can be fixed properly.
- **Tab names and icons are missing.** Allow the extension on every website (setup step 3).
- **The sidebar says "Connecting to Safari…".** That's normal for a few seconds after
  Safari or Side Tabs starts.

## Limitations

- Safari's own tab bar stays at the top. No extension can remove it.
- In full screen, the sidebar slides out *over* the page rather than beside it. Safari also
  opens its own sidebar when the pointer reaches the left edge in full screen, and has no
  setting to turn that off.
- Tabs and bookmarks can't be dragged out of the sidebar into other apps.
- The sidebar doesn't scroll by itself while you drag, so with a long list you can't drag
  a row past the visible area.
- Tabs in private windows appear only if you allow the extension in private browsing
  (Safari → Settings → Extensions).
- Safari's Settings window and other non-browser windows don't get a sidebar.

## For developers

### Build from source

You need macOS 26 or later, Xcode 26 or later, and an **Apple Development** signing
certificate. A free Apple ID works: Xcode → Settings → Apple Accounts → sign in → select
your **Personal Team** → Manage Certificates… → **+** → **Apple Development**. Without a
certificate, Safari switches the extension off every time it restarts.

```bash
scripts/install.sh
```

This builds a Release copy, signs it with your certificate, installs it to
`/Applications/Side Tabs.app`, and launches it. Run it again after making changes.
`scripts/install.sh --adhoc` builds without a certificate; Safari then needs *Allow
unsigned extensions* turned on after every restart.

Builds go to `~/Library/Developer/Xcode/DerivedData/SideTabs-CLI`, not the repository.
Folders synced by iCloud Drive (such as `~/Documents`) add Finder metadata to app
bundles, and codesign rejects bundles that have it.

### Make a release

1. Raise `MARKETING_VERSION` (and `CURRENT_PROJECT_VERSION`) for both targets in
   `SideTabs.xcodeproj`.
2. Run `scripts/package.sh`. It builds and signs the app and creates two files:
   - `dist/Side-Tabs-<version>.dmg`, which people download. Opening it shows Side Tabs and
     the Applications folder over a background with a drag arrow. The artwork comes from
     `scripts/make-dmg-background.swift`, and Finder arranges the window, so the first run
     asks to let Terminal control Finder.
   - `dist/Side-Tabs-<version>.zip`, which installed copies download to update themselves.
3. Create a GitHub release tagged `v<version>` with both files attached, and paste in the
   install steps above:
   ```bash
   gh release create v1.1 dist/Side-Tabs-1.1.dmg dist/Side-Tabs-1.1.zip --title "Side Tabs 1.1"
   ```
   Everyone's copy picks it up the next time they start Safari. Drafts and pre-releases are skipped, so
   publish as a pre-release to try a build before it goes out.

Releases are signed with a free development certificate. They aren't notarized by Apple,
so people have to click **Open Anyway** the first time (see Install). An
[Apple Developer Program](https://developer.apple.com/programs/) membership would allow
signing with Developer ID and notarizing, which removes that step. Development
certificates last a year, so package a new release with a fresh certificate before the
old one expires.

Installed copies only accept an update signed by the same team (the `OU` of the signing
certificate), so always sign releases with a certificate from the same Apple account.
macOS ties the Accessibility permission to the certificate's full name, though: if a
renewed certificate has a different name, people have to allow Accessibility again once
after that update. Side Tabs notices and opens setup to walk them through it.

### How it works

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
  - `SafariTracker` follows Safari's front window through the Accessibility API and
    brings Safari forward.
  - `DockController` positions the panel directly behind Safari's window, narrows Safari
    to fit, and handles full screen.
  - `TabStore` holds tabs, bookmarks and custom names.
  - `FaviconStore` downloads and caches icons.
  - `AccessibilityWatcher` restarts the app once Accessibility access is granted.
  - `AppLocation` offers to move the app into Applications.
  - `Updater` checks GitHub for new releases, verifies the download's code signature
    against the app's own team, and swaps it in at a quiet moment.
  - `Views/` is the SwiftUI sidebar, setup window and settings. `SidebarDrag` handles
    reordering with its own drag gesture rather than system drag and drop.
- `scripts/`: `install.sh` builds and installs, `package.sh` makes the release disk
  image (with artwork from `make-dmg-background.swift`), `build.sh` is shared by both,
  and `make-icons.swift` regenerates the icons.

Bookmarks and tab names are stored in `~/Library/Application Support/Side Tabs/state.json`.

To watch live logs from the app and the extension, run the command below. In zsh, plain
`log` is a shell built-in, so use the full path:

```bash
/usr/bin/log stream --info --predicate 'subsystem BEGINSWITH "com.digitaln.sidetabs"'
```

The extension's own console is in Safari → Develop → Web Extension Background Content →
Side Tabs.

Copies installed with `scripts/install.sh` update themselves too, so a local build with an
older version number than the latest release gets replaced. Turn off *Update automatically*
in Settings while working on an older version. To try the updater without publishing,
point it at a stand-in for GitHub's
[latest release](https://docs.github.com/en/rest/releases/releases#get-the-latest-release)
response, with a `.zip` asset whose `browser_download_url` is also a `file://` URL:

```bash
defaults write com.digitaln.sidetabs UpdateFeedURL file:///path/to/latest.json
```

The signature check still applies. Remove it with
`defaults delete com.digitaln.sidetabs UpdateFeedURL`.
