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

- [ ] `https://github.com/TaylorBoan/safari-arc-style-tabs/releases/latest` goes to the new
  tag.
- [ ] GitHub's API, which the updater reads, shows the new tag with only the `.dmg`:
  ```bash
  curl -s https://api.github.com/repos/TaylorBoan/safari-arc-style-tabs/releases/latest | grep -E '"tag_name"|"name": "Side-Tabs'
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


## Spaces

`SpaceState` persists space names, icons, themes, the selected space, and tab membership
in `state.json`. Existing bookmarks become shared Favorites; existing tabs start in
Personal. Pinned sites have a `spaceID`; Favorites have none. Deleting a space moves its
items to the first remaining space without closing Safari tabs. The last space cannot
be deleted.

Spaces organize the Side Tabs sidebar within the current Safari window. Safari's native
tab bar continues to contain all of that window's tabs. Spaces do not isolate cookies,
logins, or Safari profiles, and they do not control Safari's native Tab Groups.
When Safari selects an existing tab, the sidebar follows its space. Opening a shared
Favorite keeps the selected space and associates that open tab with it.

Switching spaces activates the last visited tab in that window and space during the
current app session, or its first tab. An empty space retains Safari's current page
without opening a placeholder tab. New tabs
and duplicates include a request ID so delayed replies retain the space that requested
them, even if the user switches meanwhile. Closing or reordering tabs operates only on
the current space; Safari indices are mapped from the filtered list.

Safari tab IDs change after relaunch. Restoration matches URLs and window order, consuming
duplicate URLs individually. If the same URL is restored in a different window order or
profile, its original membership may not be recoverable. Private browsing memberships
are kept in memory and excluded from the saved space state.

`SidebarPanel.sendEvent` handles precise scroll events over the visible sidebar, excluding
the area underneath Safari. `SpaceSwipe` locks the gesture axis, uses a 45-point horizontal
threshold, switches at most once per gesture, and ignores momentum. Left finger movement
means next and right means previous regardless of Natural Scrolling. Vertical scrolling
and mouse wheels continue to reach the normal sidebar controls. Switching pauses while
renaming a row or editing a space.

Run the isolated checks with Apple's Swift command-line tools and Node.js:

```bash
scripts/test-spaces.sh
```

Before releasing, also build with Xcode and check the signed extension in Safari: create
and edit spaces, move active and inactive tabs, pin a site, share a Favorite, swipe over
rows and blank sidebar areas with Natural Scrolling on and off, scroll vertically, drag
rows, switch Safari windows, and restart Safari and Side Tabs. Test narrow and wide sidebar
widths and the full-screen overlay. Swiping over a web page must not change spaces.
The fork's updater reads TaylorBoan/safari-arc-style-tabs releases.


## Pinned folders

Each space has its own collapsible folder tree in Pinned. A folder may contain pins and
other folders at any depth. `FolderState` stores parent IDs, expansion state, and mixed
folder/pin sibling order; `Bookmark.folderID` associates saved sites with a folder.
Older state files load with their existing pins at the top level and shared Favorites
unchanged. On load, missing parents and cycles are repaired to keep all items reachable.

The folder + button creates a root folder. Folder context menus create subfolders,
rename, move to another folder or space, and reorder siblings. A tab's Pin in Folder
menu saves it into the chosen folder; dragging an open tab into a folder does the same.
This saves a persistent pin and keeps the live Safari tab open. A root-level pin can be
moved into a folder using its context menu or by dragging. Folder menus list complete
paths, including collapsed descendants, and disallow moving a folder into itself or
one of its descendants. Moving a folder across spaces moves its subtree and contained
pins. Removing a folder promotes its immediate contents, without closing Safari tabs.

`PinnedSection` flattens only expanded rows and caps visual indentation at five levels
so deeply nested items still have usable text at narrow sidebar widths. The model has
no corresponding nesting limit. Drag insertion maps visible row geometry to the correct
parent and sibling position; dropping on the middle of a folder nests the dragged item.
Space swipes and the ordinary Tabs section retain their existing behavior.

Regression checks in `scripts/test-spaces.sh` include nesting, collapse, mixed reordering,
cycle rejection, reparenting, cross-space moves, non-destructive removal, state repair,
and persistence. Before releasing, also verify folder creation, inline rename, nested
dragging, external URL drops, and collapse/expand against the installed Safari sidebar.

## Arc migration

The menu bar's **Import from Arc…** opens a read-only preview of
`~/Library/Application Support/Arc/StorableSidebar.json`; Choose File accepts saved
copies. `--preview-arc` opens this window on launch. Nothing is imported or opened
until the user reviews the selection and presses **Import Selected Spaces**.

`ArcMigration.swift` reads stable consecutive snapshots and traverses only the
active local sidebar. Alternating-key dictionaries, per-profile Favorites, folder
hierarchies, sibling order, duplicate URLs, and split-view provenance are retained.
Unknown content and non-web URLs appear as manual-handling entries. Split views
become adjacent individual links; original appearance and all source records stay
in the local snapshot. This does not transfer cookies, passwords, archives, or
private windows. The saved-source timestamp is shown; unsaved Arc state is outside
this snapshot. No source data is uploaded, and previews fetch no website icons.

The migration ledger and normal sidebar state share one atomic `state.json` write.
Arc IDs identify records, not URLs. Repeat imports add new IDs; changed sources,
locally edited/missing targets, and conflicting order changes are kept for review.
They are never silently overwritten or resurrected. Imported spaces are appended
after existing spaces without selecting them or creating empty Safari tabs.
Imported Favorites are visible in spaces with the same source `arcProfileID`;
existing global Favorites continue to appear everywhere. Source profiles are labels,
not Safari identity isolation. The user chooses regular Safari destination windows.

Before an import, a private `Arc Imports/<batch UUID>/` directory beside the state
holds `before.json`, `Arc-sidebar.json`, and a receipt. The receipt inside state is
authoritative; the bundle copy is an inspection copy. Keep personal snapshots and
receipts out of Git. Undo removes only unchanged owned objects, retains containers
with later user content, cancels queued work, and leaves live Safari tabs open.

Open tabs are a durable queue. Restoration is explicit, serial, and pausable. The
native app persists a request token and destination before sending `migrationCreate`.
The extension stores a durable intent in `storage.local` before creating a tab and
records its result before acknowledging. Concurrent/repeated tokens create once;
closed tabs stay closed. An interrupted intent or previous Safari session is
ambiguous and requires manual review rather than blindly retrying. The history UI
provides links and Mark Handled for these cases. Extension removal clears extension
storage, so never retarget an unresolved sending request as a fresh operation.

Validation:

```sh
scripts/test-spaces.sh
scripts/test-arc-import.sh
scripts/test-arc-import.sh --inspect-arc  # read-only local source inventory
```

Tests use synthetic fixtures and temporary state: duplicate URLs, profile Favorites,
active roots vs sync caches, nested order, repeat imports, stale previews, edited or
deleted destinations, transactional rollback, restart/resume, snapshot/ack races,
private destinations, unsupported URLs, cycles, and undo preservation. Extension
checks cover concurrent tokens, closed tabs, uncertain intents, old sessions, private
windows, and persistence failure. Actual Arc tabs must not be imported merely to
validate a build; leave the user's preview open for review.

## Pinned tab presentation and space strip

`tabs(in:)` remains the full space membership for activation and persistence.
`displayedTabs(in:showBookmarks:)` is the lower ordinary-tab list: one-to-one
bookmark/tab matching removes only tabs already represented by a visible pin or
Favorite. Explicit runtime links take priority over URL matching and survive
navigation and moves within a space. Additional tabs with the same URL remain
visible. With bookmarks hidden, all tabs appear below. Counts and drag indices use
the same displayed list; close-other/below actions protect sidebar pins. Open pins
retain highlight, close/middle-click, mute, and reload controls. A newly selected
nested pin reveals its folder ancestors; routine snapshots preserve manual collapse.

The space switcher is a fixed-height horizontal scroll view with a separate, always
visible New Space button. Selection scrolls its icon into view. A native background
view reports the actual strip bounds to SidebarPanel, so precise gestures beginning
on the strip scroll icons, including momentum; gestures in the tab area retain
space switching. No fixed footer-height assumption is used for normal/fullscreen
layouts. Regression cases are in `Tests/SpaceTests.swift`.

## Auto-hide in regular Safari windows

**Automatically hide sidebar** is a persisted option in Settings and the menu bar.
The default remains docked; `--auto-hide-sidebar` explicitly enables the same saved
preference on launch. Enabled mode restores the space Side Tabs reserved beside
Safari, then overlays the page instead of resizing Safari on every reveal/hide.
The toolbar button and shortcut open/close the overlay while leaving auto-hide on.

`SidebarAutoHide.swift` contains pure hover-state and geometry rules. The regular
window trigger follows Safari's visible left content edge, excluding browser chrome;
the drawer is inset inside its content area and clamped to its display. Fullscreen
keeps screen-edge activation. A short hide grace period and pointer tolerance avoid
flicker. Renaming, space-editor popovers, drags, and menus keep the drawer open. An
explicitly opened drawer waits for the pointer to visit before auto-hiding. Switching
apps, windows, macOS Spaces, or overlay contexts clears the old reveal state. Layout
repairs also check moved/resized windows and toolbar bounds.

`DockController` shares this behavior between windowed/fullscreen overlays and keeps
normal docked mode unchanged when the option is off. Tests never move a real Safari
window:

```sh
scripts/test-auto-hide.sh
scripts/test-spaces.sh
scripts/test-arc-import.sh
```

For live testing, verify regular Safari at the display edge and inset, entering and
leaving the sidebar, menus/rename/drag retention, toolbar toggle, changing Safari
windows, other apps/Spaces, and returning to docked mode. Existing state and imported
content must remain intact. Rebuilt ad hoc apps can require refreshing their existing
Accessibility entry in macOS Privacy & Security.

## Space-switching performance

`PinnedLibraryIndex` builds ID, sibling-order, flattened-tree, and normalized-URL
lookups once per library change. Folder rows, destinations, and drag targets reuse
these indexes across space switches. `TabStore` shares one-to-one pin/tab matches
between rows and the ordinary tab list; active-first URL queues avoid rescanning
every live tab for every pin. Explicit tab links retain priority. Current-window
selection is also shared rather than recalculated per row.

The caches are transient. Bookmarks/folders, membership, explicit links, snapshots,
and docked-window title changes invalidate the affected results. Cache hits still
read the observable source properties, so SwiftUI observes edits and Safari updates.
State schema, persistence, Safari commands, and drag geometry remain unchanged.

`scripts/test-spaces.sh` exercises warm-cache invalidation, observation, duplicate
URLs, scoped/profile Favorites, folder edits, window changes, and Safari termination.
`scripts/test-space-performance.sh` uses an isolated synthetic library with 1,200
pins, 400 folders, 400 live tabs, and 20 spaces. The initial Release-mode measurement
of selection plus row-data preparation fell from 853 ms median to below 1 ms with
the same semantic checksum. This measures model work, not complete SwiftUI rendering
or Safari's page activation latency. Tests do not send commands to Safari or use
the user's state.

## Emoji icons and empty spaces

Edit Space offers Symbol and Emoji styles. Emoji input accepts a single Unicode
grapheme (including ZWJ sequences, flags, skin tones, and keycaps) and rejects plain
text or several emoji. The Choose Emoji button focuses the field and opens the macOS
character picker. `BrowserSpace.emoji` is optional, so saved symbol icons and their
existing import signatures remain compatible. Header and switcher share `SpaceIcon`;
new Arc imports retain valid source emoji. Existing spaces change only when edited.

Space activation never creates Safari tabs. Creating spaces, switching via icons or
swipes, moving the last tab, and closing the last tab use only existing candidates.
When none exists in this window, a transient background-tab marker keeps routine
snapshots and delayed activations from selecting the old page's space. Choosing a
different native tab or window resumes Safari selection following. Explicit New Tab,
pin opens, and Safari-created tabs retain membership handling and request IDs.
No existing tabs are closed or rewritten as part of this change.

## Command delivery when Safari push fails

Safari can accept snapshots from the extension while `dispatchMessage` fails with
`SFErrorNoExtensionFound`, notably with local unsigned builds. `ExtensionBridge`
therefore uses push only to request a poll. Commands travel in replies on the working
extension-to-app connection. A single outstanding JavaScript poll runs at 250 ms
while Safari is frontmost, backing off to five seconds otherwise or if the app is
unavailable. Focus changes and successful push wakeups request an immediate poll.

`ExtensionCommandQueue` keeps commands for 15 seconds, bounded at 256, scoped to the
requesting Safari instance. Stable command IDs are acknowledged and claimed in
JavaScript before browser API calls, so lost replies/acks and concurrent polls cannot
open a saved pin twice. Explicit request IDs still handle membership and migration
receipts. Old browser sessions cannot receive a previous instance's clicks; app
restart discards this transient queue. Arc restore's durable intent checks remain
separate. Broadcast snapshot requests are acknowledged per instance. Older scripts
without the negotiated deduplication protocol receive no retryable commands.

Reload the extension once after installing this native/background protocol change;
Safari itself need not quit. `scripts/test-command-delivery.sh` covers failed push,
lost replies, concurrent delivery, acknowledgements, expiry, profile isolation,
bounded queues, pin request IDs, and migration safety without accessing Safari.
