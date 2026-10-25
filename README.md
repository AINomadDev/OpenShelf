# OpenShelf

> **Bring Your Own Storage.** OpenShelf mounts the cloud accounts and buckets you already pay for as folders on your Mac. Installs made before the rename keep using their existing legacy folders and saved connections; nothing is moved.

A local macOS dashboard and menu-bar app with **multiple named accounts and Finder spaces** for Google Drive, iCloud Drive, Amazon S3, Google Cloud Storage, Azure Blob Storage, Cloudflare R2, Backblaze B2, IDrive e2, and S3-compatible endpoints. Uses your existing subscriptions through rclone. There is no OpenShelf server, account, analytics, or storage subscription. Your providers may bill their own storage and data-transfer charges.

This is an initial prototype, not a verified replacement for a backup or the official sync clients. Live authentication and mounted file operations must be verified with your accounts.

## Requirements and setup

- macOS 13+, Swift 5.9+ / Xcode command line tools to build.
- The packaged app includes official rclone v1.75.2. Source builds fetch and verify it using `scripts/fetch-engine.sh`.
- Finder mounts use rclone’s loopback-only NFS server and macOS’s built-in NFS client. No separate driver installation or security-setting change is required. Network file locking and AppleDouble sidecars are disabled for compatibility; do not use this for concurrent editing or files requiring resource forks.

## Add accounts and storage

Choose **Add storage** on the dashboard:

- **Google Drive:** name the account, optionally scope a folder, then authorize in your browser. Additional accounts can reuse the Google app client credentials in your existing default rclone configuration; account tokens are never copied. The first Google app client still needs a desktop OAuth client ID and secret. If that Google project is in Testing mode, add each additional Google account as a test user. Native browser authorization has a five-minute timeout and can be cancelled.
- **iCloud Drive:** each account gets a separate configuration. Apple ID/2FA sign-in opens in Terminal. This backend remains experimental; app-specific passwords do not work and the session needs periodic renewal.
- **Amazon S3:** enter a bucket/prefix, region, access key ID, secret key, and optional session token. Credentials need the relevant bucket read/list permissions; write permissions are required for writable mounts.
- **S3-compatible:** also enter the provider's HTTPS endpoint. Compatibility and supported features vary by service.
- **Google Cloud Storage:** choose service-account JSON credentials and enter a bucket/prefix. The credential data is copied into that space's protected engine configuration; no cloud project or bucket is created.
- **Azure Blob Storage:** enter a container/prefix and scoped HTTPS SAS URL with suitable read/list permissions and, for writable mounts, write permissions.
- **Cloudflare R2:** enter bucket/prefix, your Cloudflare account ID (the endpoint is derived), and an R2 API token's access key pair.
- **Backblaze B2:** enter bucket/prefix and a bucket-scoped application key ID and key (native B2 API).
- **IDrive e2:** enter bucket/prefix, the HTTPS endpoint for your bucket's region, and an access key pair.
- **Wasabi / DigitalOcean Spaces:** enter bucket, the region's HTTPS endpoint and an access key pair. Wasabi bills a 1 TB minimum with 90-day minimum retention; Spaces bundles 1 TB of transfer into its base plan.
- **Guided setup:** the Add storage flow shows numbered steps for each provider with an *Open console* button, and accepts a pasted R2 endpoint URL or an e2 host without `https://`.
- **Archive mode (object storage):** S3, GCS, Azure, R2, B2, e2 and S3-compatible spaces default to archive mode: no auto-mount, longer local caching of downloaded files (72 h) and a longer directory cache so repeat access is not re-billed, a confirmation before opening in Finder, and clear cost notes. Switch a space to live mode from its card menu. Finder previews, Spotlight, and media playback still read file contents, so copy files in and restore deliberately; OpenShelf cannot block reads at the protocol level.
- **Usage dashboard:** each connected space shows stored data. R2, B2 and e2 are compared to the 10 GB free allowance (the allowance is per provider account, so spaces sharing one account add up); Drive/iCloud show account quota when the provider reports it. Object-store usage comes from listing the space, which is billed as requests, so it is cached for 6 hours (`usage.json` beside the connection list) and refreshed on demand.
- **Use an existing rclone connection:** import an already configured remote, with optional folder/bucket scope. This also accommodates other engine-supported backends such as OneDrive, Dropbox, SFTP, and WebDAV; this release does not provide new-account wizards for those providers.

Each space has an independent name, Finder folder, cache, log, control endpoint, read-only choice, and mount-at-startup preference. Newly added names receive a short unique suffix in the Finder folder to avoid collisions. Additional spaces can use the same provider. A space is saved only after its read-access test passes, except iCloud which must first finish interactive Apple sign-in. No write test, bucket creation, file migration, or cloud deletion happens during setup.

