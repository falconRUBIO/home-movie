# Implementation audit — 2026-10-09

## Checks performed in this workspace

- All 18 Swift files parsed with the tree-sitter Swift grammar without syntax error nodes.
- Xcode OpenStep project parsed successfully; build-file references and all source/resource paths resolve.
- Shared scheme XML and property-list/privacy files parsed successfully.
- Permission purposes, iOS 18 deployment configuration, both landscape orientations, portrait, test-target inclusion and icon-resource references checked.
- Project generator reproduced its checked-in project and scheme deterministically.
- Interactive prototype JavaScript syntax checked; camera sample revised to fit rather than crop its source image.
- Source reviewed for take ownership, commit completion, reconciliation, original retention, transform fitting, audio offsets, cancellation, snapshot consistency, file retention and bounded thumbnail cache.

These checks are **not Swift type checking, an Xcode build, XCTest execution or real-device validation**. No browser runtime screenshot test was possible because a browser executable was unavailable. No camera output, exported codec, audio, performance or visual behavior has been certified here.

## Issues corrected during the source audit

- Lens buttons read real device switch-over factors and the iOS 18+ display multiplier; removed inferred/hardcoded telephoto choices.
- Default rear zoom now normalizes to displayed 1× instead of opening on an ultra-wide virtual-device base zoom.
- Preview uses aspect fit, no fill crop. Movie format is explicit and required starting orientation is enforced.
- Recording rotation is frozen; it is not changed by live rotation notifications or zoom controls mid-take.
- File completion success is checked before inspection/commit. UI waits for durable metadata before claiming a scene was saved.
- Journal recovery sorts pending takes by capture date/sequence. Commit checks idempotence again after asynchronous media inspection.
- Corrupt, unsupported-version, duplicate-ID, invalid-trim and inconsistent-path catalogs fail closed instead of being overwritten.
- Catalog writes are atomic; journals cover the source move/database gap. Originals and directories use protection that remains readable after first unlock during finalization.
- Scene/movie deletion preserves files and trim/sequence data. Recently Deleted provides restoration.
- Preview and export share aspect-fitting semantics; playback and export use one composition builder.
- Audio insertion intersects selected video and source audio ranges and preserves their offsets. Missing audio is allowed.
- Export uses an immutable snapshot, blocks duplicate starts, monitors framework progress, supports cancellation, verifies duration and portrait/landscape dimensions, and preserves originals.
- Export uses the configured 1080p composition canvas with the highest-quality preset rather than forcing a landscape-sized preset onto portrait output.
- Files uses the native document picker for a file URL, avoiding a large in-memory file-document copy.
- Export cache reuse validates revision, duration and dimensions; cache cleanup affects disposable old exports only.
- Thumbnail caching is bounded to 48 entries and 32 MiB; the media pipeline never decodes every movie frame at once.
- Free-space inspection has a fallback capacity query and a clear failure when capacity cannot be determined.
- Camera pause completes before switching to playback audio, avoiding an audio-session deactivation race.

## Safety fixes in this revision

- Previous valid catalogs are snapshotted before atomic replacement. Damaged catalogs remain preserved when a previous version is repaired.
- A persistent load-failure view keeps recovery available after an error alert is dismissed.
- Manual editable-project backup retains originals, trims, sequence and recoverable deletions. A maintenance gate prevents edits or new recordings while a snapshot is copied.
- Backup and restore stream video in bounded chunks, preflight free space and support cancellation. Backup hashes and media metadata are verified before imported movies enter the catalog.
- Restore uses new movie/scene identities, preserves existing movies, coordinates external file-provider reads, rejects symlink payloads and constrains manifest paths.
- Backup receipts distinguish picker-confirmed Files save from iCloud synchronization. Revision tracking exposes changes since the last saved snapshot.
- Optional Photos safety copies run after local commit, with add-only permission and separate receipts. Receipt persistence cannot be transactional with Photos; retries may duplicate a copy after a crash between those steps.
- Recovery lists unassigned footage and preserved metadata, allows exporting copies, and can import playable MOV copies into a new movie without deleting recovery originals.
- Portable validation and cloud workflows are provided. Cloud signing and uploads require repository/account integration; none has been performed here.
- No login or analytics SDK was added. Accounts are unnecessary for the current local features.

## Concept and interface refinement

