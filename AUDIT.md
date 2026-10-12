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
- Live preview fills the display; preview edges may be cropped to the screen aspect. Saved footage retains the full source frame. Movie format is explicit and required starting orientation is enforced.
- Recording rotation is frozen; it is not changed by live rotation notifications or zoom controls mid-take.
- File completion success is checked before inspection/commit. UI waits for durable metadata before claiming a scene was saved.
- Journal recovery sorts pending takes by capture date/sequence. Commit checks idempotence again after asynchronous media inspection.
- Corrupt, unsupported-version, duplicate-ID, invalid-trim and inconsistent-path catalogs fail closed instead of being overwritten.
- Catalog writes are atomic; journals cover the source move/database gap. Originals and directories use protection that remains readable after first unlock during finalization.
- Scene/movie deletion preserves files and trim/sequence data. Recently Deleted provides restoration.
- Playback and export use one aspect-fitting composition builder. Live preview uses aspect fill to cover the screen; this presentation does not crop saved source files.
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

## Second cloud build — 2026-10-10 correction

The supplied plain-text log for commit `94f6cace6e0c7e887e95c16cc4f183367f2fc015` reports 12 test-target compiler errors with one cause: tests in a separate module cannot synchronously read the actor-isolated `ProjectStore.root`, including inside XCTest assertion autoclosures. The app target compiled, but test compilation failed and XCTest did not execute.

`root` is now explicitly `nonisolated let`: an immutable, Sendable URL set during initialization. Mutable storage state remains actor-isolated. This allows both test modules to read the configured directory without disabling concurrency checks or introducing unsafe isolation overrides.

Portable source checks pass. Native test compilation and all 13 supplied tests remain pending a new cloud build.

## Third cloud build — 2026-10-11 correction

Codemagic build 3 for commit `168d71c793d7b4aac245f6ec99ac23f6ab92e966` compiled the app and test targets and executed all 13 tests: 11 passed, including all five backup tests; two video-export tests failed with AVFoundation -11838 / OSStatus -16976. This proves execution of the supplied storage/recovery/backup tests, not real-device recording or release readiness.

Both failures export video-only fixtures. Inspection found that the shared assembler always created an empty audio track, with no media segments or audio format. This revision creates the audio track only when a source has an overlapping, nonempty audio range, so silent movies contain only video. Video-composition frame timing now explicitly references the populated video track. The existing export tests retain their duration and full-frame dimension checks and now also check that silent compositions/exports contain no audio track.

The empty audio track is the suspected common cause; confirming the fix requires another cloud run. Portable grammar/configuration checks pass. No tests were skipped or weakened, and no native rerun has been performed here.

## Passing GitHub build and signing setup — 2026-10-11

GitHub Actions run `38166745629` at commit `b684eb8a8256e1196439a9b70c21721019ff8323` compiled both targets and executed 13 tests with zero failures. Both previously failing landscape/portrait silent-export tests passed after the track setup correction. Logs report 79.322 seconds for all tests. This is a simulator result, not device-camera validation.

The generator default now uses the user's registered `com.falconcraft.homemovie` identifier. A manual, main-only GitHub workflow runs tests before automatic Apple signing and internal-only upload. It uses standalone CLI tools, not Codemagic's hosted service. Signing requires an Admin API key and a persistent certificate private key in GitHub Secrets. Signing and upload are pending that setup; no native build of this configuration or TestFlight upload has yet run.

## Signed archive validation — 2026-10-11 correction

The user's retry passed tests, Apple authentication, signing, archive, and IPA export. Apple package validation rejected two occurrences of the reserved `com.example.homemovie.backup` type with error 90847 and warned about document opening mode (90737). Upload did not complete.

The exported backup type, document-handler type, and Swift UTType now use `com.falconcraft.homemovie.backup`. The package extension and backup contents remain compatible. `LSSupportsOpeningDocumentsInPlace` is explicitly false because restore imports separate copies rather than editing an external project in place. Portable validation now checks the type declarations, runtime identifier agreement, and document configuration; both GitHub workflows run these checks before native tests.