Credentials stay out of the connection manifest and process arguments. New-account engine files are stored with owner-only permissions under `~/Library/Application Support/OpenShelf/accounts/`. These are protected local files, not Keychain storage. Existing legacy credentials remain in the default rclone configuration. Encrypted default rclone configurations still require an external unlock mechanism.

Existing Google Drive and iCloud connections from earlier versions migrate without changing credentials, Finder paths, or caches. The secret-free connection list is at `~/Library/Application Support/OpenShelf/connections.json`. Corrupt or conflicting manifests are refused instead of silently resetting connections. A disconnected space can be removed from its card's More menu; removal keeps cloud files, credentials, and cache data.

Cloud object storage may charge for requests and downloads. Cold/archive objects may require restoration. These backends do not provide all normal filesystem semantics: rename, locking, folder, metadata, and trash behavior vary. Do not assume a cached cloud mount is a backup or a distributed file-locking system.

## Build and install

```sh
./scripts/fetch-engine.sh
./scripts/test-core.sh
./scripts/build-app.sh
open dist/OpenShelf.app
```

Drag `dist/OpenShelf.app` into Applications to install for regular use. The build is locally ad-hoc signed, not notarized for public distribution. Open the dashboard, connect each account, then choose Open drive and Show in Finder. Closing the dashboard leaves the menu-bar app running..

Finder locations: new installs use `~/OpenShelf/<name> · <unique suffix>`. Installs that predate the rename keep using their existing legacy folders for mounts, data, caches and logs.

Caches live separately under `~/Library/Caches/OpenShelf/`; logs under `~/Library/Logs/OpenShelf/`. Add either mounted location to Finder Favorites if desired. Existing iCloud/Google sync folders are not used as the backing storage.

## Platforms and design notes

- **macOS only.** The UI is native SwiftUI/AppKit, and mounting uses macOS's NFS client and launchd. Windows and Linux would need a separate UI and different mount/service layers (WinFsp or FUSE, Task Scheduler or systemd); they are not implemented.
- **JuiceFS was considered and not adopted.** It stores files as opaque chunks plus a separate metadata database, so objects would no longer be readable in the R2/B2/e2 console or other tools, and on macOS it needs macFUSE. That conflicts with keeping your data usable in its provider's own tools.
- **Secrets:** never commit credentials. Account files live under `~/Library/Application Support/OpenShelf/` (owner-only) and are outside this repository.

## Behavior and limitations

- Files are fetched on demand using rclone's virtual filesystem. Each drive has a 5 GB cache target, not a hard disk limit: open files and uploads can exceed it. This is not zero-disk storage.
- Writes are cached and uploaded asynchronously. Never delete the cache while uploads are pending. Each drive runs as its own background launchd job, so quitting or updating the app does not interrupt uploads; inspect logs and verify important uploads using the provider's website.
- Mount readiness is checked against the system mount table. Cache use and queued/active uploads come from authenticated, loopback-only rclone control endpoints. Disconnect requires current transfer stats with no queued/active uploads, errors, or out-of-space state, then a normal OS unmount. No forced unmount is used for user drives. A mounted drive is not proof all cloud data is synced.
- Close open files and finish uploads before unmounting. Quitting the app leaves mounted drives (and their uploads) running; reopening it reattaches. Use Disconnect to stop a drive. Drives started by a pre-launchd version are not adopted: disconnect them from that version first. No forced unmount, sync deletion, automatic file migration, or cache purge is performed.
- Encryption is **optional and off by default**, available for object storage when you add a space (an rclone `crypt` overlay encrypts names and contents before upload). Encrypted files are unreadable in the provider's own console and apps, and losing the key loses the files, so use **⋯ › Copy encryption recovery key** and store it safely. It cannot be switched on later for a space that already holds files. Without it, files stay readable in the provider's own tools.
- Google-native Docs/Sheets are not ordinary binary files and have rclone export/mount limitations. Offline pinning, shared-link UI, conflict resolution, automatic session renewal are not implemented.
- Avoid concurrent editing of the same file through multiple clients. This is remote access, not distributed file locking.

## Manual verification after sign-in

1. List your saved remotes with `rclone listremotes`, then check each with `rclone lsd <remote>:`.
2. Mount each separately. Confirm both Finder locations appear and provider contents are distinct.
3. Copy a disposable test file to each mount, wait for upload, and verify contents on each provider's website.
4. Open and seek in a large disposable video; watch cache growth and check behavior when the network disconnects.
5. Close files, wait for uploads, unmount normally, remount, and verify test file contents again.

Do not claim production readiness until these account-dependent checks pass.

## Verified locally

