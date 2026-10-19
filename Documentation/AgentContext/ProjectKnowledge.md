# PodBridge project knowledge

This is a working map for people maintaining the code. It records how the current implementation is organized and where to look before changing a behavior. It is not an API reference and should not grow into a catalog of variables. Keep details here only when they save a future maintainer from rediscovering a non-obvious contract.

## What the app does

PodBridge is a SwiftUI app for copying authorized audio from a user-selected folder to a supported click-wheel iPod. It also reads and manages the iPod's existing library. The iPod is exposed as a Files document destination on iOS or as a mounted volume on Mac Catalyst.

The main workflow has a safety-sensitive boundary: the app edits a legacy binary music database and related artwork caches on removable storage. Treat the README's supported-model table and limitations as product support claims; implementation compatibility does not itself mean a model has been physically tested.

## Start here by task

| If you are changing… | Start with… | Then check… |
| --- | --- | --- |
| App navigation and transfer presentation | `Application/ContentView.swift`, `Features/Transfer/Views/PodBridgeHomeView.swift`, `Features/Transfer/ViewModels/MusicTransferViewModel.swift` | The base view-model file owns state and task handles; focused `MusicTransferViewModel+*.swift` files own each workflow; also check README safety and workflow instructions |
| iPod library screens | `Features/Library/Views/` | `PodBridgeLibraryFeatureViews.swift` and `PodBridgeLibraryToolsViews.swift` for the consumer library and repair tools |
| Connection, recovery, and transfer review screens | `Features/Transfer/Views/` | `Features/Settings/Views/SettingsViews.swift` |
| Background execution and cancellation | `Features/Transfer/Services/TransferBackgroundExecution.swift` | Cancellation and rollback behavior in the active sync operation |
| Demo iPod scenarios and synthetic library edits | `Features/Transfer/Services/DemoIPodFactory.swift`, `Features/Transfer/Services/DemoLibraryEditor.swift`, `Features/Transfer/Services/DemoArtworkSearchService.swift` | The factory owns fixture bytes and temporary storage; the editor owns in-memory mutations; artwork lookup is isolated from presentation state; the view model owns connected-screen state and cleanup timing |
| Source scanning, metadata, playlists | `Features/Transfer/Models/` and `Features/Transfer/Services/` | `MusicTransferEngineTests.swift` |
| Rockbox direct file copy | `Features/Transfer/ViewModels/MusicTransferViewModel+Rockbox.swift`, `Features/Transfer/Services/RockboxTransferEngine.swift` | The view model owns URL access scope and progress; the engine copies one or several source trees, verifies files, and removes the batch on failure |
| ALACarte source import | `Features/ALACarte/Services/ALACarteIntegration.swift`, `ALACarteTransferService.swift`, `ViewModels/MusicTransferViewModel+ALACarte.swift`, `ALACarteBrowserView.swift` | These files are compiled only into the ALACarte target; the client owns authentication and HTTP, the downloader builds a merged source batch, and the transfer service owns temporary folders through Apple-library or Rockbox completion |
| Destination filenames | `Features/Transfer/Services/TransferFileNaming.swift` | Sanitize path components and choose a non-overwriting name for both copy workflows. |
| Database parsing and integrity checks | `Core/Database/ClassicDatabaseParsing.swift`, `Core/Database/BinaryData.swift` | `ClassicDatabaseTests.swift`, malformed and truncated fixtures |
| Database edits and binary record layout | `Core/Database/ClassicDatabase.swift`, `ClassicDatabaseImport.swift`, `ClassicDatabaseRemoval.swift`, `ClassicDatabasePlaylists.swift`, `ClassicDatabasePlayCounts.swift`, `ClassicDatabaseMetadataEditing.swift`, `ClassicDatabaseAlbumNormalization.swift`, `ClassicDatabaseArtworkEditing.swift`, `ClassicDatabaseRecordEditing.swift`, `ClassicDatabaseCoreOperations.swift`, `ClassicDatabaseSorting.swift`, `ClassicDatabaseSerialization.swift` | `ClassicDatabaseTests.swift`, unknown-record preservation and deterministic output |
| Device identity discovery | `Core/Database/ClassicDatabaseDeviceIdentity.swift`, `IPodDeviceProfile` code | `ClassicDatabaseTests.swift`, profile selection and cached-ID behavior |
| Hashing or signature recovery | `Core/Database/Hash58.swift`, `Features/Transfer/Services/LocalSignatureRecoveryService.swift`, `ClassicDatabase.swift`, `IPodSyncEngine.swift` | Hash58 owns candidate validation; the recovery service owns CPU/Metal batching; the view model owns resume state and device access |
| Artwork layout or cache changes | `Core/Database/ArtworkDatabase.swift` | `ArtworkDatabaseTests.swift`, transaction cleanup |
| Library export | `Features/Library/Services/IPodLibraryExport.swift`, `ExportAudioMetadataWriter.swift`, `Core/Database/ArtworkDatabase.swift` | Current iTunesDB metadata is written into copied audio; the largest recognized RGB565 cache rendition becomes embedded and sidecar PNG artwork; source iPod files remain unchanged |
| Recoverable deletion and restore | `Features/Library/Services/IPodDeletionBackupStore.swift`, `IPodDeletionOperations.swift`, `IPodDeletionRestoreOperations.swift` | Manifests bind both database states, retained audio, and device identity; restore requires the exact recorded post-deletion database |
| Permanent deletion | `Features/Library/Services/IPodPermanentDeletionOperations.swift` | Activate and verify the new database before audio removal; individual audio cleanup failures are reported without promising a retained backup |
| Other destination writes or recovery | `Features/Library/Services/IPodSyncEngine.swift`, `IPodVolumeStore.swift` | `IPodSyncEngineTests.swift`, transaction ordering, backups, and rollback behavior |
| Artwork search and application | `Features/Library/Services/IPodArtworkOperations.swift`, `Core/Database/ArtworkDatabase.swift` | `ArtworkDatabaseTests.swift`, `IPodSyncEngineTests.swift`, apply and rollback behavior |
| Import album and playlist grouping | `Features/Library/Services/IPodImportNormalization.swift` | Import fixtures and duplicate-reuse behavior in `IPodSyncEngineTests.swift` |
| Diagnostics or persistent logs | `Core/Diagnostics/` | `PersistentLogStoreTests.swift`, privacy implications |