Local source checks pass. A new signed build and Apple package-validation run are required to confirm acceptance of this correction.

## Edge-to-edge camera — 2026-10-11

User-provided iPhone screenshot showed the preview boxed into a movie-aspect rectangle with side margins, separate header, and bottom control area. The camera now renders its live preview across the display, including safe-area backgrounds. The header, timer, available lenses, record/stop button, recent scene, camera flip, and review controls overlay the image. Subtle top/bottom gradients preserve control contrast. Portrait and landscape controls remain within safe areas; the preview no longer reserves space for them.

AVCaptureVideoPreviewLayer uses aspect fill, which trims some visible preview edges on screens with a different aspect ratio. Capture settings and saved/exported frames are unchanged. This supersedes the earlier full-frame live-preview preference following the user's explicit full-screen request. Local Swift grammar/project checks pass; native compilation and physical-device layout verification of this revision are pending.

## Device-native zoom choices — 2026-10-11

The user reported a missing 8× option. The previous list included only minimum zoom and physical virtual-device switch-over factors. It now also includes the active format's secondary native-resolution factors, plus constituent camera factors converted into virtual-device coordinates. Apple's documented switch-over ordering supplies the coordinate conversion. The display multiplier converts internal factors into camera labels; unsupported/out-of-range factors are excluded and duplicate factors are merged. This can expose native-resolution 2×/8× choices on devices/formats reporting them without adding a fixed 8× button to every phone.

Two regression tests cover 0.5×/1×/2×/4×/8× labels, duplicate factors, older hardware without secondary modes, and active zoom limits. Fifteen tests are now supplied. Local grammar/configuration checks pass; the new tests and physical-device 8× capture verification are pending.

## Tap focus and exposure — 2026-10-11

The live preview now accepts taps while ready or recording, displays a yellow focus square, and requests continuous autofocus and automatic exposure at that point when each capability is supported. AVCaptureVideoPreviewLayer converts screen coordinates into device coordinates, accounting for aspect-fill cropping, orientation and preview mirroring. Configuration stays on the capture queue and does not stop recording. Fixed-focus cameras can still meter exposure when supported. Significant subject-area changes restore centered continuous metering; this is not AE/AF lock. A configuration error is a nonfatal notice rather than a recording failure. The square acknowledges the request, not confirmation of optical focus.

Portable grammar/configuration validation passes. Native compilation and on-device focus/gesture verification are pending. Other unimplemented familiar video controls include long-press AE/AF lock, exposure-bias adjustment, torch, stabilization selection, supported resolution/frame-rate selection, and grid/level guides. Capture remains 1080p/30 SDR with stabilization off.

## Familiar iPhone camera interactions — 2026-10-11

Following the user's request to use familiar native-camera controls, press-and-hold requests one-shot autofocus/autoexposure, which settle and hold rather than continuously remetering. Subject-area resets are suppressed while locked. The camera shows an AE/AF LOCK badge; a new tap unlocks and resets exposure bias. A yellow sun beside the focus square supports vertical dragging to adjust hardware-clamped exposure bias. Single-finger vertical drags near the indicator are recognized separately from two-finger pinch zoom. Configuration notices do not interrupt a recording. VoiceOver custom actions offer centered focus/lock and brightness steps.

A compact lightning control replaces the empty header space on cameras with a torch. It can toggle during recording, checks current availability before illumination, and turns off when switching cameras or leaving the capture session. Front cameras without a hardware torch omit it. These are custom controls using AVFoundation and UIKit gestures, following familiar iPhone Camera interactions; the app does not embed Apple's stock Camera interface.

This supersedes the prior missing-controls list for AE/AF lock, brightness adjustment and torch. Stabilization selection, resolution/frame-rate selection, and grid/level remain unimplemented. Portable checks pass; native compilation and physical-device gesture/torch/lock verification remain pending.

