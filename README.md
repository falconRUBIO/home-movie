# Home Movie — native iPhone foundation

A SwiftUI iPhone application for recording multiple ongoing movies, scene by scene. Choose a movie, record a take, and it is appended only after its file has been validated and committed. Watch the assembled sequence and export a separate MP4 whenever you like.

## Status — read this first

The orientation, timeline and library-export revision `d70fa524` compiled and passed all 25 native tests in GitHub Actions run `38177797042`. Optional Apple Log capture/looks now supplies 34 tests and awaits its native run. A signed internal TestFlight build for `123e29e` uploaded successfully. See `AUDIT.md` and `VALIDATION.json` for evidence; complete physical-device acceptance remains pending.

## Automatic GitHub build tests

[Open GitHub Actions](https://github.com/falconRUBIO/home-movie/actions/workflows/ios-tests.yml). The **Compile and test Home Movie** workflow runs on every push to `main`, pull requests targeting `main`, and manually through **Run workflow**. It generates the project and runs the existing simulator tests on a hosted Mac. Failed tests fail the build; logs and zipped XCTest results are retained for 14 days. New updates cancel an older run for the same branch. This workflow requires no Apple signing credentials and does not upload to TestFlight.

## TestFlight without local Xcode

Start with `TESTFLIGHT.md`. The manually started **Upload internal TestFlight beta** GitHub workflow tests, signs, and uploads the app using Apple credentials stored in GitHub Secrets. It uses the registered `com.falconcraft.homemovie` identifier and requires the signing setup described there. The first signed upload succeeded; start a new workflow on main to upload later revisions. No login page is needed in the app.

## Open it on your Mac

1. Unzip this package into a folder on your Mac.
2. Install **Xcode 26 or newer**. The deployment target is iOS 18, with actual Liquid Glass guarded for iOS 26 and later.
3. Double-click **HomeMovie.xcodeproj**. Choose the **HomeMovie** scheme.
4. In the project’s **Signing & Capabilities**, select your Apple development team. The app uses `com.falconcraft.homemovie`. Keep the registered identifier and the matching test identifier unless intentionally registering a different app.
5. Connect an iPhone with iOS 18 or later. Enable Developer Mode if the phone asks. Select that iPhone as the run destination.
6. Press **Run** (the triangle at the top of Xcode). Allow camera and microphone access when opening the camera.
7. Choose **Product → Test** to run `PipelineTests` and `BackupTests`. Camera testing requires a physical device; generated-media unit tests can also run in Simulator.

If Xcode reports a compiler error, keep its complete diagnostic and file/line reference for the next revision.

Optional terminal commands on your Mac:

```sh
xcodebuild -project HomeMovie.xcodeproj -scheme HomeMovie -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project HomeMovie.xcodeproj -scheme HomeMovie -showdestinations
```

Then run tests with a destination identifier shown by the second command:

```sh
xcodebuild -project HomeMovie.xcodeproj -scheme HomeMovie -destination 'platform=iOS Simulator,id=YOUR_SIMULATOR_ID' test
```

## Included behavior

- Multiple independent movies, creation and rename, default library launch, optional last-movie launch, remembered camera and selected movie.
- Native SwiftUI navigation, menus, forms, sheets, accessibility labels and scalable system typography. No reproduction of a fake camcorder interface.
- Compact movie picker with native `glassEffect` on iOS 26; standard system material on iOS 18–25.
- Familiar red video button in a white ring, stop square, latest-scene thumbnail, front/rear switch, timer, and saving state.
- AVFoundation discovery of virtual rear cameras and available front cameras; lens choices derived from switch-over and secondary native-resolution factors, converted with `displayVideoZoomFactorMultiplier`. No hardcoded 0.5/1/3/5 list. Pinch zoom clamps to device limits. Virtual cameras decide which physical sensor to use; low light and other constraints can affect switching.
- Edge-to-edge `.resizeAspectFill` preview; display edges can be trimmed to fit the screen, while saved recordings retain their full source frame. Landscape movies require a landscape interface; portrait movies require portrait. Capture rotation is frozen for a take; composed playback/export letterbox differing source geometry rather than crop it. Front preview is mirrored; recorded footage is unmirrored. Verify on device.
- 1080p, target 30 fps, SDR capture. Video stabilization is initially disabled to avoid a stabilization crop changing the preview/export field of view. This must be assessed on device before offering stabilization.
- Explicit preparing, ready, starting, recording, finalizing, denied, interrupted and failed states. Movie and camera switching disabled throughout an active take and finalization.
- New movies choose portrait or landscape automatically from camera rotation at the first recording. The saved movie opens directly in its established format for later scenes without a rotation prompt. Preview rotation uses a separate layer-aware coordinator; recording rotation is fixed at Record.
- Tap focus/exposure, long-press AE/AF lock, vertical brightness adjustment beside the yellow sun, and a hardware torch toggle. Controls use available device capabilities; native gesture and torch behavior need physical-device verification.
- Serial capture configuration off the main thread. Recording destination frozen into a durable journal before starting. Short background allowance for finalization; no promise of background camera recording.
- Local versioned JSON catalog under Application Support, relative source paths, atomic catalog replacement, rational media times, retained originals and startup reconciliation. Damaged manifests fail closed instead of becoming an empty library.
- Startup recovery of playable journaled takes and orphan footage. Incomplete/unrecognized footage is preserved and reported. Recovery cannot reconstruct a video that the camera never finalized.
- Movie and scene deletion are recoverable tombstones, with restore from Settings. No permanent-delete feature in this foundation. Restoring retains sequence positions and trim metadata.
- Shared composition builder for playback and export, video track transforms, frame-fitting, asynchronous loading, correctly offset audio ranges, and support for scenes without audio.
- Native AVPlayer playback, scene strip, source scene review, accessible two-edge trim controls, original reset, and nondestructive trim metadata.
- Watch Movie keeps the horizontally scrolling scene timeline and Continue Recording action below a bounded, full-frame player; portrait playback no longer pushes the scenes off-screen.
- Export snapshot, real AVFoundation progress, cancellation, storage preflight, MP4 output validation, native Photos add-only save, Files picker, and system share sheet. Validated unchanged revision exports can be reused. Exports are kept alive for saving/sharing. Cache exports older than seven days may be discarded on launch.
- Foreground export baseline. Leaving the app cancels an in-progress export and offers retry; it does not falsely claim to resume at the same frame.
- Camera/microphone/Photos purpose strings, native Privacy screen, privacy manifest, and a provisional app icon. A hosted privacy policy and developer contact are required before a public store submission.

## Storage and safety boundaries

Originals are never stored only in Caches. Thumbnail cache is bounded; the movie pipeline references media on disk and does not decode an entire movie into memory. Exports live in disposable Caches; use Photos or Files for a lasting finished copy. Settings reports committed original-file bytes, including recoverable deletions; it does not claim that figure is the full app storage footprint.

The JSON catalog is suitable for a first local build, not an unlimited library of tens of thousands of scenes. File and catalog writes are not a single transaction; the journal covers the move/commit gap. This design does not promise recovery of every interrupted take. Settings includes preserved-file recovery and previous-catalog repair. Recovery keeps the source file, and cannot make every unfinished recording playable.

Project backups contain committed originals and edit metadata, including recoverable deleted scenes and movies. Backups use bounded streaming and SHA-256 checksums. Save the prepared `.homemovie` package through the native Files picker to a destination outside the app. The backup receipt records the snapshot revision only after the picker reports success. Later edits show that another backup is needed. A Files receipt does not certify completed iCloud synchronization.

Restore checks the manifest, paths, checksums and media, then imports separate movie copies with new IDs. It preserves existing movies and the source backup. A failed restore cleans its own transient files; a committed restore never deletes its installed footage. Keep external copies and verify a restore before relying on this as an archive. Backup is manual, uses extra free space, and excludes unfinished/unassigned files; use Recording Recovery to preserve those separately.

Optional original-scene copies to Photos run after the local scene commit. They use add-only permission and report separate Photos receipts. Photos copies preserve original videos, not editable project structure. iCloud Photos syncing depends on the user's Photos settings and is not confirmed by this app. A crash after Photos accepts a file but before its receipt is stored can produce a duplicate on retry.

No account, server uploads, analytics, automatic cloud synchronization, imported clips, filters, music, or scene reordering are included. Sign in with Apple would not back up footage. Exported MP4s do not preserve editable scene boundaries. Deleting the app can remove its local projects; external Files/Photos copies are separate.

The App Store privacy declaration, entitlements, actual binaries, accessibility, thermal behavior, long exports and all device acceptance results need release review. An export preset/container is checked at runtime; actual encoding and output behavior must be inspected on devices.

## Structure

- `HomeMovie/Core`: rational media data, durable store, app state.
- `HomeMovie/Media`: capture queue/delegates, camera state, assembly, export.
- `HomeMovie/UI`: native library, camera, watch, review/trim, export and settings.
- `HomeMovieTests/PipelineTests.swift`: generated video fixtures, persistence, journal recovery, invalid takes, nondestructive editing, composition/export and geometry tests.
- `HomeMovieTests/BackupTests.swift`: backup round trips, tampering, maintenance/cancellation, catalog recovery and legacy metadata decoding; these passed in the prior 13-test native suite.
- `TESTFLIGHT.md` and `codemagic.yaml`: repository, signing and internal beta setup; GitHub signing/upload has succeeded.
- `DEVICE_TESTS.md`: release-blocking device scenarios and an outcome log.
- `AUDIT.md`: audit findings, checks performed and known limitations.
- `scripts/generate_project.py`: deterministic regeneration of the already-included Xcode project; no XcodeGen dependency.
- `scripts/validate_source.py`: portable source/project validation. Optional Swift grammar check requires `tree-sitter` and `tree-sitter-swift`; it is not a Swift compiler.

## Apple references checked during implementation

- [AVCam architecture](https://developer.apple.com/documentation/avfoundation/avcam-building-a-camera-app)
- [Movie file output](https://developer.apple.com/documentation/avfoundation/avcapturemoviefileoutput)
- [Display zoom multiplier](https://developer.apple.com/documentation/avfoundation/avcapturedevice/displayvideozoomfactormultiplier) — documented as iOS 18+.
- [Virtual device switch-over zoom factors](https://developer.apple.com/documentation/avfoundation/avcapturedevice/virtualdeviceswitchovervideozoomfactors)
- [Rotation coordinator](https://developer.apple.com/documentation/avfoundation/avcapturedevice/rotationcoordinator)
- [Export API](https://developer.apple.com/documentation/avfoundation/avassetexportsession/export(to:as:isolation:)) and [progress states](https://developer.apple.com/documentation/avfoundation/avassetexportsession/states(updateinterval:))
- [SwiftUI glass effect](https://developer.apple.com/documentation/swiftui/view/glasseffect(_:in:))
- [Required-reason privacy APIs](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitypereasons)

Composition uses the older mutable instruction API because it supports the iOS 18 baseline. Those APIs are deprecated in newer SDK documentation but remain callable; a newer configuration API migration is deliberately deferred until an Xcode device baseline is established. This is not presented as a deprecation-free implementation.

### Optional Apple Log and looks

Standard is the default. Supported phones expose Apple Log under Recording in New Movie. Log movies have an optional Look row and a small playback Look menu. Apple Standard is included. Use Add Apple Log Look to import Cinema.cube or another original-Apple-Log-input / SDR-output 3D cube through Files. Imported assets stay in the app container, and the selected look is included in project backups. Cinema’s purchased LUT/PowerGrade files are not published in this repository. A cube provides color, not Resolve grain/glow/blur effects.

Show Original temporarily compares ungraded playback; export uses the movie’s selected look. Originals stay untouched. Color-managed playback/export use one compositor and selected-look revisions invalidate export caches. Actual Log capture and color accuracy require the physical-device acceptance tests; Cinema’s exact setup awaits its guide/reference. Apple Log 2 and LUTs expecting other input spaces are not interchangeable with this initial mode.

Log recording also has a small Live Look menu for the selected grade or original comparison. The GPU preview retains only the latest high-bit-depth frame, coalesces UI notifications and allows one GPU render in flight. Original movie-file capture stays separate. Standard recordings use the native preview layer without the additional render view. Camera and Watch Movie request the established interface format through UIKit; new movies remain automatic until the first take. Import Cinema.cube once through Files.
