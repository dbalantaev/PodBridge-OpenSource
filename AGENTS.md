# PodBridge contributor instructions

## Purpose and project context

PodBridge is a SwiftUI app for transferring authorized music files to supported click-wheel iPods. Read [README.md](README.md) for user-facing setup and safety guidance, [ARCHITECTURE.md](ARCHITECTURE.md) for code ownership, and the relevant topic in [Documentation/AgentContext/ProjectKnowledge.md](Documentation/AgentContext/ProjectKnowledge.md) before changing behavior. Keep project documentation in English.

This is a single Xcode project with the `PodBridge`, `PodBridgeALACarte`, and `PodBridgeTests` targets. The two app targets share the core transfer/database code; ALACarte integration belongs only to its dedicated target. Check target membership before adding or moving source files.

## Required workflow

1. Read this file and run `git status --short` before editing.
2. Treat all existing staged, modified, and untracked files as user work. Do not discard, overwrite, or broadly format them.
3. Inspect only the files and documentation relevant to the requested change. Never inspect credentials, signing material, `.env` files, build products, or vendored dependencies unless the task explicitly requires it.
4. Preserve the established behavior and safety guarantees. Do not infer unsupported iPod models, binary-format rules, or rollback behavior.
5. Update the knowledge base when an architectural, data-ownership, safety, target, build, or test contract changes.
6. Run the narrowest relevant verification when asked to verify, and report exact commands and outcomes. Do not claim physical-device coverage from simulator tests.

## Architecture boundaries

- `PodBridgeApp` owns application startup and top-level dependency construction.
- SwiftUI views render state and forward user actions. `MusicTransferViewModel` owns screen orchestration, security-scoped access, and presentation state.
- `MusicTransferEngine` discovers source audio and playlist files; it does not mutate the iPod.
- `IPodSyncEngine` coordinates destination changes and rollback. Keep operations that mutate the iPod behind this boundary.
- `IPodVolumeStore` owns mounted-volume paths and file operations; database transaction logic belongs in the transaction abstraction.
- `ClassicDatabase`, `Hash58`, and `ArtworkDatabase` own format-specific transformations. Keep parsing and serialization deterministic and testable without physical media.
- Keep logging free of credentials and unnecessary personal or source-path data.
- Avoid a global service locator, speculative layers, and unrelated file moves. Extract a type when it creates a clear ownership boundary or makes behavior independently testable.

## Safety invariants

- Preserve existing library records unless the user explicitly requests an operation that changes them.
- Validate generated database and artwork data before activating it.
- Keep a recoverable backup for operations documented as recoverable; verify rollback and surface rollback failures.
- Keep temporary files and partial media copies recoverable or clean them up on failure.
- Treat model-specific hashes, filesystem assumptions, and artwork layouts as device-profile behavior; do not generalize from one tested iPod.
- Do not use Finder/Music or iTunes synchronization assumptions as a substitute for the app's transaction guarantees.

## Swift style and tooling

- Follow `.swiftlint.yml`; do not add blanket suppressions to make existing violations disappear.
- Prefer small, cohesive types and explicit dependencies. Avoid clever abstractions in binary-format code.
- Document non-obvious binary layouts, checksums, transaction stages, and compatibility decisions at the point where they are maintained.
- Add or update focused tests for changes to parsing, serialization, checksums, transaction ordering, cleanup, and rollback.
- Keep generated files, local Xcode state, and machine-specific configuration out of commits.

## Build and test commands

List available schemes and destinations before selecting a local simulator. Typical commands are:

```sh
xcodebuild -list -project PodBridge.xcodeproj
xcodebuild -project PodBridge.xcodeproj -scheme PodBridge \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project PodBridge.xcodeproj -scheme PodBridge \
  -destination 'platform=iOS Simulator,name=<available simulator>' \
  CODE_SIGNING_ALLOWED=NO test
```

Use `Scripts/lint.sh` for the repository lint workflow. If SwiftLint is unavailable, report that explicitly rather than silently skipping lint.
