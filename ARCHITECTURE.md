# PodBridge architecture

PodBridge is a single-flow SwiftUI application. It has one primary screen and
one long-running user action: moving selected audio into an iPod library. The
project intentionally does not use feature coordinators, a global dependency
container, or a repository layer.

## Runtime flow

```text
ContentView
    ↓ user actions and presentation state
MusicTransferViewModel
    ↓ orchestration and UI state
MusicTransferEngine       scans source files and playlists
AudioMetadataReader       reads AVFoundation metadata
IPodSyncEngine            owns transactional destination changes
    ├── ClassicDatabase   parses and serializes iTunesDB
    ├── Hash58            signs device-bound Classic database bytes
    ├── ArtworkDatabase   builds ArtworkDB and RGB565 ithmb caches
    ├── IPodVolumeStore   owns iPod paths and atomic file operations
    ├── IPodDatabaseTransaction
    │                       coordinates backup, activation, and database rollback
    └── AppLogger         records structured diagnostics
```

## Responsibilities

### `ContentView`

The SwiftUI composition root for the app's single workflow. It presents source
and destination pickers, transfer controls, library management sheets, and
diagnostics. It does not parse database bytes or perform file-system writes.

### `MusicTransferViewModel`

Owns observable screen state and translates user actions into engine calls. It
also manages security-scoped folder access and refreshes the displayed library
after a successful operation.

### `MusicTransferEngine`

Scans a source folder, filters supported audio extensions, and parses ordered
`.m3u`/`.m3u8` playlists. It never writes to the iPod.

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
transactional destination and backup rules. Format-specific code belongs in
the specialized database types below.

### `IPodVolumeStore` and `IPodDatabaseTransaction`

`IPodVolumeStore` is the file-system boundary for the mounted iPod. Its live
implementation knows the `iPod_Control` paths, while tests can substitute a
virtual volume. `IPodDatabaseTransaction` centralizes the common database
sequence: create a verified backup, stage a verified temporary file, atomically
activate it, and restore the original bytes when activation or verification
fails. Artwork caches and audio files keep their own rollback plans because
their lifecycles differ from the database.

### `ClassicDatabase`

Pure byte-oriented logic for the iPod Classic `iTunesDB`: parsing tracks and
playlists, editing records, rebuilding indexes, and producing signed output.
It receives bytes and a device key; it does not open folders or create backups.

### `Hash58`

The small, independent signing implementation used by device families that
require a FireWire-bound database hash. Keeping it separate makes the binary
format code easier to audit and lets its known vectors be tested directly.

### `ArtworkDatabase`

Generates and applies the iPod artwork representation (`ArtworkDB` and `.ithmb`
files). It records original file sizes in an apply plan so appended caches can
be truncated or removed during rollback.

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

`ClassicDatabaseTests` and `ArtworkDatabaseTests` cover binary format behavior
and rollback. `IPodSyncEngineTests` use a `VirtualIPodFixture` with the real
`iPod_Control` directory layout to cover end-to-end writes, verification, and
failure cleanup without touching physical media. Debug builds also expose
single-use failure points for database replacement, artwork application, and
audio deletion, so rollback paths can be exercised deterministically.
Physical validation has been performed only on an iPhone 15 Pro paired with an
iPod Classic 7th generation 160 GB; other device profiles remain experimental.