## Camera stability audit — 2026-10-11

Reviewed the new gestures and controls alongside capture startup, stop, interruption, camera switching and durable storage handoff. Fixed a race where a stop/background/interruption during asynchronous ticket creation could still start recording. The model now checks cancellation immediately before handoff, ignores outdated permission completions, and closes background-save time on cancelled/failed preparation. Unstarted cancellation removes only a journal with no staging/original file and no committed scene; any recording bytes and their journal are retained. Two regression tests cover clean cancellation/relaunch/subsequent recording and preservation of both staging and original bytes. Seventeen tests are now supplied.

The capture queue retains a stop request through the interval before AVFoundation's didStart callback. Started/finished callbacks are matched to the active file URL, and capture state changes remain serialized. Zoom rejects nonfinite/nonpositive input, uses current hardware bounds, and configuration errors are nonfatal notices. Controls reject use while inactive/interrupted. Focus failures restore authoritative UI state; subject-area resets publish updated metering.

Camera switching restores the prior input if the new configuration fails, or marks the session for reconnection if recovery fails. Recording connection settings are reapplied after switches. Runtime errors request stop, extinguish the torch and require fresh configuration on resume. Camera/audio interruptions also request stop and extinguish the torch. Preview indicators retain device coordinates across rotation and clear when switching front/back cameras.

Portable Swift grammar, project, permissions, privacy and document checks pass. Native build/test execution for this revision is pending GitHub's Mac runner; the preceding automatic revision was still pending at audit time. No native tests or physical-device race/gesture/thermal tests were executed locally. This audit does not establish that the app is crash-free or release-ready. Existing original-media, atomic catalog, journal recovery and backup protection are retained.

## Native gesture compilation correction — 2026-10-11

GitHub run 38175522102 for commit 514de18f compiled far enough to report that UIView already declares gestureRecognizerShouldBegin(_:); the preview's implementation requires override. Added the missing keyword. That build failed before test execution. Portable grammar checks pass; a new native run is required to validate the correction and stability revision.

## Full-app source audit — 2026-10-11

Read all 18 Swift files, the project generator, simulator/upload workflows, Info.plist, privacy manifest and test sources. Scope included camera/recording, local catalog and recovery, backups/restoration, playback, trimming, export, Photos safety copies, navigation and documentation. This was source review plus portable validation, not a claim of full runtime/device coverage.

Additional fixes: failed AppModel reloads clear the ready flag; decoded catalogs are validated before becoming authoritative, so rejected metadata cannot hide footage from recovery. Storage metadata is bounded and summed with overflow detection. Duration labels safely handle extreme finite times without trapping or truncating large hour counts. Video inspection/composition reject invalid ranges, dimensions and nonfinite transforms before configuring composition layers. Canceled thumbnail/review tasks do not publish late results. Backup/restore controls cannot overlap previous-catalog repair, copying has additional cancellation checkpoints before installation, and backup creation enforces the same manifest-size limit as restore. Photos retry batches are deduplicated, stop starting new copies after opt-out, and check cancellation before submitting a Photos change. Already accepted Photos writes retain their receipts.

Four more regression tests cover malformed video geometry, extreme/invalid duration labels, unsafe catalog storage plus recovery-file visibility, and failed app reload state while preserving catalog bytes. Twenty-one tests are supplied. README now reflects the successful prior TestFlight upload, actual bundle identifier, edge-to-edge preview, native-resolution zoom and familiar metering controls.

Reviewed existing protections without changing them: atomic catalog/previous-catalog writes, immutable original footage during trimming/deletion, journal recovery, streamed backup checksums and path validation, separate restored identities, immutable playback/export snapshots, bounded thumbnail memory, add-only Photos access, and task-based asynchronous export cancellation. Silent exports and backup behavior passed in the previously uploaded native revision; mixed microphone audio, long recordings/exports, low storage, thermal shutdown, Files/iCloud materialization and full accessibility/device acceptance still require physical-device checks. Latest 17-test camera revision was still running on GitHub during this broader audit. Current 21-test revision awaits its own native build.