The standalone core checks cover provider isolation, loopback binding, required NFS options, and refusal to disconnect with pending or failed uploads. A disposable local backend was mounted on this Mac; reads, write-back, and normal unmount succeeded after adding `nolocks,noappledouble`. The installed dashboard was launched and inspected, and the guide and iCloud connection launcher were exercised. The authenticated local control endpoint returned transfer stats and rejected unauthenticated access. Cloud authentication and small-file read/write were subsequently verified on both providers. Media-app compatibility and intermittent-network behavior remain unverified. NFS mounting and the iCloud backend are experimental upstream.

Run `python3 scripts/test-mount.py` outside restrictive execution sandboxes for the disposable mount integration check. It creates its own folders under `.build`, uses a dedicated loopback control port, and never reads cloud files. Test folders and logs remain available for diagnosis.

## Disk-space safeguards

New mounts require at least 10 GiB of available disk space; unknown capacity also blocks a new mount. The dashboard shows free disk space and a low-space warning. Each rclone cache targets 5 GiB and a 10 GiB minimum free-space reserve, with cache checks every 10 seconds. These targets are shared against the same disk, not separate reservations. Open files, pending uploads, and unrelated applications can exceed them: this is not a hard disk quota or a guarantee against a full SSD. Existing drives are not forcibly stopped and pending data is never deleted by the app.

## Partial-video benchmark

`scripts/test-streaming.py` uploads `.build/stream-check/sample.mov` to a new, clearly named folder in each provider, decodes frames at 0 and 20 seconds through fresh isolated caches, compares decoded frame hashes against the source, and records download counts, allocated cache bytes, and timing in `.build/stream-check/results.json`. It requires FFmpeg. Samples remain in the cloud for inspection; the script never deletes user data. This is a partial-read test, not a DaVinci Resolve compatibility or editing-performance test.

## Login and automatic mounts

The installed app registers with macOS Login Items on its first launch. The sidebar reports the actual macOS registration state and opens Login Items if approval is needed. Later changes in System Settings are respected. Saved Google Drive and iCloud connections mount automatically on app launch; failed mounts retry at most once per minute while the app is running, allowing networking to become available after login. Manual Disconnect pauses that drive's automatic mounting until the next app launch or an explicit Open drive action. New mounts still require the disk reserve. Expired credentials require interactive Reconnect; the app never opens sign-in prompts automatically. Login occurs after signing in to your Mac, not before disk unlock. Do not move the installed app without checking Login Items again.

Normal quit/logout requests try to unmount idle drives before exiting. Open files, pending uploads, unavailable transfer stats, or failed normal unmounts keep the app running and request attention; it never forces an unmount. An actual macOS reboot has not been performed during verification.

## Multi-account verification

Core checks cover preserved legacy paths, multiple accounts of the same provider, distinct caches/configs/ports, read-only engine flags, manifest persistence, duplicate/corrupt manifest refusal, and OAuth output parsing. Provider setup fields were checked against the bundled engine schema. Live testing for newly added AWS, GCS, Azure, and S3-compatible services requires credentials and has not been completed. A real second Google identity also requires its own browser authorization before it can be claimed verified.

## Editing and quota notes

- Use **Edit details…** in a card menu (or **Edit** in the desktop app) to change the name, bucket or folder, read-only, auto-mount and archive mode. You can also replace object-storage credentials; saved secrets are never displayed, and the old ones are restored if the new ones fail the access test. Disconnect the space first.
- Google Drive and iCloud: iCloud Drive and Google *Shared Drives* do not report a storage total, so the dashboard says "not reported". Personal My Drive accounts show used and remaining space.

- **Account info and labels:** each card shows which account it belongs to (Google email and name, the iCloud Apple ID or phone number, the GCS service account, or the S3 endpoint host), plus your own tags and a note. Labels are searchable and can be edited even while a drive is mounted; name, location, access and credentials need the drive disconnected.
- **Google Shared Drives** report no quota of their own, so OpenShelf shows your whole Google account's usage and limit instead (marked "whole Google account"). iCloud Drive has no public quota API, so OpenShelf asks Apple's web service using the sign-in session rclone already stores (used and total for the whole iCloud account, kept in memory only). If that session has expired, use **Measure size now** in the card menu to total the files instead (slow on large drives).
- **Renaming:** the display name can be changed even while a drive is mounted; the Finder folder keeps its name until you next edit with the drive disconnected.
- Account details are read in memory from your own rclone config and the Google Drive API; only the email, name or host is saved, never tokens or passwords.

- **Pricing info:** the ⓘ button on object-storage cards opens a pay-as-you-go summary (storage per GB, egress, request fees, free tier) with an estimated monthly storage bill for what you have stored, and a link to the provider's pricing page. These are approximate list prices for standard tiers in US regions, so check the provider before relying on them.

