# PodBridge architecture

PodBridge is a single-flow SwiftUI application with one primary screen. It
supports Apple-library management and direct Rockbox file copies. The project
intentionally does not use feature coordinators, a global dependency
container, or a repository layer.

## Source layout

The source tree inside `PodBridge/` follows feature ownership rather than
technical layers. The folders do not create Swift modules; they show where a
change belongs.

```text
Application/                         app startup and root composition
Core/
  Database/                          iTunesDB, signatures, artwork bytes
  Diagnostics/                       persistent logs and diagnostics UI
  UI/                                small views shared by more than one feature
Features/
  Transfer/
    Models/ Services/ ViewModels/ Views/
  Library/
    Models/ Services/ Views/
  Settings/Views/
  ALACarte/
    Services/ ViewModels/                 dedicated ALACarte app target only
```

Add a type to a feature when it makes a product workflow clearer. Put it in
`Core` only when it has a narrow, stable role shared by several features. Do
not introduce folders that merely restate implementation layers.

## Target boundary

The project has two product targets that share the transfer, library, database,
diagnostics, and application code. Their only intentional product boundary is
the self-hosted ALACarte capability.

| Target | Includes | Contract |
| --- | --- | --- |
| `PodBridge` | Standard transfer, native library management, Rockbox copies, and library tools. | Must not expose ALACarte UI, client code, or local-network permission. |
| `PodBridgeALACarte` | Shared product code plus `Features/ALACarte`. | May authenticate to a user-owned ALACarte server and deliver its downloads through either destination path. |
| `PodBridgeTests` | Fixture-based tests for shared behavior and ALACarte client contracts. | Must remain deterministic without a physical iPod or a live ALACarte server. |

Check target membership in `PodBridge.xcodeproj/project.pbxproj` whenever a
source file, resource, entitlement, or Info.plist key is added or moved. The
standard target must remain buildable without ALACarte configuration.

## Runtime flow

```text
ContentView + focused SwiftUI screens
    ↓ user actions and presentation state
MusicTransferViewModel
    ├── Connection and device recovery extensions own destination sessions
    ├── Transfer and Rockbox extensions own source sessions and write tasks
    ├── Library, artwork, repair, and demo extensions own their screen workflows
    ├── Source inspection
    │   ├── MusicTransferEngine     scans source files and playlists
    │   └── AudioMetadataReader     reads AVFoundation metadata
    ├── ALACarte source path (ALACarte target only)
    │   ├── ALACarteClient owns authentication and server requests
    │   ├── ALACarteSourceDownloader downloads selections and merges playlist indices
    │   └── ALACarteTransferService owns temporary files through the destination write
    ├── Apple-library operations
    │   ├── IPodSyncEngine          coordinates transactional changes
    │   │   ├── IPodLibraryExport   exports audio and library manifests
    │   │   │   └── ExportAudioMetadataWriter restores current tags and cached artwork
    │   │   ├── IPodImportNormalization groups imported albums and playlists
    │   │   ├── IPodArtworkOperations owns artwork search, apply, and restore
    │   │   ├── IPodDeletionBackupStore persists verified recovery manifests
    │   │   ├── IPodDeletionOperations owns recoverable deletion and crash recovery
    │   │   ├── IPodDeletionRestoreOperations validates and restores one deletion
    │   │   └── IPodPermanentDeletionOperations removes data without retaining a backup
    │   ├── ClassicDatabase         coordinates deterministic iTunesDB byte transforms
    │   │   ├── ClassicDatabaseParsing / Serialization / DeviceIdentity
    │   │   ├── ClassicDatabaseImport / Removal / Playlists / PlayCounts
    │   │   ├── ClassicDatabaseMetadataEditing / AlbumNormalization / ArtworkEditing
    │   │   └── ClassicDatabaseCoreOperations / RecordEditing / Sorting
    │   ├── Hash58                  signs device-bound Classic database bytes
    │   ├── ArtworkDatabase         builds ArtworkDB and RGB565 ithmb caches
    │   ├── IPodVolumeStore         owns iPod paths and atomic file operations
    │   └── IPodDatabaseTransaction coordinates database backup and rollback
    └── RockboxTransferEngine       copies files without changing iTunesDB
        └── MusicTransferViewModel+Rockbox owns URL access and progress

PodBridgeApp
    └── TransferBackgroundExecution keeps long-running iOS transfers active
```

## Operation map

This map identifies the persistent state each workflow is allowed to change.
It is the first check before extending a transfer or library feature.