## Camera stability native result — 2026-10-11

GitHub run 38176139953 for commit 14d68e8e079d1be282d67973c4f1002e22c66a78 compiled the app/tests and executed all 17 tests with zero failures (148.639 seconds of test execution). This confirms the missing-override correction and supplied cancellation tests, as well as existing zoom, storage/recovery, backup and silent export coverage. It does not exercise physical camera controls. The broader audit adds four tests and awaits its own 21-test run. Deprecated session notification spellings are updated to the SDK's recommended names without changing notification behavior.

## Full-audit test compilation correction — 2026-10-11

Run 38176808347 compiled the application but stopped in the new geometry regression test: CGSize's CGFloat/Double initializer overloads made .infinity ambiguous. The fixture now explicitly uses CGFloat.infinity. No tests ran in that failed revision; a new run is required.

## Watch Movie timeline visibility — 2026-10-11

Replaced the vertically scrolling, width-sized movie preview with a bounded player above an intrinsically sized scene timeline. The timeline and recording action receive space first; playback fits the complete movie frame within the remaining area. The scene strip uses shorter thumbnails in compact-height landscape, keeps horizontal scrolling, and exposes review/trimming hints to VoiceOver. No stored footage, composition or export dimensions change. Portable source/project checks pass; native compilation and physical-device layout acceptance are tracked separately.

## Full-app audit native result — 2026-10-11

GitHub run 38176920518 for 448f36b011dbcdf64c75b58c7d42bde18b63aa15 compiled the app and executed all 21 tests with zero failures (97.879 seconds). This validates the full-audit fixes and corrected geometry fixture. The following Watch Movie layout change requires its own native compilation; physical-device acceptance remains pending.

## Library export entry point — 2026-10-11

Each movie card now offers Export at the top of its three-dot menu. The item presents the same ExportView used by Watch Movie, retaining MP4 preparation, Save to Photos, Save to Files, Share Video, progress and cancellation. Export is disabled for movies with no active playable scenes. The item sheet captures the selected movie snapshot and receives the existing AppModel. Portable source checks pass; device menu/presentation acceptance remains pending.

## Automatic recording orientation — 2026-10-11

Removed the New Movie format picker. Empty movies follow camera rotation automatically. Record snapshots the camera coordinator capture angle and format before asynchronous journal preparation, applies that angle once to the movie-file output, and retains it for the take. A separate coordinator tied to the actual preview layer applies horizon-level preview angles as the phone rotates, including during recording. The edge-to-edge preview remains aspect-fill in portrait and landscape. Apple reference: https://developer.apple.com/documentation/avfoundation/supporting-device-rotation-in-your-camera-app

The first playable saved scene persists its format atomically with scene metadata. Capture journals carry an optional format so startup recovery preserves the first take’s choice; legacy journals infer it from inspected media. Subsequent scenes are gated by camera rotation in UI/model/storage. Deleted scenes and lastRecordedAt retain the existing lock, preserving existing movie canvases. Canceled or failed first attempts do not lock an empty draft. Four regressions cover both landscape directions, portrait capture, first-scene locking/relaunch/deletion, canceled first attempts, recovery and old journal decoding. Twenty-five tests are now supplied. Native and physical-device rotation checks are pending.

## Native orientation validation and optional Log looks — 2026-10-11

Orientation revision d70fa524028219e806d7853c05ff4f8f9da60643 compiled and passed all 25 simulator tests in GitHub run 38177797042. Hardware orientation remains a device acceptance item.

