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
scripts/package-app.sh
```

The package script builds `Photos Backup.app`, adds `NSPhotoLibraryUsageDescription`, signs it, and verifies its signature and property list. It does not install or load a LaunchAgent. By default it uses an ad-hoc signature; for durable macOS Photos permission across app updates, sign each build with the same trusted Developer ID:

```sh
CODE_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" scripts/package-app.sh
```

Move the packaged app to its permanent path before authorizing Photos or installing the service. macOS associates privacy approval with the app identity. Run commands from `Photos Backup.app/Contents/MacOS/photos-backup` or a shell alias to that executable.

## Configure

Create the private application support directory and copy one example. Fill in the stable library UUID, existing container, and preferred prefix. Never put credentials in command arguments or commit a real config file.

```sh
mkdir -p "$HOME/Library/Application Support/PhotosBackup"
# AccountKey or SAS:
cp config.example.json "$HOME/Library/Application Support/PhotosBackup/config.json"
# For Azure CLI instead, use:
# cp config.azure-cli.example.json "$HOME/Library/Application Support/PhotosBackup/config.json"
chmod 600 "$HOME/Library/Application Support/PhotosBackup/config.json"
```

For a connection string, choose AccountKey:

```text
DefaultEndpointsProtocol=https;AccountName=<account>;AccountKey=<key>;EndpointSuffix=core.windows.net
```

or SAS:

```text
BlobEndpoint=https://<account>.blob.core.windows.net;SharedAccessSignature=<SAS query>
```

The client preserves SAS percent escapes in the signed URL query. It sends a Shared Key Authorization header for AccountKey and uses HTTPS for Azure. Plain HTTP is accepted only for an explicitly enabled loopback development endpoint (for example Azurite).

### Use the signed-in Azure CLI session

To avoid storing a key or SAS, copy `config.azure-cli.example.json` instead. It contains only the storage account name, Blob endpoint, container, and prefix. Then sign in once with Azure CLI if needed:

```sh
az login
az account show --output table
```

Set `authenticationMode` to `azureCli`. The app asks `az account get-access-token` for a token scoped to Azure Storage, keeps it in memory, and refreshes it before expiry. It does not write the token to config, journal, or logs. Azure CLI persists the signed-in account's refresh credentials for later token requests; the daily LaunchAgent must run as the same macOS user. [Azure CLI documents token expiry and recommends the UTC `expires_on` field](https://learn.microsoft.com/en-us/cli/azure/account?view=azure-cli-latest#az-account-get-access-token), and [how `az login` stores and refreshes the signed-in session](https://learn.microsoft.com/en-us/cli/azure/authenticate-azure-cli-interactively).

Grant the signed-in user **Storage Blob Data Contributor** on the target container or storage account. Azure management roles such as `Owner` by themselves do not grant blob data access. [Microsoft's Blob authorization guide describes the data roles](https://learn.microsoft.com/en-us/azure/storage/blobs/authorize-access-azure-active-directory).

Set `azureCliSubscription` only when the storage account belongs to a subscription other than the active Azure CLI subscription. Set `azureCliPath` to the absolute `az` executable path if LaunchAgent cannot find it on `PATH`; the app checks common Homebrew paths too. If Azure CLI asks for sign-in again, run `az login` as the same user and rerun `doctor`.

For AccountKey or SAS, use `config.example.json`. Scope SAS to the configured container and prefix with the operations needed to list/read blob metadata, stage and commit blocks, update metadata, and delete the temporary doctor probe. The container must already exist for normal backups. Config files require mode `0600` or stricter. The journal, spool, logs, run lock, and LaunchAgent property list are also private to the user.

Important config values:

- `libraryID`: a stable, unique UUID for this Photos library. Keep it across runs and app reinstalls.
- `authenticationMode`: `connectionString` for AccountKey/SAS, or `azureCli` to use the active user's signed-in Azure CLI session.
- `connectionString`: required only for `connectionString` mode; omit it in Azure CLI mode.
- `storageAccountName`, `blobEndpoint`: non-secret Azure storage location fields for `azureCli`. The standard endpoint is inferred from the account name if `blobEndpoint` is omitted.
- `azureCliSubscription`, `azureCliPath`: optional subscription selector and absolute path to the `az` executable.
- `container`, `prefix`: destination location. A prefix scopes all manifests and content objects.
- `spoolDirectory`, `journalPath`, `logPath`: absolute paths or `~/` paths so launchd resolves them the same way as Terminal.
- `maxSpoolBytes`: maximum space retained for complete exports waiting for Azure. The current default is 20 GiB; choose a value that fits available disk space.
- `blockSize`: Azure upload block size (64 KiB to 100 MiB). The engine raises it when necessary to stay below Azure's 50,000 block limit.
- `timeZoneIdentifier`, `dailyHour`: filter calendar and LaunchAgent schedule. The LaunchAgent runs at minute zero in the Mac's local clock.
- `allowInsecureLocalHTTP`: set `true` only in a development config for a loopback emulator.

## Authorize and check

From the packaged app:

```sh
"/Applications/Photos Backup.app/Contents/MacOS/photos-backup" authorize
"/Applications/Photos Backup.app/Contents/MacOS/photos-backup" doctor
```

`authorize` requests full Photos read access. Limited Photos access is not enough for a whole-library backup. `doctor` checks that full authorization is present, the spool directory is writable, and an isolated temporary blob can be written, read, and deleted under the configured prefix. It does not export a photo, validate every library item, check iCloud synchronization completeness, or prove backup fidelity.

## Sync

```sh
photos-backup sync
photos-backup sync --from 2024-01-01
photos-backup sync --to 2024-12-31
photos-backup sync --from 2024-01-01 --to 2024-12-31 --dry-run
```

With no dates, the command enumerates the full accessible library on every run; it does not use a last-run watermark. Dates use the Photos capture date in `timeZoneIdentifier`, and both ends are inclusive. Missing capture dates are included only without a filter; with a filter, they are reported as unclassifiable and the run exits nonzero. A dry run queries Photos inventory and Azure manifests but does not export/download resources, write blobs, update manifests, or clear recovery state. It reports `would upload` candidates; a changed source date may need export/hash comparison in a real run, so this is an estimate.

Each `PHAssetResource` original is considered independently, including photo/video components of Live Photos, alternate RAW/JPEG resources, audio, and hidden assets. The current representation prefers Photos' full-size rendered photo, video, or paired-video resource. If that resource is absent, the app asks Photos for its current rendered editing input (and a current Live Photo for the motion component) with network access enabled. When the asset has no edits, the original is the current representation. If Photos cannot supply a current render, the resource fails visibly instead of backing up the wrong bytes.

Resource identity uses the Photos asset local identifier, representation, resource kind, and a digest of the UTI. Filename and enumeration order are not identity. If one asset contains multiple indistinguishable resources with the same kind and UTI, the run flags incomplete coverage and skips those resources rather than assigning unstable ordinals. Local identifiers are specific to one Photos library and are not cross-Mac deduplication IDs.

The PhotoKit inventory enables both hidden assets and all burst frames. PhotoKit does not provide a verified full-library export path for Recently Deleted, and Shared Albums coverage has not been validated; this tool does not claim those collections are backed up. Album organization, faces, edit history, and automatic restore are outside scope. A completed sync also cannot certify that iCloud has finished downloading/synchronizing every item.

## Incremental storage and recovery

The Azure container holds three forms of blob:

- `manifests/...` blobs contain metadata for one logical original/current resource and point to its current SHA-256 object.
- `objects/<library>/<sha256>` blobs are immutable content-addressed files. Original and current manifests in the same library reuse the same object when bytes match. Older edited versions remain as objects when the current manifest moves after a later edit or revert.
- `archives/<identity>/<sha256>` blobs are historical pointers for a retained, fully exported resource that disappeared from a successful full-library inventory before its interrupted upload completed.

Blob metadata records the identity hash, representation, source date, file name/type, object name, size, schema, and content hash. A local cache never proves that an Azure object still exists. Remote writes use ETags and conditional creation/update; concurrent changes are re-read rather than overwritten blindly. If the Photos source date is missing, the content is exported and rehashed each run. A dated Azure version newer than a local dated version is preserved. If the local date is unknown and the bytes differ from a dated destination, the run reports a conflict.

Exports are streamed to a private spool file one resource at a time and SHA-256 is computed in bounded memory. The journal is atomically persisted before export and after each completed block checkpoint. After a crash, the next process verifies the retained file and origin, checks Azure's uncommitted block list, and sends only missing blocks for the exact content hash and segmentation. Block IDs include the block size, so changing segmentation cannot combine versions. If a commit response is lost, the client checks the committed blob before retrying. Azure may expire uncommitted blocks after about a week without successful operations; the spool is retained within `maxSpoolBytes`, but expired blocks must be sent again. Completed objects stay backed up even when another resource fails.

When a journal is corrupt or lost, untracked spool files are discarded conservatively; the next sync re-exports and Azure block IDs allow any still-present identical blocks to be reused. Interrupted partial exports are discarded. The journal does not store Azure credentials. Failures leave resources pending for a later run and produce a nonzero exit status.

The backup is cumulative: removing an asset in Photos does not remove its Azure objects or manifests. If a resource disappears while a verified full export is still pending, a successful unfiltered inventory completes that snapshot and records an archive pointer before freeing its local spool. The object path is private to the configured library namespace, so rebuilding a Photos library or switching Macs creates a distinct logical backup.

## Daily LaunchAgent

Use the packaged app at its final path and config path:

```sh
photos-backup service install --config "$HOME/Library/Application Support/PhotosBackup/config.json"
photos-backup service status --config "$HOME/Library/Application Support/PhotosBackup/config.json"
photos-backup service uninstall --config "$HOME/Library/Application Support/PhotosBackup/config.json"
```

`install` writes and loads only this user's `com.photosbackup.daily` LaunchAgent. It runs daily at the configured hour and minute `00` while the user is logged in. launchd may run a missed calendar event after wake; the Mac must be powered on and the user session available. It is not a daemon that runs while logged out. Uninstalling unloads/removes only the plist and keeps config, journal, logs, spool, and remote blobs. Standard error goes to `<logPath>.launchd`; application logs rotate by configured size/count.

## Tests

The regular suite uses fixture PhotoKit and a fake BlobStore. It covers date boundaries and DST, hidden/burst selection policy, object/manifest behavior, edits and reverts, missing remote objects, ETag conflicts, partial blocks across new engine instances, changed block sizing, changed source bytes, corrupted/lost checkpoints, disk limits, lost commit replies, and Azure CLI bearer-token acquisition/caching without exposing CLI stderr.

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
