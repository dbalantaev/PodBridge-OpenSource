# PodBridge project knowledge

This is a working map for people maintaining the code. It records how the current implementation is organized and where to look before changing a behavior. It is not an API reference and should not grow into a catalog of variables. Keep details here only when they save a future maintainer from rediscovering a non-obvious contract.

## What the app does

PodBridge is a SwiftUI app for copying authorized audio from a user-selected folder to a supported click-wheel iPod. It also reads and manages the iPod's existing library. The iPod is exposed as a Files document destination on iOS or as a mounted volume on Mac Catalyst.

The main workflow has a safety-sensitive boundary: the app edits a legacy binary music database and related artwork caches on removable storage. Treat the README's supported-model table and limitations as product support claims; implementation compatibility does not itself mean a model has been physically tested.

## Start here by task

| If you are changing… | Start with… | Then check… |
| --- | --- | --- |
| Transfer screen or user flow | `ContentView.swift`, `MusicTransferViewModel.swift` | README safety and workflow instructions |
| Source scanning, metadata, playlists | `MusicTransferEngine.swift`, `AudioMetadataReader.swift`, `MusicFile.swift` | `MusicTransferEngineTests.swift` |
| Database parsing or edits | `ClassicDatabase.swift`, `BinaryData.swift` | `ClassicDatabaseTests.swift` |
| Hashing or signature recovery | `Hash58.swift`, signature-related code in `ClassicDatabase.swift` and `IPodSyncEngine.swift` | Database fixture and known-vector tests |
| Artwork layout or cache changes | `ArtworkDatabase.swift` | `ArtworkDatabaseTests.swift`, transaction cleanup |
| Any destination write or recovery path | `IPodSyncEngine.swift`, `IPodVolumeStore.swift` | `IPodSyncEngineTests.swift`, backups and rollback behavior |
| Diagnostics or persistent logs | `AppLogger.swift`, `PersistentLogStore.swift`, `DiagnosticsView.swift` | `PersistentLogStoreTests.swift`, privacy implications |
| ALACarte client or target behavior | `ALACarteIntegration.swift`, `PodBridge.xcodeproj/project.pbxproj` | `ALACarteClientTests.swift`, target membership and README |

## How the runtime is divided

The app has one primary screen and a growing set of library-management operations. It is not organized into separate Swift modules or feature coordinators.

```text
PodBridgeApp
  └─ ContentView
       └─ MusicTransferViewModel
            ├─ MusicTransferEngine       source discovery
            ├─ AudioMetadataReader       source metadata
            └─ IPodSyncEngine             destination operations
                 ├─ ClassicDatabase      iTunesDB data model and format edits
                 ├─ Hash58                device-bound signature support
                 ├─ ArtworkDatabase       artwork records and cache files
                 └─ IPodVolumeStore       mounted-volume file boundary
```

`ContentView` presents the workflow. The view model coordinates user intent and observable state. The source engine discovers audio and ordered playlists. Destination operations are centralized in `IPodSyncEngine`; format helpers produce or inspect bytes, while `IPodVolumeStore` performs volume I/O. Tests can use virtual volume fixtures rather than physical iPods.

Some types have grown to cover many operations. Before extracting code, trace who owns the transaction and rollback for the operation. A smaller file is not an improvement if it obscures the order in which files are staged, activated, verified, and restored.

## Destination writes: the contract to preserve

Before modifying a write path, draw its actual stages from the implementation. The common database transaction is in `IPodVolumeStore.swift`; the broader orchestration and operation-specific file plans are in `IPodSyncEngine.swift` and `ArtworkDatabase.swift`.

The key questions are:

1. Which original bytes/files remain available if the next step fails?
2. At what point does the new database become active?
3. What is re-read to verify the result?
4. Which audio and artwork files must be removed or truncated on failure?
5. If restoration itself fails, how is that failure surfaced to the user?

Do not assume that every operation has the same backup policy. Reversible edits, imports, explicit permanent deletion, and restoring an older backup can intentionally have different recovery semantics. Confirm the specific operation and its tests before changing shared transaction helpers.

## Binary database and device profiles

`ClassicDatabase.swift` owns parsing and writing of the supported `iTunesDB` records. It also contains many transformations over tracks and playlists, so changes need to preserve records the app does not understand. `Hash58.swift` implements a device-dependent signature; a database that parses successfully may still be rejected by the iPod if its signature or device profile is wrong.

Artwork has a separate database and cache-file representation. Keep cache dimensions, pixel formats, and device-profile choices with the artwork implementation and its fixtures. Do not infer that two iPod generations share a format only because they share a marketing name.

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