| User workflow | Entry owner | Persistent effect | Failure handling |
| --- | --- | --- | --- |
| Scan a Files folder | `MusicTransferEngine` | None on the iPod. | Stops without creating destination files. |
| Add files to the Apple iPod library | `IPodSyncEngine` | Audio, `iTunesDB`, and when needed `ArtworkDB` / `.ithmb` files. | Verifies a staged transaction; restores database, artwork, and created audio when the operation fails. |
| Edit, repair, or manage the existing library | `IPodSyncEngine` and focused library services | The active iPod library and, for explicit deletion, its managed recovery state. | Uses the operation-specific backup and verification contract. |
| Export the library | `IPodLibraryExport` | A new folder outside the iPod with copied audio, manifests, restored tags, and cached-cover PNGs. | Removes an incomplete export folder; never modifies the source iPod. |
| Copy files for Rockbox or install a theme | `RockboxTransferEngine` | Only files in the selected Rockbox destination. | Verifies copied sizes and removes files and empty folders created by a failed batch. It never changes `iTunesDB`. |
| Import from ALACarte | `ALACarteTransferService` in the ALACarte target | Temporary local downloads, then the selected Apple-library or Rockbox operation. | Removes temporary downloads after success, cancellation, or error; destination recovery is owned by the selected route. |

## Responsibilities

### `ContentView`

The SwiftUI composition root for the app's single workflow. It owns navigation,
source and destination selection, transfer presentation, and diagnostics. The
connected and disconnected home states live in `PodBridgeHomeView`, which
receives explicit presentation actions from the composition root. The
screens are grouped by user flow: connection and recovery, transfer review,
iPod library browsing, library tools, settings, and transfer completion live in
focused view files. These views present state and collect actions; they do not
parse database bytes or perform destination writes.

### `MusicTransferViewModel`

Owns observable screen state and translates user actions into engine calls. It
also manages security-scoped folder access and refreshes the displayed library
after a successful operation. The base file contains the state and owned task
handles. Focused extensions contain connection, device recovery, transfer,
library I/O, library editing, artwork, repair, demo, derived-state, and Rockbox
workflows. The ALACarte extension is compiled only into the dedicated target.

Each long-running workflow stores its `Task` on the view model so a replacement
selection, explicit cancellation, or disconnect can stop the work. Source and
destination selection UUIDs identify the active session; an older task must
check its session before publishing results. Transfer requests snapshot the
selected URLs, files, and playlists before suspension. Keep these rules when
adding asynchronous work so a result from a previous folder cannot overwrite
the current screen or target the newly selected device.

The focused extensions share module-internal setters because Swift access
control does not allow a `private(set)` property to be written from another
file. Treat mutation as view-model-owned despite that language-level access:
SwiftUI views render values and invoke actions instead of assigning workflow
state directly.

### `TransferBackgroundExecution`

Owns the platform-specific background execution window for long-running
transfers. It reports progress to iOS when continued processing is available,
falls back to UIKit's limited background task on older systems, and cancels the
owning transfer when the system expires that time so sync rollback can run.

### `DemoIPodFactory`

Builds the disposable mounted-volume fixture used by diagnostics and demo
builds. It owns the synthetic device identity, disk-use preferences, tracks,
playlists, and signed `iTunesDB`; `DemoLibraryEditor` applies later in-memory
metadata, artwork, playlist, and deletion changes. `DemoArtworkSearchService`
runs optional online lookup for the synthetic tracks. `MusicTransferViewModel`
applies those results to presentation state and removes the fixture when the
simulated device is disconnected.

### `LocalSignatureRecoveryService`

Owns the CPU and Metal batch search over the Hash58 candidate space. It reports
engine selection and progress to the main actor but does not own security-scoped
access, resume persistence, or presentation state; those remain in
`MusicTransferViewModel`.

### `MusicTransferEngine`

Scans a source folder, filters supported audio extensions, and parses ordered
`.m3u`/`.m3u8` playlists. It never writes to the iPod.

### ALACarte integration

The ALACarte files are compiled only into the dedicated app target. The models
and errors are independent of presentation. `ALACarteClient` owns HTTP,
authentication, and Keychain-backed session persistence. `ALACarteBrowserView`
owns connection and selection state; `ALACarteWebView` is the isolated WebKit
bridge. `ALACarteSourceDownloader` turns selected server items into scanned
audio files and playlists while preserving playlist references across several
downloads. `ALACarteTransferService` retains those temporary folders until the
Apple-library or Rockbox write finishes and removes them on success, failure,
or cancellation. The Rockbox route does not read or change `iTunesDB`.

### `RockboxTransferEngine`

Copies selected files to a user-chosen iPod folder or the Rockbox themes
folder. This path bypasses `iTunesDB`; Rockbox reads these files directly from
the volume. The view model owns security-scoped URLs and progress state, while
the engine handles deterministic copy order, safe names, size verification,
and removal of files created by a failed or cancelled batch. It accepts several
source trees so an ALACarte selection is copied to `/Music` as one operation.

### `IPodSyncEngine`

The application-level orchestration boundary for destination mutations. Its
write pipeline is:

