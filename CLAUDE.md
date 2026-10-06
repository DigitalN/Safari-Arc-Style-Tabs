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
