# OpenShelf storage expansion proposal

Status: native setup forms and multiple saved spaces are implemented for Google Drive, iCloud, AWS S3, GCS, Azure Blob, and S3-compatible storage. Live object-storage validation remains pending authorized accounts. Later phases below remain proposals. The current implementation uses one persisted record per space, including its engine configuration reference, rather than introducing separate connection and mount tables.

## Product direction

A native Mac app that gives storage you already own a consistent place in Finder, with clear disk usage, transfer state, and connection recovery. Keep the current warm visual style. Replace the two fixed cards with a responsive collection of named spaces and a clear Add storage action. Do not expose engine flags, backend identifiers, or developer terminology in normal flows.

## First implementation

Support AWS S3, Google Cloud Storage, Azure Blob Storage, and custom S3-compatible endpoints alongside the existing Google Drive and iCloud connections. Allow multiple accounts and multiple bucket/prefix mounts. Include native provider-specific setup, connection testing, read-only mounts, and per-space automatic mounting. Do not create buckets, cloud projects, permissions, or billable resources automatically.

Add storage flow:

1. Choose a provider: Personal cloud, Object storage, or Server/NAS.
2. Connect: show only the fields required by the selected authentication method. Explain where to obtain credentials. Offer an existing supported credential profile where available. Never ask for a domain for a personal desktop connection.
3. Choose a scope: folder, bucket, container, and optional prefix. Support entering a known bucket/container directly when account-wide listing is not permitted.
4. Test access: distinguish authentication, permissions, network, and unsupported storage class. Read tests must not silently write objects; offer a clearly explained write test for writable connections.
5. Name the Finder space, choose read-only or read/write and automatic mount behavior, and review the cache policy.

AWS setup: region, bucket, optional prefix, and a supported scoped credential method. Custom S3 endpoints additionally need endpoint URL and provider-specific compatibility options. Do not treat all S3 implementations as identical.

GCS setup: bucket/prefix and a supported Google identity or service-account credential source. GCS is a separate service from a Google Drive subscription.

Azure setup: storage account/container/prefix and a supported identity or scoped SAS credential. Do not require account-wide keys if a narrower credential works.

## Small, explicit architecture

Replace the fixed Storage enum with two persisted records and provider metadata:

- Connection: stable identifier, provider, label, rclone remote reference, and credential reference. No secret values in the app manifest.
- Mount: stable identifier, connection identifier, remote root, Finder name/path, unique cache/log paths, read-only choice, and auto-mount preference.
- Provider metadata: display name, icon, setup fields, documentation link, and actual capabilities. Start with a local registry; a plugin framework is not needed.

Continue using rclone behind a single engine boundary for commands and authenticated local control. Keep retries, exit-code handling, mount readiness, and validation deterministic. Allocate collision-free control endpoints per running mount. Operations on one slow provider must not delay monitoring every other drive.

Track explicit per-mount states: disconnected, connecting, mounted, offline, authentication required, upload pending, and error. A saved configuration alone does not establish working authorization. Do not launch interactive sign-in repeatedly during automatic retries.

Keep long-lived secrets in Keychain where the integration supports it; protect engine-owned OAuth token configuration on disk. Never expose credentials in process arguments, UI logs, exported diagnostics, or the manifest. Token refresh and credential persistence need an explicit tested design before replacing the current authentication flow.

Preserve the existing openshelf-google and openshelf-icloud remotes, Finder folders, and caches during migration. Adopt them as initial connections/mounts without copying or deleting files. Migration must be idempotent and must not leave two processes sharing the same cache.

## Capability differences

Object stores are not ordinary filesystems. Buckets/containers must be explicitly scoped. Renames may be copy-and-delete rather than atomic; empty folders, symlinks, metadata, locking, trash, quota reporting, and version history differ. Show unsupported capabilities as unavailable, never emulate them silently or report invented capacity.

Cold/archive storage may need restoration before access. Reading object storage can incur request and data-transfer charges. Show this during setup and provide observed bytes/request activity where available; do not invent a live currency estimate without provider pricing, region, and billing data.

## Feature priorities

Phase 1 — practical multi-provider app:

- Native Add storage wizard and responsive cards.
- Multiple saved connections, bucket/folder mounts, read-only option.
- Per-mount auto-connect controls and clear reconnect/error states.
- Global cache budget plus free-space reserve; keep current safeguards during migration.
- Transfer panel showing active, queued, failed, and completed operations.
- Disconnect/remove actions that distinguish removing a connection from deleting cloud files.

Phase 2 — daily use and recovery:

- Offline pinning with explicit disk usage and unpin behavior.
- Safe reclaim action for clean, closed cache data only.
- Bandwidth controls and large-upload recovery status.
- Opt-in folder metadata search; no automatic content downloads for indexing.
- Redacted diagnostic export and notifications for actionable failures.
- Credential expiration recovery and signed/notarized app updates.

Phase 3 — media workflow, after measurement:

- Playback/seek diagnostics and measured recommendations for cache/prefetch settings.
- Optional project working sets and proxy workflow assistance.
- DaVinci Resolve compatibility testing across representative codecs and timelines.
- Optional encrypted spaces with an explicit key-recovery design.
- Additional providers: OneDrive, Dropbox, Backblaze B2, SFTP, WebDAV, and supported NAS connections.

Do not add automatic destructive synchronization, a combined writable pool, multi-device conflict resolution, or an AI assistant in the first expansion. They are separate product and data-integrity commitments.

## Verification gates

1. Existing Drive/iCloud migration preserves credentials, mount folders, cache separation, and startup behavior.
2. Native setup handles cancelled authentication, wrong credentials, limited bucket permissions, and direct known-bucket entry.
3. Two mounts of one connection and two connections of one provider have independent endpoints, caches, and lifecycle state.
4. Verify read, write, upload completion, normal quit/unmount, relaunch, partial-video seeking, offline recovery, and low-disk behavior per provider.
5. Test S3-compatible behavior with a disposable local service; separately verify AWS, GCS, and Azure against authorized accounts before claiming them live-tested.
6. Verify read-only protection at the engine boundary and confirm diagnostics contain no credentials.

Live AWS/GCS/Azure verification requires user-provided authorized accounts or test resources. Supporting configuration is not equivalent to completing those live tests.

## Sources

- https://rclone.org/overview/
- https://rclone.org/s3/
- https://rclone.org/googlecloudstorage/
- https://rclone.org/azureblob/