## Source tree

`Application` contains startup and root presentation. `Core` contains shared
database, diagnostics, and small reusable UI types. Product workflows live in
`Features`: Transfer uses `Models`, `Services`, `ViewModels`, and `Views`;
Library keeps its browsing models, iPod operations, and screens together; Settings contains its
screens; ALACarte contains only the dedicated-target integration. These folders
describe ownership, not independent modules or a request to add generic
layering.

The standard `PodBridge` target excludes `Features/ALACarte` and its
local-network capability. `PodBridgeALACarte` adds that target-only code while
sharing the rest of the application. Keep the feature boundary in target
membership as well as source-level compilation checks. The complete target and
operation map is in [ARCHITECTURE.md](../../ARCHITECTURE.md#target-boundary).

## Published documentation

- [README.md](../../README.md) owns user-facing setup, supported-device claims,
  safety guidance, and current product screenshots.
- [ARCHITECTURE.md](../../ARCHITECTURE.md) owns source boundaries, target
  composition, write paths, and transaction responsibilities.
- `Documentation/Screenshots/README/` holds the versioned screenshots used by
  the README. Add only intentional product documentation images; do not add
  local captures, diagnostics containing personal data, or generated build
  artifacts.
- [Documentation/README.md](../README.md) indexes the documentation system and
  records when a standalone feature contract is appropriate.

## How the runtime is divided

The app has one primary screen and a growing set of library-management operations. It is not organized into separate Swift modules or feature coordinators.

```text
PodBridgeApp
  └─ ContentView + flow-specific SwiftUI screens
       └─ MusicTransferViewModel
            ├─ Connection + DeviceRecovery extensions
            ├─ Transfer extension → MusicTransferEngine + AudioMetadataReader
            ├─ Rockbox extension → RockboxTransferEngine
            ├─ Library, LibraryIO, Artwork, LibraryRepair, and Demo extensions
            ├─ ALACarte extension in the dedicated target
            └─ IPodSyncEngine + focused contracts, export, import, artwork, and deletion extensions
                 ├─ ClassicDatabase
                 │    ├─ ClassicDatabaseParsing / Serialization / DeviceIdentity
                 │    ├─ Import / Removal / Playlists / PlayCounts
                 │    ├─ MetadataEditing / AlbumNormalization / ArtworkEditing
                 │    └─ CoreOperations / RecordEditing / Sorting
                 ├─ Hash58 + ArtworkDatabase
                 └─ IPodVolumeStore + IPodDatabaseTransaction
```

`ContentView` presents navigation and composes focused screens grouped by user flow. The view model coordinates user intent and observable state. The source engine discovers audio and ordered playlists. Destination transactions are coordinated by `IPodSyncEngine`; `IPodSyncModels` contains its operation contracts, while focused export, import-normalization, artwork, and deletion extensions own their workflows. The deletion files keep recoverable backup storage, interrupted-operation recovery, exact-state restore, and irreversible cleanup as distinct contracts. Format helpers produce or inspect bytes, while `IPodVolumeStore` performs volume I/O. Tests can use virtual volume fixtures rather than physical iPods.

The view-model base file is the observable state container. Its extensions are
organized by user workflow rather than by generic layers. Every asynchronous
workflow owns a stored task. Source and destination selection tokens prevent a
task started for an earlier folder from publishing into the current session,
and transfer requests snapshot their input before suspension. Cross-file
extensions require module-internal setters, but views still treat the state as
read-only and send user actions through view-model methods.

Some types have grown to cover many operations. Before extracting code, trace who owns the transaction and rollback for the operation. A smaller file is not an improvement if it obscures the order in which files are staged, activated, verified, and restored.

## Destination writes: the contract to preserve

Before modifying a write path, draw its actual stages from the implementation. The common database transaction is in `IPodVolumeStore.swift`; broader orchestration and operation-specific plans are in `IPodSyncEngine.swift`, the `IPodDeletion*` files, and `ArtworkDatabase.swift`.

The key questions are:

1. Which original bytes/files remain available if the next step fails?
2. At what point does the new database become active?
3. What is re-read to verify the result?
4. Which audio and artwork files must be removed or truncated on failure?
5. If restoration itself fails, how is that failure surfaced to the user?

Do not assume that every operation has the same backup policy. Reversible edits, imports, explicit permanent deletion, and restoring an older backup can intentionally have different recovery semantics. Confirm the specific operation and its tests before changing shared transaction helpers.

## Binary database and device profiles

`ClassicDatabase.swift` holds model and result contracts. `ClassicDatabaseParsing.swift` reads track and playlist records and diagnoses database integrity; `ClassicDatabaseSerialization.swift` builds binary records; `ClassicDatabaseDeviceIdentity.swift` resolves and caches FireWire IDs. Each edit has a focused file: import, removal, playlists, play counts, metadata, album normalization, or artwork. Shared record mutations, section rewrites, and index rebuilding stay in `ClassicDatabaseRecordEditing.swift`, `ClassicDatabaseCoreOperations.swift`, and `ClassicDatabaseSorting.swift`. Changes must preserve records the app does not understand. `Hash58.swift` implements a device-dependent signature; a database that parses successfully may still be rejected by the iPod if its signature or device profile is wrong.

Artwork has a separate database and cache-file representation. Keep cache dimensions, pixel formats, and device-profile choices with the artwork implementation and its fixtures. Do not infer that two iPod generations share a format only because they share a marketing name.

Library export treats the iTunesDB as the current metadata authority and the
ArtworkDB/`.ithmb` files as the available cover source. It copies the original
audio stream, rewrites supported container metadata in the destination copy,
and writes the decoded cover beside the song. The cache contains an iPod-sized
RGB565 rendition, so export preserves that rendition rather than recovering the
original full-resolution image. Any metadata or artwork rewrite failure removes
the incomplete export folder and leaves the mounted volume untouched.

For a format change, inspect malformed/truncated input handling, preservation of unknown records, deterministic output, and verification of the bytes written. Use small fixture-based tests and known vectors where available.

## Tests and what they establish

- `ClassicDatabaseTests` exercise database transforms and diagnostics.
- `ArtworkDatabaseTests` exercise artwork generation and apply/rollback behavior.
- `IPodSyncEngineTests` exercise destination workflows against test storage.
- `MusicTransferEngineTests` exercise source discovery and playlist behavior.
- `ALACarteClientTests` exercise the optional server client.
- `PersistentLogStoreTests` exercise log persistence.

A passing virtual-volume test establishes behavior against that fixture and implementation, not physical compatibility with every iPod. README claims identify the known physical test configuration. Add tests at the layer where the contract lives, and include a failure case for each new destination mutation stage.

## Xcode targets and local workflow

The project has two app schemes (`PodBridge`, `PodBridgeALACarte`) and corresponding test targets. Check the `.pbxproj` before adding source, resource, entitlement, or plist files; target membership is part of the feature boundary. The standard app intentionally excludes the self-hosted ALACarte capability.
All eight Debug/Release target configurations use Swift 6 language mode. Keep the app and test targets on the same language mode so concurrency checking applies to production code and its fixtures.

SwiftLint runs with `.swiftlint.yml`. The checked-in `.swiftlint-baseline.json` captures legacy findings from before the ongoing cleanup; `Scripts/lint.sh` uses strict mode and the baseline so new findings fail while existing ones can be removed incrementally. A baseline entry is temporary debt, not a permanent suppression.

Useful discovery commands:

```sh
xcodebuild -list -project PodBridge.xcodeproj
xcrun simctl list devices available
```

Build and test commands are kept in the root `AGENTS.md`. Keep generated build output outside source control. Use the lint script only after checking its baseline and tool version; do not apply automatic fixes across files that already contain user changes.

## Maintainer habits

- Read the relevant README section before changing a user-visible transfer or recovery behavior.
- Keep binary-format knowledge close to the parser/writer; keep cross-file workflow and ownership knowledge here.
- Record why a compatibility exception exists and what evidence supports it.
- Keep failure handling explicit. Cancellation, failed verification, and failed rollback are distinct outcomes.
- Do not log credentials, music content, or more path information than diagnosis requires.
- Update this document when boundaries or contracts change, not for routine implementation details.