- Core flow stays account-free: choose a movie, record, confirm the durable save, review, and export. Accounts would add no current recording or storage capability.
- Movies uses a compact native inline title with Settings and New Movie in the navigation bar; removed the redundant bottom toolbar and count.
- Controls use system typography, symbols, hit targets and actual guarded Liquid Glass. Decorative duration badges no longer use an interactive glass effect.
- The recent-scene camera thumbnail opens that scene's review, matching its accessibility label. Watch Movie still opens the assembled movie.
- Disabled recording controls dim visibly; singular scene count is corrected. New Movie enforces the name limit and shows failures inside its sheet.
- Playback and review are scrollable for compact height and larger text. Selected trim end bounds review playback; the recording timer uses monotonic system uptime.
- A native Privacy screen explains local storage, permissions, external copies, and recoverable deletion. A public hosted privacy-policy URL and developer/contact details still need to be supplied for store metadata.
- These are source-level refinements. Native screenshots, material contrast, VoiceOver, largest Dynamic Type, rotation and performance still require device review.

## Automated tests supplied, not run

`PipelineTests` contains eight XCTest cases using generated H.264 video fixtures:

1. Independent movie persistence and idempotent commit.
2. Completed-but-uncommitted recording recovery.
3. Invalid recording preservation without a commit.
4. Original-byte preservation across trims/deletion/restore and invalid-trim rejection.
5. Immutable composed sequence and export agreement for silent/mixed-orientation sources.
6. Full portrait export dimensions.
7. Fail-closed handling of damaged catalog data.
8. Aspect-fit transform bounds and centering.

`BackupTests` supplies five additional tests: byte/trim-preserving round trip, tampered payload rejection, maintenance and cancellation cleanup, previous-catalog repair with damaged-file preservation, and decoding legacy metadata without the new optional fields.

The fixture generator itself and all native tests still require compilation and execution in Xcode. They are not substitutes for recordings from actual cameras. The device matrix includes audible captures, calls, audio routing, frame charts, both landscape orientations, interruptions, low storage, sharing and long movies.

## Outstanding acceptance and product work

- **Release blocking:** compile with Xcode 26+, resolve any Swift/SDK diagnostics, run supplied tests, pass the real-device matrix, inspect output codec/audio/framing and measure long-movie memory/thermal behavior.
- Actual Liquid Glass is used on supported systems; the HTML mockup is illustrative and does not prove the native material or typography on-device.
- Some mutable video composition APIs are deprecated by newer SDKs but supported for the iOS 18 baseline. Modern composition API migration is deferred and documented.
- Foreground export only; no BGContinuedProcessingTask integration. Leaving the app cancels and requires a retry.
- JSON metadata storage is a local first-build choice; very large libraries will need a database and measured migration path.
- Recovery preserves incomplete files but cannot make all interrupted takes playable. Preserved-file export/import and previous-catalog repair are included in source; they still require runtime validation.
- No permanent-delete UI; recoverable deletions continue using space. Settings reports committed source bytes, not all app disk usage.
- Full editable-project backup/restore is implemented in source, but not runtime-tested. External-copy durability and a fresh-device restore are acceptance gates before archive claims.
- App Store signing, privacy review, real-device accessibility checks and final icon refinement remain outside the checks completed here.


## First cloud build — 2026-10-10 correction

The supplied Codemagic result bundle for commit `2c369981b632a13866cb7e8a5e97e17e22ebb490` shows that the app failed Swift compilation. XCTest was cancelled before execution. The bundle reports three distinct compiler errors; this revision corrects all three:

- `MediaAssembler.swift`: added the required `otherRange:` label to the audio-range intersection call.
- `WatchMovieView.swift`: awaited the initial asynchronous AVPlayer seek; synchronous trim callbacks explicitly use the completion-handler overload.
- `WatchMovieView.swift`: moved thumbnail sample mutation into an ordinary helper function, outside SwiftUI's view builder.

The simulator script now captures a plain-text `build/xcodebuild.log` using `tee` and retains `pipefail`, so logging does not hide a failed build. Both Codemagic workflows publish the log as an artifact.

Portable grammar/configuration checks pass after these changes. Compilation and XCTest for the corrected revision are **pending the next cloud build**. This is a targeted correction of reported compiler errors, not a claim of a passing native build or device test.
