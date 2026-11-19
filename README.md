# Photos Backup to Azure Blob Storage

<p align="center">
  <img src="logo.svg" alt="Photos Backup icon" width="180">
</p>

A macOS command-line backup for the accessible Photos library. It stores original resources and the current rendered representation in an existing Azure Blob container. It does not modify Photos or delete remote objects when assets are removed locally.

## Build and package

Requires macOS 13 or newer, Swift 6, and Xcode command-line tools. The implementation was built on macOS 27.2.1 arm64 with Xcode 27.2 / Swift 6.4.2.

```sh
swift build
swift test
swift build --configuration release --product photo-backup
```

The release is one raw executable named `photo-backup-macos-arm64`; it contains the Photos permission description and stable bundle identifier in its Mach-O `__info_plist` section. It is code-signed with the same self-signed identity on each release, so macOS can recognize the executable across updates. [Apple documents embedded Info.plist sections for command-line tools](https://developer.apple.com/documentation/xcode/build-settings-reference) and the [required Photos usage-description key](https://developer.apple.com/documentation/bundleresources/information-property-list/nsphotolibraryusagedescription).

Download that single file from the latest GitHub release, put it at a stable path, and make it executable:

```sh
mkdir -p ~/.local/bin
curl -fL https://github.com/PabloZaiden/icloud-photos-to-azure/releases/latest/download/photo-backup-macos-arm64 -o ~/.local/bin/photo-backup
chmod 755 ~/.local/bin/photo-backup
```

Self-signed releases are not notarized and do not satisfy Gatekeeper's trusted-developer check; macOS may ask you to approve the downloaded executable. Publishing a GitHub release starts `.github/workflows/release-macos.yml`. It builds and tests on an arm64 macOS runner, signs and verifies the standalone binary, and attaches only `photo-backup-macos-arm64`. The workflow needs repository Actions secrets `PHOTOS_BACKUP_SIGNING_IDENTITY_P12_BASE64` and `PHOTOS_BACKUP_SIGNING_P12_PASSWORD`; the signing key is not stored in git. GitHub secrets are available to trusted repository workflows, not pull requests from forks. Do not print or commit the P12 or password.

## Run

Azure CLI authentication needs only the storage account name. Sign in once if needed, then use the command sequence below:

```sh
az login
photo-backup config --storage-account "storageaccount"
photo-backup authorize
photo-backup doctor
photo-backup sync --dry-run
photo-backup sync
photo-backup service install
```

`config` creates the private config automatically. For AccountKey or SAS instead, run `photo-backup config --connection-string`; it prompts with input hidden. The executable uses the existing `photos-backup` container and prefix, so neither belongs in the config. The active Azure CLI subscription is used; run `az account set --subscription ...` first only if needed.

Azure CLI asks for a token scoped to Storage, keeps it in memory, and refreshes it before expiry. It does not write the token to config, journal, or logs. Azure CLI persists the signed-in account's refresh credentials for later token requests; the daily LaunchAgent runs as that same macOS user. The executable finds `az` on `PATH` and common Homebrew paths. [Azure CLI documents token expiry and how `az login` stores the session](https://learn.microsoft.com/en-us/cli/azure/authenticate-azure-cli-interactively).

The storage account must have an existing `photos-backup` container. The signed-in user needs **Storage Blob Data Contributor** on the container or account; Azure management roles such as `Owner` by themselves do not grant blob data access. [Microsoft documents the Blob data roles](https://learn.microsoft.com/en-us/azure/storage/blobs/authorize-access-azure-active-directory). Config files and internal settings are written with mode `0600`; runtime paths, limits, retries, logging, library ID, and daily 2:00 AM schedule use private defaults.

## Authorize and check

Use the installed command:

```sh
photo-backup authorize
photo-backup doctor
```

`authorize` requests full Photos read access. Limited Photos access is not enough for a whole-library backup. `doctor` checks that full authorization is present, the spool directory is writable, and an isolated temporary blob can be written, read, and deleted under the configured prefix. It does not export a photo, validate every library item, check iCloud synchronization completeness, or prove backup fidelity.

## Sync

```sh
photo-backup sync
photo-backup sync --from 2024-01-01
photo-backup sync --to 2024-12-31
photo-backup sync --from 2024-01-01 --to 2024-12-31 --dry-run
```

With no dates, the command enumerates the full accessible library on every run; it does not use a last-run watermark. Dates use the Photos capture date in the Mac's current time zone, and both ends are inclusive. Missing capture dates are included only without a filter; with a filter, they are reported as unclassifiable and the run exits nonzero. A dry run queries Photos inventory and Azure manifests but does not export/download resources, write blobs, update manifests, or clear recovery state. It reports `would upload` candidates; a changed source date may need export/hash comparison in a real run, so this is an estimate.

Each `PHAssetResource` original is considered independently, including photo/video components of Live Photos, alternate RAW/JPEG resources, audio, and hidden assets. The current representation prefers Photos' full-size rendered photo, video, or paired-video resource. If that resource is absent, the executable asks Photos for its current rendered editing input (and a current Live Photo for the motion component) with network access enabled. When the asset has no edits, the original is the current representation. If Photos cannot supply a current render, the resource fails visibly instead of backing up the wrong bytes.

Resource identity uses the Photos asset local identifier, representation, resource kind, and a digest of the UTI. Filename and enumeration order are not identity. If one asset contains multiple indistinguishable resources with the same kind and UTI, the run flags incomplete coverage and skips those resources rather than assigning unstable ordinals. Local identifiers are specific to one Photos library and are not cross-Mac deduplication IDs.

The PhotoKit inventory enables both hidden assets and all burst frames. PhotoKit does not provide a verified full-library export path for Recently Deleted, and Shared Albums coverage has not been validated; this tool does not claim those collections are backed up. Album organization, faces, edit history, and automatic restore are outside scope. A completed sync also cannot certify that iCloud has finished downloading/synchronizing every item.

## Incremental storage and recovery

The Azure container holds three forms of blob:

- `manifests/...` blobs contain metadata for one logical original/current resource and point to its current SHA-256 object.
- `objects/<library>/<sha256>` blobs are immutable content-addressed files. Original and current manifests in the same library reuse the same object when bytes match. Older edited versions remain as objects when the current manifest moves after a later edit or revert.
- `archives/<identity>/<sha256>` blobs are historical pointers for a retained, fully exported resource that disappeared from a successful full-library inventory before its interrupted upload completed.

Blob metadata records the identity hash, representation, source date, file name/type, object name, size, schema, and content hash. A local cache never proves that an Azure object still exists. Remote writes use ETags and conditional creation/update; concurrent changes are re-read rather than overwritten blindly. If the Photos source date is missing, the content is exported and rehashed each run. A dated Azure version newer than a local dated version is preserved. If the local date is unknown and the bytes differ from a dated destination, the run reports a conflict.

Exports are streamed to a private spool file one resource at a time and SHA-256 is computed in bounded memory. The journal is atomically persisted before export and after each completed block checkpoint. After a crash, the next process verifies the retained file and origin, checks Azure's uncommitted block list, and sends only missing blocks for the exact content hash and segmentation. Block IDs include the block size, so changing segmentation cannot combine versions. If a commit response is lost, the client checks the committed blob before retrying. Azure may expire uncommitted blocks after about a week without successful operations; the internal spool limit is 20 GiB, and expired blocks must be sent again. Completed objects stay backed up even when another resource fails.

When a journal is corrupt or lost, untracked spool files are discarded conservatively; the next sync re-exports and Azure block IDs allow any still-present identical blocks to be reused. Interrupted partial exports are discarded. The journal does not store Azure credentials. Failures leave resources pending for a later run and produce a nonzero exit status.

The backup is cumulative: removing an asset in Photos does not remove its Azure objects or manifests. If a resource disappears while a verified full export is still pending, a successful unfiltered inventory completes that snapshot and records an archive pointer before freeing its local spool. The object path is private to the configured library namespace, so rebuilding a Photos library or switching Macs creates a distinct logical backup.

## Daily LaunchAgent

Manage the daily LaunchAgent with the installed command:

```sh
photo-backup service install
photo-backup service status
photo-backup service uninstall
```

`install` first requests full Photos access if needed, checks the local spool and performs `doctor`'s Azure write/read/delete probe. It checks that the current user can write the LaunchAgents directory, then installs and loads the job only if all preflight checks pass. A denied Photos permission or failed Azure check leaves the service uninstalled. The job runs daily at 2:00 AM local time while the user is logged in; it does not start a backup immediately when installed. launchd may run a missed calendar event after wake; the Mac must be powered on and the user session available. It is not a daemon that runs while logged out. Uninstalling unloads/removes only the plist and keeps config, journal, logs, spool, and remote blobs. Standard error goes to `<logPath>.launchd`; application logs rotate by internal defaults.

## Tests

The regular suite uses fixture PhotoKit and a fake BlobStore. It covers date boundaries and DST, hidden/burst selection policy, object/manifest behavior, edits and reverts, missing remote objects, ETag conflicts, partial blocks across new engine instances, changed block sizing, changed source bytes, corrupted/lost checkpoints, disk limits, lost commit replies, and Azure CLI bearer-token acquisition/caching without exposing CLI stderr.

The Azure CLI integration test is opt-in. Its private config needs only `storageAccountName`; it uploads synthetic bytes under a unique name, exercises block reconciliation/commit/download/conditional writes, and cleans up its blobs:

```sh
PHOTOS_BACKUP_RUN_AZURE_CLI=1 \
PHOTOS_BACKUP_AZURECLI_INTEGRATION_CONFIG="$HOME/Library/Application Support/PhotosBackup/azure-cli-test.json" \
swift test --filter AzureBlobStoreTests/testAzureCliBlockUploadIsAvailableAsOptInIntegration
```

The Azurite test is opt-in and uses the public development-only account key against loopback only. It creates a local test container if needed and exercises Shared Key authentication, block list reconciliation, commit, metadata, download, and conditional writes:

```sh
PHOTOS_BACKUP_RUN_AZURITE=1 swift test --filter AzureBlobStoreTests/testAzuriteBlockUploadIsAvailableAsOptInIntegration
```

For a private Azure or private emulator config, the test loads it directly from a path without printing it. It writes only a 160 KB synthetic file beneath the configured prefix and deletes the test blob afterward:

```sh
PHOTOS_BACKUP_RUN_REAL_AZURE=1 \
PHOTOS_BACKUP_INTEGRATION_CONFIG="$HOME/Library/Application Support/PhotosBackup/config.json" \
swift test --filter AzureBlobStoreTests/testPrivateAzureSASBlockUploadIsAvailableAsOptInIntegration
```

No test needs Photos authorization. Real Photos export fidelity (including iCloud-only originals, edited videos, and Live Photos), LaunchAgent/TCC persistence, and a representative library over 100 GB still need a controlled user-machine validation. The current host build and synthetic storage tests are not a proof of those checks.