1. Read and validate the current `iTunesDB`.
2. Read source metadata and copy audio files.
3. Build database and artwork edits in memory or temporary files.
4. Create a verified backup.
5. Apply artwork and replace the active database.
6. Re-read and verify the active files.
7. Remove temporary state, or restore the backup and copied-file state on error.

The engine may expose many operations because they all share the same
transactional destination and backup rules. Its operation result and progress
contracts live in `IPodSyncModels`; format-specific code belongs in the
specialized database types below.

Deletion has separate workflows because their recovery contracts differ.
`IPodDeletionBackupStore` persists manifests that bind the original database,
deleted database, retained audio, and device identity. Recoverable deletion
keeps those verified bytes and can roll back an interrupted operation.
Restoration proceeds only while the active database still matches the recorded
post-deletion hash. Permanent deletion verifies and activates the new database
before removing audio, then reports any file cleanup that could not complete.

### `IPodVolumeStore` and `IPodDatabaseTransaction`

`IPodVolumeStore` is the file-system boundary for the mounted iPod. Its live
implementation knows the `iPod_Control` paths, while tests can substitute a
virtual volume. `IPodDatabaseTransaction` centralizes the common database
sequence: create a verified backup, stage a verified temporary file, atomically
activate it, and restore the original bytes when activation or verification
fails. Artwork caches and audio files keep their own rollback plans because
their lifecycles differ from the database.

### `ClassicDatabase`

Coordinates byte-oriented `iTunesDB` operations and database edits. The base
file defines shared model and result contracts. `ClassicDatabaseParsing`,
`ClassicDatabaseSerialization`, and `ClassicDatabaseDeviceIdentity` respectively
read and audit records, build deterministic binary records, and resolve the
device identity used for signing. `ClassicDatabaseImport`, `Removal`,
`Playlists`, `PlayCounts`, `MetadataEditing`, `AlbumNormalization`, and
`ArtworkEditing` contain one high-level transformation each. Shared record
rewrites and sort-index handling live in `ClassicDatabaseRecordEditing`,
`ClassicDatabaseCoreOperations`, and `ClassicDatabaseSorting`.

Every transformation works only on supplied bytes and the device key. It
preserves records it does not own, validates the parsed result and structural
diagnostics after signing, and never opens volumes, creates backups, or
activates a database. Those responsibilities stay with the transaction layer.

### `Hash58`

The small, independent signing implementation used by device families that
require a FireWire-bound database hash. Keeping it separate makes the binary
format code easier to audit and lets its known vectors be tested directly.

### `ArtworkDatabase`

Generates and applies the iPod artwork representation (`ArtworkDB` and `.ithmb`
files). It records original file sizes in an apply plan so appended caches can
be truncated or removed during rollback. Export reads the largest recognized
cached rendition for a track, decodes its RGB565 pixels, and returns PNG data.
That image is limited to the resolution stored by the iPod; the original cover
cannot be reconstructed from the cache.

### Library export

`IPodLibraryExport` copies the selected audio into artist and album folders and
writes JSON, CSV, and M3U8 manifests. `ExportAudioMetadataWriter` then restores
the current iTunesDB title, artist, album, album artist, genre, year, track
number, compilation flag, and cached cover into supported containers. MP3 and
AAC use an ID3v2.4 prefix, WAV and AIFF use an ID3 chunk, and M4A/M4B update the
iTunes metadata atom tree without transcoding the media payload. A decoded PNG
is also written beside each track so the cached cover remains accessible when
a player does not read embedded artwork. Export never modifies the source iPod;
an error removes the incomplete destination folder.

## Data ownership and safety

- Existing track, playlist, and unknown database records are preserved unless
  an explicit management operation edits them.
- Recoverable edits and imports create a backup before replacing the active
  database. Explicit permanent deletion keeps the original database in memory
  until verification succeeds, but deliberately does not retain database or
  audio backups afterward.
- Hash58 signing uses the destination's FireWire ID for device families that
  require it.
- Source URLs and security-scoped access stay in the UI/transfer layer; they are
  not stored in `iTunesDB`.
- A failed verification must leave the previous database active. If that
  rollback cannot be verified byte-for-byte, the operation surfaces
  `restoreFailed` instead of hiding the recovery failure.

## Testing boundary

`ClassicDatabaseTests` and `ArtworkDatabaseTests` cover binary format behavior,
artwork extraction, and rollback. `IPodSyncEngineTests` use a
`VirtualIPodFixture` with the real
`iPod_Control` directory layout to cover end-to-end writes, verification, and
failure cleanup without touching physical media. Debug builds also expose
single-use failure points for database replacement, artwork application, and
audio deletion, so rollback paths can be exercised deterministically.
Physical validation has been performed only on an iPhone 15 Pro paired with an
iPod Classic 7th generation 160 GB; other device profiles remain experimental.

All app and test targets use Swift 6 language mode. SwiftLint runs in strict
mode with a checked-in baseline for existing cleanup work. New findings fail
the lint script; remove baseline entries as violations are fixed.
