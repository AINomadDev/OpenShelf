# Multi-account and provider setup verification

Implemented and installed:

- Multiple named spaces for Google Drive and iCloud; independent Finder directories, cache directories, logs, control ports, and startup/read-only preferences.
- Native setup for additional Google accounts, with locally reused app client credentials and a fresh browser authorization/token for each identity.
- Native setup forms for AWS S3, GCS service accounts, Azure scoped SAS URLs, and HTTPS S3-compatible endpoints.
- Import of supported remotes already present in the default rclone configuration, including optional folder/bucket scope.
- Read-only access testing before saving new spaces, except iCloud's interactive Apple sign-in.
- Local-only removal of disconnected spaces; cloud files, credentials, and cached data are retained.

Verified:

1. Existing Google Drive and iCloud records migrated without changing legacy Finder paths or caches, then automatically mounted in the installed app.
2. Core checks passed for account/config/cache/port isolation, provider mappings, read-only flags, persistence, migration, duplicate/corrupt manifest rejection, path validation, disk reserve, startup retries, and authorization response parsing.
3. Provider credential option names match the bundled rclone engine's schemas.
4. The native form imported the existing Google connection as a second simultaneous read-only space. Its known test file read correctly, and file creation was rejected.
5. All three spaces normally unmounted on quit; the extra space persisted and automatically remounted after relaunch.
6. The temporary test space was normally disconnected and removed through the local-only confirmation. Both original spaces remain.
7. Provider picker and AWS/GCS/Azure-specific fields were inspected in the installed app. Incomplete S3 setup showed a validation error before creating a connection or making a cloud write.
8. Installed app signature verified and the final release build completed.

Limits:

- The Professional Google space was subsequently saved through native authorization using its own configuration. Mounted directory access, a small mounted write/read, and exact direct Google Drive read-back succeeded. Google identity IDs were not compared; the identity is selected by the user during browser consent. Testing-mode projects must include additional identities as test users.
- New AWS, GCS, Azure, S3-compatible, and additional iCloud accounts have not been live-tested without their authorized credentials. Schema checks and native forms do not establish full compatibility with every provider.
- The repeated-Google test used two spaces pointing at the same existing Google account. It verifies simultaneous mounts and read-only isolation, not distinct account identities.
- Additional credentials use protected engine configuration files, not Keychain or an added encryption layer. OAuth tokens are never copied between Google accounts.
- OneDrive/Dropbox/SFTP/WebDAV support in this release is through importing an already configured rclone remote, not a new-account wizard.
- An actual Mac reboot remains untested; login registration and relaunch auto-mount were verified.

## Professional interruption report

After an interrupted-server alert was reported, the current Professional NFS process and listening endpoint were healthy, the kernel mount referenced the same live port, and direct provider access succeeded. A mounted directory metadata read completed in 0.043 seconds; a generated small file passed mounted write/read and exact cloud read-back. Finder no longer showed the alert when inspected. The mount log contained startup notices without a recorded failure. The earlier interruption was not reproduced and its cause remains unknown; no speculative code fix or forced unmount was applied.
