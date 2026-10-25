# Media archive setup

## Selected configuration

| Setting | GCS | AWS S3 |
| --- | --- | --- |
| Bucket | `example-media-archive-gcs` | `example-media-archive-s3` (proposed) |
| Region | `asia-south1` — Mumbai | `ap-south-1` — Mumbai, pending account availability |
| Class | Standard | Standard |
| Public access | Prevented | Block all public access |
| Object ACLs | Uniform bucket-level IAM | Disabled / bucket owner enforced |
| Encryption | Google-managed | SSE-S3 |

Use Standard for media that OpenShelf should open directly. Do not transition active media into Glacier Flexible Retrieval or Deep Archive: objects need restoration before reading. GCS cold classes remain online but have retrieval and minimum-duration costs.

The GCS bucket was created and verified in `your-gcp-project-id`. Seven-day soft delete is enabled; deleted data continues to occupy billable storage during that period. Object versioning and retention locks were not enabled.

## GCS account and permissions

Dedicated service account: `openshelf-media-archive@your-gcp-project-id.iam.gserviceaccount.com`.

The console reported service account creation. It was created without project-level roles or access grants to other principals. The bucket permission grant and JSON key creation are pending confirmation; the account is not yet a working OpenShelf connection.

1. Open the bucket, then **Permissions → Grant access**.
2. Add the service account above.
3. Select **Storage Object User** (`roles/storage.objectUser`) on this bucket only. This permits object read/create/update/delete, without project administration or object ACL management. Do not grant project Editor, Owner, or Storage Admin.
4. After confirming the access grant, open **IAM & Admin → Service Accounts → openshelf-media-archive → Keys → Add key → Create new key → JSON**. Store the downloaded key privately; never paste its contents in chat or commit it.
5. OpenShelf → Add storage → Google Cloud Storage. Name: **Media Archive · GCS**. Bucket path: `example-media-archive-gcs`. Choose the JSON file. Leave read-only off and enable automatic mounting.
6. Use bucket-level IAM mode (`bucket_policy_only = true`) in rclone. OpenShelf's updated connection setup supplies this setting.

If an access test fails, inspect the exact missing permission before adding roles. Do not broaden access to the whole project. A service-account key is a persistent credential; revoke it if lost or no longer needed.

## AWS least-privilege user

Current AWS account experience restricts this project to Sydney. The Mumbai console explicitly requires a plan upgrade and advanced features. The user must complete any upgrade/activation themselves; activation warns that it is irreversible and removes existing spend limits. No S3 bucket or IAM user has been created yet.

When the chosen region is available:

1. Create a general-purpose bucket with the proposed name above, in the agreed region. Keep Block all public access enabled, ACLs disabled, and SSE-S3 encryption. Do not enable Object Lock or change billing plans as part of bucket creation.
2. IAM → Users → Create user: **openshelf-media-archive**. Do not enable AWS Management Console access. Do not attach managed administrator or S3FullAccess policies.
3. Create a customer-managed or inline policy using [aws-media-archive-policy.json](aws-media-archive-policy.json). Attach it only to this dedicated user after reviewing/confirming the grant.
4. The policy permits listing the dedicated bucket and reading, writing, deleting, and managing multipart uploads within it. It does not grant bucket creation/deletion, bucket policy changes, object ACL changes, or listing all account buckets. Keep this user out of groups with broader permissions.
5. Create an access key for a local application only after access-grant confirmation. Save the secret directly into OpenShelf's secure input or a protected local file. Never use root access keys.
6. OpenShelf → Add storage → Amazon S3. Name: **Media Archive · S3**. Bucket path: `example-media-archive-s3`. Region: actual bucket region. Supply the user's access key and secret. Leave session token blank for an IAM user key.
7. Use `no_check_bucket = true` so rclone does not require bucket-creation permission. Leave the S3 ACL setting empty for this bucket; the app does not need PutObjectAcl.

The S3 policy controls object deletion as requested. Without versioning, deleted S3 objects may not be recoverable. Decide separately whether to enable versioning and a lifecycle for old versions; retaining versions increases storage usage.

## Verification after connecting

- List the dedicated bucket using the new credential.
- Upload a small uniquely named verification file, read it back, and compare content.
- Test deletion only on that disposable file, with explicit confirmation where required.
- Verify reading an unrelated bucket and creating a new bucket are denied. An empty-bucket listing alone is not proof of read/write permissions.
- Relaunch OpenShelf and verify the saved connections mount automatically.

Neither bucket is included in Google Drive or iCloud subscriptions. Storage, requests, and downloads are billed separately. No media migration or bulk upload has been performed.

## References

- https://docs.cloud.google.com/storage/docs/creating-buckets
- https://docs.cloud.google.com/storage/docs/access-control/iam-roles
- https://rclone.org/googlecloudstorage/#gcs-bucket-policy-only
- https://rclone.org/s3/#s3-no-check-bucket
- https://docs.aws.amazon.com/AmazonS3/latest/userguide/using-with-s3-policy-actions.html
