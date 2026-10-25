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
- **Guided setup:** the Add storage flow shows numbered steps for each provider with an *Open console* button, and accepts a pasted R2 endpoint URL or an e2 host without `https://`.
- **Archive mode (object storage):** S3, GCS, Azure, R2, B2, e2 and S3-compatible spaces default to archive mode: no auto-mount, longer local caching of downloaded files (72 h) and a longer directory cache so repeat access is not re-billed, a confirmation before opening in Finder, and clear cost notes. Switch a space to live mode from its card menu. Finder previews, Spotlight, and media playback still read file contents, so copy files in and restore deliberately; OpenShelf cannot block reads at the protocol level.
- **Usage dashboard:** each connected space shows stored data. R2, B2 and e2 are compared to the 10 GB free allowance (the allowance is per provider account, so spaces sharing one account add up); Drive/iCloud show account quota when the provider reports it. Object-store usage comes from listing the space, which is billed as requests, so it is cached for 6 hours (`usage.json` beside the connection list) and refreshed on demand.
- **Use an existing rclone connection:** import an already configured remote, with optional folder/bucket scope. This also accommodates other engine-supported backends such as OneDrive, Dropbox, SFTP, and WebDAV; this release does not provide new-account wizards for those providers.

Each space has an independent name, Finder folder, cache, log, control endpoint, read-only choice, and mount-at-startup preference. Newly added names receive a short unique suffix in the Finder folder to avoid collisions. Additional spaces can use the same provider. A space is saved only after its read-access test passes, except iCloud which must first finish interactive Apple sign-in. No write test, bucket creation, file migration, or cloud deletion happens during setup.

Credentials stay out of the connection manifest and process arguments. New-account engine files are stored with owner-only permissions under `~/Library/Application Support/OpenShelf/accounts/`. These are protected local files, not Keychain storage or an added encryption layer. Existing legacy credentials remain in the default rclone configuration. Encrypted default rclone configurations still require an external unlock mechanism.

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
- No additional end-to-end encryption layer is enabled. Files retain the provider's own protection and remain usable in its official apps.
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

Run `./run.sh` (macOS/Linux) or `run.cmd` (Windows) to start the right app for your OS.

## Windows and Linux (preview)

`desktop/` contains a Tauri app with the same model: bring-your-own storage, archive mode, free-tier usage, and drives that run as detached rclone processes so uploads survive closing the app.

Requirements: [rclone](https://rclone.org/install/) on PATH (or next to the app), plus [WinFsp](https://winfsp.dev/) on Windows or FUSE (`fuse3`) on Linux.

```sh
cd desktop/src-tauri && cargo test && cargo run
```

Status: unit tests run in CI on Linux, Windows and macOS. Mounting has only been exercised on macOS so far, so treat Windows/Linux as untested preview. Google Drive and iCloud (interactive sign-in) are macOS-only for now.