- **Costs and budgets:** the usage panel totals the estimated monthly storage cost across spaces (free tiers are applied per space, which can overstate the total if spaces share one provider account). Set a monthly budget in **Edit details**; you are warned at 80% and when over. The archive-open confirmation shows the egress an entire restore would cost on S3, GCS and Azure.
- **Growth forecast:** each refresh records one size sample a day (`history.json`). Once there are two days of data, free-tier spaces warn if the current growth will pass 10 GB within 60 days.
- **Archive folder / Verify archive:** the card menu of an object-storage space can copy a local folder straight to the space (copy only, never deletes; junk, `node_modules` and `.git/objects` are skipped) and compare it afterwards by checksum. These run while the app is open, unlike mounts; re-running resumes by skipping files already uploaded.
- **Credential health:** Azure SAS tokens are checked for their `se=` expiry and flagged in the usage panel within 14 days.
- **Menu bar:** shows estimated cost, active uploads and spaces near their allowance.
- **Pages and sidebar:** *Activity* and *Costs & budgets* open as full pages. Activity shows live uploads, queue, errors and cache per space, running archive/verify tasks, and a saved history of recent messages (`events.json`, newest first, cleared on demand). Costs shows stored size, estimated cost, restore cost, growth and a trend line per priced space, with inline budgets. Sidebar quick views filter to mounted spaces, archive spaces and spaces that *need attention* (upload errors, full cache, near or over an allowance or budget, expiring credentials).
- **Cloudflare R2 analytics (optional):** in **Edit details** add an API token with *Account Analytics: Read*. OpenShelf then reads month-to-date storage and Class A/B request counts from Cloudflare's GraphQL Analytics API (no billed list requests), shows them against the free 1M/10M monthly requests, and adds estimated request charges to the cost. The token is stored in an owner-only file and sent only to `api.cloudflare.com`; if it is rejected the app falls back to listing the bucket. Spaces in the same R2 account share one 10 GB free tier in the cost estimate.
- **Tokens per account:** the Cloudflare token is saved once per Cloudflare account, so every R2 space in that account shares it (Edit details says how many). You can have several accounts per provider, each with its own token.
- **Tooltips:** hover the usage figures, mode chips, status, totals and cost. They explain what the state means for your bill: pay-as-you-go once an R2/B2/e2 free tier is used up, per-GB billing for GCS/S3/Azure, and fixed plans for Google Drive/iCloud (full means you must free space or buy more).
- **Backblaze B2, IDrive e2 and other S3 providers** expose no usage or billing API for storage keys (those live behind the account login), so their size comes from listing the bucket and costs are list-price estimates.
- **Alerts:** macOS notifications fire once when a space crosses 80% or 100% of its allowance, nears or exceeds its budget, or uses up R2's free request allowance. They re-arm after the situation improves. Allow notifications for OpenShelf in System Settings.
- **Shelf totals:** the dashboard shows everything stored across all spaces, the space left in accounts with a fixed plan (Google, iCloud; shared accounts count once) and what remains of the 10 GB free tiers.
- **Windows/Linux app:** shows the same shelf totals (stored, free tier left, estimated monthly cost) and a per-type account list, with R2 spaces in one Cloudflare account sharing a free tier.
- **Shared catalogue:** `providers.json` is the reference for provider names, backends, free tiers and list prices; tests on the Mac and desktop sides fail if either drifts from it.
- **Sidebar:** *Your Accounts* lists one row per storage type (Google Drive, Cloudflare R2, Backblaze B2, IDrive e2…) with space count and size; click to filter. Also quick views, quick views, tag chips that filter spaces, an Add storage button and a status card with estimated cost, attention count and active uploads.
- Releases: pushing a `v*` tag builds unsigned macOS, Windows and Linux artifacts (`.github/workflows/release.yml`).

Run `./run.sh` (macOS/Linux) or `run.cmd` (Windows) to start the right app for your OS.

## Windows and Linux (preview)

`desktop/` contains a Tauri app with the same model: bring-your-own storage, archive mode, free-tier usage, and drives that run as detached rclone processes so uploads survive closing the app.

Requirements: [rclone](https://rclone.org/install/) on PATH (or next to the app), plus [WinFsp](https://winfsp.dev/) on Windows or FUSE (`fuse3`) on Linux.

```sh
cd desktop/src-tauri && cargo test && cargo run
```

The desktop app also supports tags and notes (editable while connected), cost estimates and Wasabi / DigitalOcean Spaces.

Status: unit tests run in CI on Linux, Windows and macOS. Mounting has only been exercised on macOS so far, so treat Windows/Linux as untested preview. Google Drive and iCloud (interactive sign-in) are macOS-only for now.
