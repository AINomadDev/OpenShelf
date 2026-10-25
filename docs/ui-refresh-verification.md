# UI refresh verification — 2026-10-25

Installed build: `~/Applications/OpenShelf.app`.

## Changes

- Compact dashboard, shared rounded controls, provider badges and account cards.
- Account search, provider menu, mounted-only filter and sidebar account shortcuts.
- Live activity sheet with cache, queued uploads and error counts; missing status is shown explicitly.
- Three-step Add storage flow: provider, connection details, review. Credentials are excluded from review.
- Copy Finder path action alongside existing logs and removal actions.
- Explicit directory hints when constructing mount URLs prevent Foundation from probing an NFS mount on the main thread.

## Checks performed

- Release build, app signing verification and standalone core checks passed.
- All three saved spaces automatically mounted after relaunch; UI remained responsive.
- Search for Professional displayed one matching space; resetting restored three.
- Mounted-only switch toggled; all three mounted spaces remained visible.
- Activity displayed Google Drive and iCloud cache/upload counts. Professional temporarily showed unavailable status, then returned to 4 KB cached and no uploads.
- Google Drive setup reached review with a temporary name; cancellation returned to the original three accounts without starting OAuth.
- GCS empty-name validation displayed its error; Back navigation retained provider selection.
- Dashboard and connection form were visually inspected. Provider menu width was corrected.

## Limits

- Provider menu options were exposed in accessibility, but automated menu selection repeatedly failed or timed out; filtering by selecting a menu item was not confirmed end-to-end.
- Copy-path clipboard contents were not checked.
- No fresh object-storage credentials or new cloud writes were used for this UI verification.
- The main-thread NFS path probe was reproduced in a process stack sample; normal unmount recovered the old build, and the directory-hint fix was verified by relaunch with three mounted spaces.
