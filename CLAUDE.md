# Side Tabs

A Mac menu bar app plus a Safari web extension that shows Safari's tabs in a sidebar.
Building, the release checklist, how it works, and testing the updater are in
@DEVELOPMENT.md.

## Releasing

- A release means the whole **Release checklist** in DEVELOPMENT.md, every time, without
  being reminded: version bump, DMG checks, release notes, publishing, drafting the
  previous release, the README, and checking the live GitHub page afterwards.
- Merging to `main` is not a release. If user-facing changes are merged but unreleased,
  say so: the download links keep serving the old version until a release is published.
- Ask once before anything public on GitHub (publishing, drafting the previous release,
  editing release notes or files, pushing to `main`), then do all of it.
- Check each step's result before the next step that can't be undone. Don't chain a check
  and a publish with `&&`. `strings` can't see short Swift string literals, so check a
  binary for longer text.

## The public page

- README.md is for people using Side Tabs, and short: install, a brief features list,
  troubleshooting. No sections on updating, uninstalling or limitations. Developer notes
  go in DEVELOPMENT.md.
- The maintainer is currently the only user. No notes for people on older versions
  ("coming from 1.0", "1.0 can't update itself") in the README, release notes, or app.
- Releases have only the `.dmg`. The page should list only the current release.

## Testing on the maintainer's Mac

- Don't quit Safari or other apps to test something without asking.
- After testing the updater, remove `UpdateFeedURL`, delete test builds, and reinstall a
  normal build with `scripts/install.sh`.
- Say so before switching apps or opening windows on screen for a test (for example
  `open -a Finder`). The maintainer may be in the middle of something.
- Claude's shell has no Accessibility or Screen Recording access, so it can't read
  Safari's windows or take screenshots. To see what the app decided, run
  `/usr/bin/log show --last 10m --predicate 'subsystem == "com.digitaln.sidetabs"'`; the
  `dock`, `tracker` and `bridge` categories log every state change. To see a window or
  trigger an action, add a temporary hook (for example, a distributed notification that
  snapshots a window with `cacheDisplay`). Then remove it and confirm the installed binary
  no longer contains it.
- If the sidebar disappears after a reinstall and the log says `hidden: no Accessibility
  access`, ask the maintainer to select Side Tabs in Privacy & Security → Device Control
  and Data Access, click −, then add it back with +. An entry created by the system
  prompt can be tied to a single build. Claude can't change that setting.
- The maintainer creates signing certificates in Xcode (Settings → Apple Accounts →
  Personal Team → Manage Certificates). `xcodebuild -allowProvisioningUpdates` can't use
  the Xcode account from Claude's shell. The paid developer membership has lapsed and the
  maintainer doesn't want to renew it yet, so don't plan around Developer ID or
  notarization.

## Git and privacy

- `origin` is the public repo. `private` is an archive whose history contains the
  maintainer's personal email. Never push from it to `origin`, merge it, or cherry-pick
  from it.
- Commits use the GitHub noreply address set in this repo's git config. Don't change it.
- Work on a branch, not `main`. The maintainer opens pull requests with Create PR, which
  needs a branch other than `main`.

## Decisions already made

Don't undo these without asking:

- The sidebar sits flush against Safari's window, with no gap and an opaque background.
  It's ordered directly behind Safari's window, so its corner fills hide under Safari's
  rounded corners.
- In full screen the sidebar hides. A left-edge hover or the toolbar button's shortcut
  slides it out instantly, below Safari's toolbar. Safari opens its own sidebar from that
  same edge and has no setting to stop it; the maintainer accepted that, so don't work
  around it. The sidebar never shows over other Spaces or full-screen videos.
- The address bar shows the site, with reload on the right. Clicking it opens Safari's
  own address bar (⌘L). There's no typing in the sidebar, because extensions can't get
  Safari's history or suggestions.
- Any left or middle click on the sidebar brings Safari forward, and so does picking the
  sidebar in Mission Control. Right-clicking, scrolling and hovering don't.
- Tab renames show only in the sidebar. Reordering uses its own drag gesture
  (`SidebarDrag`), not system drag and drop.
- Onboarding happens in the app, one step at a time, with no instructions in the README
  or in text files. The only text in the disk image is the first-launch Open Anyway hint.
- The disk image's background stays light. Finder draws icon names in black over a
  background picture, even in dark mode.

## Working style

- When fixing a reported problem, think through the related cases and fix the whole
  class, so the maintainer doesn't have to report each one.
