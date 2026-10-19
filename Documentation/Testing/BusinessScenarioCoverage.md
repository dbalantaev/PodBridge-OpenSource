# Business scenario coverage

## Purpose

This document records the evidence for user-visible workflows. Unit and service tests establish local logic; they do not establish the full UI, navigation, mounted-device, or external-system flow. Record those layers and residual risk separately.

## Current coverage map

| Scenario | Automated coverage | Manual or device coverage | Residual risk |
| --- | --- | --- | --- |
| Import authorized audio and update the classic database | `ClassicDatabaseTests`, `IPodSyncEngineTests` | Physical iPod transfer is required for device-specific compatibility. | Model-specific database, hash, and artwork behavior must be confirmed on supported devices. |
| Export library audio with metadata and artwork | `IPodSyncEngineTests`, export metadata tests where applicable | Validate exported files in supported media players. | Container-specific metadata support and iPod artwork cache quality vary by source media. |
| Recoverable deletion and restore | `IPodSyncEngineTests` with the virtual iPod fixture | Validate recovery on a removable test volume before release. | Physical-volume interruption and filesystem behavior cannot be fully represented by a simulator fixture. |
| ALACarte import to Apple library or Rockbox | `ALACarteClientTests` and transfer-service tests where applicable | Validate account-backed and Rockbox flows with authorized test content. | Network, authorization, and device mounting remain external dependencies. |

## Release regression

1. Build both `PodBridge` and `PodBridgeALACarte` with code signing disabled for the iOS Simulator.
2. Run the repository lint workflow and relevant focused tests.
3. For changes to destination writes, perform the documented manual verification on an authorized supported iPod or state that it was not performed.

## Coverage gaps

Physical iPod compatibility, mounted-volume interruption, and third-party account behavior require controlled manual validation. Simulator builds and virtual fixtures do not establish that coverage.