Added an optional Apple Log capture profile in New Movie only on supported devices. Standard remains the default with no Look controls. Log setup exposes a quiet Look row; playback exposes a single Look menu, with Apple Standard, imported Apple Log cube looks, and a temporary Show Original comparison. The selected look applies to Watch Movie, scene review, and export through one custom compositor; Show Original is comparison-only and does not change the exported look. Movie revisions invalidate old export caches when selection changes. Imports remain in the private app container and are included, with checksums, in backups. Restore assigns fresh look identities. Cinema’s paid assets are NOT included in the public repository; import Cinema.cube through Files. The .drx effects are not implemented by the color LUT.

Apple’s supplied 65-point Log-to-Rec709 table is packed as zlib-compressed unsigned 16-bit RGB, retaining all samples with <= 1/65535 quantization error, and decoded once to RGBA float data. The custom compositor requests high-bit-depth source buffers, disables automatic source-color conformance and Core Image color matching, applies the cube to encoded Log values, preserves spatial transforms/full-frame fitting and outputs tagged Rec.709. This avoids accidentally applying the transfer conversion twice. Cube imports validate dimensions 2...65, exact sample count, finite ranges/values, file-size limits and domain normalization; 1D linear-conversion LUTs are rejected. Log and look metadata use optional fields for old catalogs/journals/backups.

Capture selects an Apple Log-capable format at 30 fps, disables automatic wide-color configuration, sets activeColorSpace to original Apple Log, and selects HEVC at the recording boundary. It never silently falls back to Standard. Commit verifies the recorded track’s Apple Log metadata; unverified footage is preserved for recovery. Supported camera switching is discovered for the chosen profile. Log may require a higher-resolution capture format; assembled/exported movies remain 1080p SDR. This path still requires physical-device codec/bit-depth/metadata and lens validation.

Five new tests cover malformed cube input, the built-in conversion resource and legacy metadata, persistent selection/revision changes, selected-look backup restoration, and shared preview/export rendering with a custom compositor. Native execution is pending. Cinema input/output settings and exact appearance still need its guide or a Resolve reference; this implementation accepts looks intended for original Apple Log input with SDR output. Log 2 and arbitrary Rec.709-input creative LUT chains are not silently substituted.

First Log native run 38181083865 stopped at application compilation: Resume Camera used optional chaining on its nonoptional Movie argument. Corrected that reference, matched the current AVVideoCompositing Sendable dictionary signatures, and retained a supported remembered front camera rather than unconditionally choosing rear for Log. No tests ran in that failed revision.

Second Log native run 38181203567 compiled the application without compositor concurrency warnings, then stopped in a backup test because its second throwing load lacked try. Both test loads are now evaluated explicitly. Added one regression for atomic movie creation with its initial look, tightened decoded LUT alpha/range validation, and used ObjectIdentifier for the compositor-class assertion. Thirty-one tests are supplied.

The third Log run remained in its compile/test step beyond twelve minutes without downloadable live logs. Confirmed an independent built-in asset bug: Apple Compression ZLIB consumes RFC 1951 raw DEFLATE, while the packed resource has Python’s RFC 1950 zlib wrapper. The decoder now strips the two-byte header and four-byte checksum before inflating. The suite now enforces per-test limits (60-second default, 120-second maximum) so stalled rendering reports a failure. Canceled playback loads cannot clear the loading state for a newer look request. Native validation continues.

## Quiet established format and live looks — 2026-10-11

Renamed the uploaded cube and PowerGrade files to Cinema.cube and Cinema.drx, and removed the former look name from current repository source, tests and documentation. No history rewrite was performed. Native run 38182206301 confirmed the built-in conversion decoder now passes and the shared compositor still passes; the run failed only because two existing simulator media fixtures exceeded the newly tightened one-minute timeout. Test budgets now allow up to six minutes for cold simulator encoder startup while remaining bounded.

Added an app orientation delegate and leased UIKit scene geometry policy. New movies follow rotation, the first take pins its format, and established Camera/Watch Movie pages request portrait or landscape directly. Recording uses the established interface angle and no longer disables the record button or displays a request to rotate. Storage retains a format consistency guard without an instruction to rotate. Child presentations cannot accidentally release another screen’s orientation lease.

