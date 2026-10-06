# Developing Side Tabs

Notes for building Side Tabs from source and publishing releases. For installing and using
it, see the [README](README.md).

## Build from source

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

## Make a release

1. Raise `MARKETING_VERSION` (and `CURRENT_PROJECT_VERSION`) for both targets in
   `SideTabs.xcodeproj`.
2. Run `scripts/package.sh`. It builds and signs the app and creates two files:
   - `dist/Side-Tabs-<version>.dmg`, which people download. Opening it shows Side Tabs and
     the Applications folder over a background with a drag arrow. The artwork comes from
     `scripts/make-dmg-background.swift`, and Finder arranges the window, so the first run
     asks to let Terminal control Finder.
   - `dist/Side-Tabs-<version>.zip`, which installed copies download to update themselves.
3. Create a GitHub release tagged `v<version>` with both files attached. For the notes,
   list what's new and paste in the Install section of the README:
   ```bash
   gh release create v1.1 dist/Side-Tabs-1.1.dmg dist/Side-Tabs-1.1.zip --title "Side Tabs 1.1"
   ```
   Everyone's copy picks it up the next time they start Safari. Drafts and pre-releases are
   skipped, so publish as a pre-release to try a build before it goes out.
4. Check that the README still matches the app (install steps, features, settings,
   troubleshooting), and that its download link gives the new version.

Releases are signed with a free development certificate. They aren't notarized by Apple,
so people have to click **Open Anyway** the first time (see Install in the README). An
[Apple Developer Program](https://developer.apple.com/programs/) membership would allow
signing with Developer ID and notarizing, which removes that step. Development
certificates last a year, so package a new release with a fresh certificate before the
old one expires.

Installed copies only accept an update signed by the same team (the `OU` of the signing
certificate), so always sign releases with a certificate from the same Apple account.
macOS ties the Accessibility permission to the certificate's full name, though: if a
renewed certificate has a different name, people have to allow Accessibility again once
after that update. Side Tabs notices and opens setup to walk them through it.

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
