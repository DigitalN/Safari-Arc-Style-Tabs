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

## Release checklist

Go through all of it for every release. Releases are public, and installed copies update
themselves from the latest one the next time Safari starts, so a mistake reaches everyone.
Merging a pull request doesn't release anything: the download links only change when a
release is published.

### Before building

- [ ] Everything going out is merged into `main`, and the local `main` matches GitHub
  (`git pull`).
- [ ] `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` are raised in
  `SideTabs.xcodeproj` for both targets, the app and the extension (four build
  configurations). The version must be higher than the latest release, or installed
  copies won't update.
- [ ] The signing certificate is valid and not about to expire:
  `security find-identity -v -p codesigning` lists an *Apple Development* identity from the
  same team as the last release. If the certificate's name has changed since then,
  everyone has to allow Accessibility again after updating (see *Signing* below).
- [ ] The README matches what's shipping: install steps, features, troubleshooting. It's
  only for people using Side Tabs and kept short; developer notes go in this file.

### Build and check the disk image

- [ ] `scripts/package.sh` makes `dist/Side-Tabs-<version>.dmg`. That's the only file a
  release has: people download it, and installed copies update from it. No `.zip`.
- [ ] Open the DMG: Side Tabs and Applications with the arrow between them, and the
  first-launch card at the bottom easy to read.
- [ ] The app inside has the new version, a valid signature, and the right team:
  ```bash
  M=$(hdiutil attach -nobrowse -readonly -noautoopen dist/Side-Tabs-1.2.dmg | grep -o '/Volumes/.*$')
  defaults read "$M/Side Tabs.app/Contents/Info" CFBundleShortVersionString
  codesign --verify --deep --strict "$M/Side Tabs.app" && codesign -dvv "$M/Side Tabs.app" 2>&1 | grep TeamIdentifier
  hdiutil detach "$M"
  ```

### Test updating, if the updater, packaging or signing changed

- [ ] An installed copy updates to a higher-version build from a stand-in release (see
  *Testing the updater* below): it downloads, swaps, relaunches, keeps Accessibility, and
  the extension reconnects.
- [ ] It refuses a build changed after signing, a build signed by someone else, and a
  release whose tag is newer than the app inside it.
- [ ] Afterwards, `UpdateFeedURL` is removed, the test builds are deleted, and a normal
  build is reinstalled with `scripts/install.sh`.

### Publish

- [ ] Release notes: what's new in this version, then the README's Install section. Only
  the current version: no notes for people on older versions, and nothing about files
  that aren't attached.
- [ ] Publish it, tagged `v<version>`, from the commit it was built from:
  ```bash
  gh release create v1.2 dist/Side-Tabs-1.2.dmg --title "Side Tabs 1.2" --notes-file notes.md
  ```
  Drafts and pre-releases are skipped by the updater, so publish a pre-release first to
  try a build before everyone gets it.
- [ ] Turn the previous release into a draft, so the page lists only the current one.
  This hides it without deleting it:
  ```bash
  gh release edit v1.1 --draft=true
  ```

### After publishing

- [ ] `https://github.com/DigitalN/Safari-Arc-Style-Tabs/releases/latest` goes to the new
  tag.
- [ ] GitHub's API, which the updater reads, shows the new tag with only the `.dmg`:
  ```bash
  curl -s https://api.github.com/repos/DigitalN/Safari-Arc-Style-Tabs/releases/latest | grep -E '"tag_name"|"name": "Side-Tabs'
  ```
- [ ] The DMG downloaded from the page is identical to the one in `dist/`
  (`shasum -a 256`).
- [ ] The repository's main page shows *Releases 1* with the new version, and the release
  page has nothing stale in it.
- [ ] An installed copy, restarted while Safari is open, logs `up to date at <version>` (or
  updates itself, if it was older).

### Signing

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

## Testing the updater

Copies installed with `scripts/install.sh` update themselves too, so a local build with an
older version number than the latest release gets replaced. Turn off *Update automatically*
in Settings while working on an older version.

To try an update without publishing anything:

1. Build a copy with a higher version, signed the same way as `build.sh` signs, outside
   the usual build folder:
   ```bash
   xcodebuild -project SideTabs.xcodeproj -scheme "Side Tabs" -configuration Release \
     -derivedDataPath ~/Library/Developer/Xcode/DerivedData/SideTabs-UpdateTest \
     CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=Apple Development" DEVELOPMENT_TEAM=<team id> \
     PROVISIONING_PROFILE_SPECIFIER= MARKETING_VERSION=9.9 build
   ```
   Then run `lsregister -u` on it (the full path is in `install.sh`), so Safari doesn't
   pick up a second copy of the extension.
2. Put it in a disk image with `hdiutil create -srcfolder`, and write a stand-in for
   GitHub's
   [latest release](https://docs.github.com/en/rest/releases/releases#get-the-latest-release)
   response whose `.dmg` asset's `browser_download_url` is a `file://` URL.
3. Point the installed copy at it and restart Side Tabs with Safari open:
   ```bash
   defaults write com.digitaln.sidetabs UpdateFeedURL file:///path/to/latest.json
   ```
   The signature check still applies. `log stream` (above) shows `downloading`,
   `ready to install`, then `installed <version>; relaunching` once the Mac has been idle
   for 10 seconds.
4. To check that bad updates are refused, change the test app's `Info.plist` after it's
   signed, or re-sign it with `codesign --force --deep -s -`. Each should log
   `update check failed` and leave the installed copy alone.
5. Clean up: `defaults delete com.digitaln.sidetabs UpdateFeedURL`, delete the test build
   folder, and reinstall with `scripts/install.sh`.

The updater mounts the disk image in `/Volumes`, like any other disk image, but hidden
from Finder. Mounted anywhere else, macOS's file access protection stops Side Tabs from
reading it. `hdiutil attach` is deprecated in macOS 27 in favor of `diskutil image attach`;
it still works.