Log capture includes a high-bit-depth AVCaptureVideoDataOutput alongside the untouched movie-file output. A separate Metal/Core Image view applies the selected cube live, using the same unmanaged encoded-value cube operation as playback/export. The newest frame replaces the previous one, UI wakeups are coalesced, and only one GPU render is in flight. Late frames are discarded; no preview frame modifies original capture. Preview remains aspect-fill, capped at a 1920-pixel longest drawable edge, with rotation, front mirroring and metering overlays aligned. Native preview continues underneath and is used for Original comparison and Standard mode. Live Look supports selection and original comparison during recording; Files import is disabled while a take is busy. Three more regressions cover established-angle selection, aspect-fill/mirroring geometry, and bounded latest-frame replacement. Thirty-four tests are supplied; physical-device live rendering, dual-output capture, orientation requests, focus alignment and performance still require acceptance.

Live-preview run 38183482779 found two iOS API spellings: the Metal view color-space property is macOS-only, so iOS uses CAMetalLayer.colorspace; AVCaptureVideoDataOutput’s Swift pixel-format list is availableVideoPixelFormatTypes. Corrected both, selected HEVC during Log configuration before session start, and ensured the invisible initial Metal frame remains drawable. No tests ran in that failed compile.

## Complete native result — 2026-10-11

GitHub run 38183715011 for source revision 468bb983a8cf4408752d9a91a0fb04121141304d compiled the application/tests using Xcode 26.6 and executed all 34 tests with zero failures (176.806 seconds). This confirms the Apple conversion resource, custom color compositor preview/export comparison, private selected-look persistence and backup round trip, atomic initial-look setup, both-format/mirror aspect-fill math and latest-frame replacement, plus the existing camera/storage/orientation regressions. No source changes follow this result; this commit records validation only. Physical-device dual-output Apple Log capture, live Metal presentation and actual scene-geometry requests cannot be established by these simulator tests. The signed internal TestFlight upload recorded earlier remains the baseline; current source needs its next TestFlight workflow run and full device acceptance.

## Live-preview handoff and setup audit — 2026-10-12

Reviewed camera lifecycle/interruption handling, serial output ownership, private LUT loading, preview/export composition, playback-task cancellation, atomic scene/catalog writes, soft deletion, Photos receipts and backup/restore checks. Found a concrete live-preview presentation race: a Metal completion could re-enable the graded overlay after Original comparison or capture suspension because the renderer retained its cube. Renderer configuration now clears inactive inputs and assigns a presentation identity when its source or color data changes. Completion only reveals the overlay for the current active identity. Switching looks hides the previous drawable until the replacement renders. Identical timer/metering updates retain the identity, so they cannot starve presentation. Camera look loading also clears the previous cube immediately.

Two regression tests exercise Original comparison, suspension/resume, unchanged-look updates, domain changes and capture-source replacement through the actual renderer configuration. New Movie can expand from medium to large for keyboard and larger-text use, and cannot be dismissed during an import. Thirty-six tests are supplied. Portable source/grammar/configuration validation passes; this revision still requires the native GitHub run and physical-device acceptance.

Run 38187868797 for d750f6eed1533962394d0aeb6f0374baf12623d7 compiled and passed all 36 tests (70.220 seconds), including both live-presentation regressions. Logs identified captured weak-variable concurrency warnings in the nested live-frame callback. Its main-queue closure now explicitly captures its own weak references rather than sharing the outer closure’s mutable weak slots. New Movie’s Cancel button now matches the import dismissal guard. A final native run is required for these follow-up changes.

The independently started TestFlight run 38187684998 successfully tested, signed, validated and uploaded source 7ba9e7cad6632792d9370d9c2d6e7824dd40a089 as version 0.2.0 build 1031. This includes the previous 34-test live/orientation implementation; it does not include the current presentation audit changes. Apple processing and physical-device acceptance remain separate.
