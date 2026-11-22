# Photos Backup to Azure Blob Storage

<p align="center">
  <img src="logo.svg" alt="Photos Backup icon" width="180">
</p>

A macOS command-line backup of original resources exposed by the system Photos library. Azure blobs keep each real resource filename. If an original exists only in iCloud, Photos is asked to download it only when Azure needs that resource uploaded. Rendered edits are not included. The backup never modifies Photos or deletes remote files when local originals disappear.

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

`config` creates the private config automatically. For AccountKey or SAS instead, run `photo-backup config --connection-string`; it prompts with input hidden. The executable uses the existing `photos-backup` container; neither container nor prefix belongs in the config. The active Azure CLI subscription is used; run `az account set --subscription ...` first only if needed.

Azure CLI asks for a token scoped to Storage, keeps it in memory, and refreshes it before expiry. It does not write the token to config, journal, or logs. Azure CLI persists the signed-in account's refresh credentials for later token requests; the daily LaunchAgent runs as that same macOS user. The executable finds `az` on `PATH` and common Homebrew paths. [Azure CLI documents token expiry and how `az login` stores the session](https://learn.microsoft.com/en-us/cli/azure/authenticate-azure-cli-interactively).

The storage account must have an existing `photos-backup` container. The signed-in user needs **Storage Blob Data Contributor** on the container or account; Azure management roles such as `Owner` by themselves do not grant blob data access. [Microsoft documents the Blob data roles](https://learn.microsoft.com/en-us/azure/storage/blobs/authorize-access-azure-active-directory). Config files and internal settings are written with mode `0600`; runtime paths, limits, retries, logging, library ID, and daily 2:00 AM schedule use private defaults.

## Authorize and check

Use the installed command:

```sh
photo-backup authorize
photo-backup doctor
```

`authorize` requests full Photos read access. `doctor` checks access to the system Photos library through PhotoKit and writes/reads/deletes an isolated temporary blob. It does not copy photos or verify iCloud synchronization.

## Sync

```sh
photo-backup sync
photo-backup sync --from 2024-01-01
photo-backup sync --to 2024-12-31
photo-backup sync --from 2024-01-01 --to 2024-12-31 --dry-run
```

With no dates, the command enumerates every original resource in the system Photos library through PhotoKit. `--from` and `--to` filter by the asset's capture date in the Mac's current time zone, with inclusive date boundaries. A dry run compares resource identity and known size against Azure without exporting, downloading from iCloud, or uploading file bytes. When Photos does not report a resource size, the dry run can only report a candidate; an actual sync exports the resource only after it is identified as missing or stale in Azure.

The mirror preserves each original filename, including videos, Live Photo components, and separate RAW/JPEG files. PhotoKit exposes asset IDs and resource filenames, but Apple does not expose the private package-relative path under `Originals`. Azure therefore stores each file as `Originals/<asset-id>/<resource-kind>/<type>/<original-filename>` to avoid filename collisions. The asset ID and type components are reversible identifiers, not content hashes; blobs contain the actual file bytes and do not use hash-named objects or metadata-only manifests. Blob Content-Type comes from Photos' resource type.

The system library is selected by Photos and accessed through PhotoKit; the command does not search `~/Pictures` or open the `.photoslibrary` package. The Azure preflight does not read photo bytes. When a resource needs uploading, PhotoKit network access is enabled so it can download an iCloud-only original; download or network errors are reported as failures and retried by a later run. Already-backed-up resources and dry runs do not trigger those downloads. The mirror does not copy edited renders.

## Incremental storage and recovery

Each Azure blob stores the actual original bytes. Custom metadata identifies the Photos asset/resource and records its filename, type, size, and source modification date. Each run reads Azure's `Originals/` catalog as a paginated listing with metadata, then compares it to Photos locally instead of issuing one `HEAD` request per resource. A temporary SQLite catalog holds the remote inventory and upload plan on disk, keeping memory use bounded; it is removed at the end of the run. The client skips an existing blob when its resource identity and size match, preserves an Azure version marked newer, and conditionally replaces a different or older version at the same resource path.

Large files upload in blocks. Block IDs are derived from file size, asset creation date (or modification date when capture date is missing), and block number, so a later run can reuse uncommitted blocks without naming the blob by a hash. The PhotoKit resource identity is rechecked before commit. Writes use ETags; if a commit response is lost, the client checks the blob's stored size and source metadata. Azure can expire uncommitted blocks after roughly a week without successful operations; a later run resends expired blocks. Removing a local resource never deletes its Azure blob.

The previous hash/manifests layout may remain under the old `photos-backup/` prefix from earlier runs. The new sync does not read or delete that legacy layout. Those blobs are kept until a separate migration and cleanup is authorized.

## Logs

Each sync writes timestamped events to standard output and the private rotating log at `~/Library/Logs/PhotosBackup/backup.log` by default. Before uploading, it logs how many resources are candidates, how many are already backed up, known candidate bytes, and any preflight failures. Each in-scope resource gets start/end events with its filename, type, estimated and actual size, result, elapsed time, and bytes sent/reused. `FILE_SOURCE_READY` records the actual size after Photos exports a local resource.

The LaunchAgent captures stdout/stderr in `backup.log.launchd` for the latest service run; it resets that capture at the start of each run. The rotating `backup.log` keeps history across runs. Reinstall an existing LaunchAgent with `photo-backup service install` to update its output paths.

## Daily LaunchAgent

Manage the daily LaunchAgent with the installed command:

```sh
photo-backup service install
photo-backup service status
photo-backup service uninstall
```

`install` first requests Photos access if needed, checks the system library through PhotoKit and runs `doctor`'s Azure probe. It checks that the current user can write the LaunchAgents directory, then installs and loads the job only if preflight succeeds. The job is restricted to the logged-in user's Aqua (GUI) session so Photos uses that user's granted privacy permission. It runs daily at 2:00 AM local time while the user is logged in; installation does not start a sync immediately. launchd may run a missed calendar event after wake. Uninstalling removes only the LaunchAgent plist and preserves the local configuration and all Azure blobs.

## Tests

The existing unit suite covers Azure REST behavior, date boundaries, and the previous PhotoKit backup engine. It does not read the user's Photos library or validate the new direct `Originals` mirror.

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

No automated test needs Photos authorization. A representative library still needs validation on the user's Mac. Cloud-only originals are outside this mirror by design.
