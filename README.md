# Home Movie — native iPhone foundation

A SwiftUI iPhone application for recording multiple ongoing movies, scene by scene. Choose a movie, record a take, and it is appended only after its file has been validated and committed. Watch the assembled sequence and export a separate MP4 whenever you like.

## Status — read this first

Current source `2b287a0e` compiled and passed all **85 native simulator tests with zero failures** in [GitHub Actions run 38279445539](https://github.com/falconRUBIO/home-movie/actions/runs/38279445539). No application-source compiler warnings were reported. The suite covers Apple Log/Cinema GPU rendering, backup/recovery, audio and export, countdown, Dolly duration/continuity, adaptive drag speed, response settings, nearby retargets, queue stalls, temporary lens ranges and measured route progress.

The live Cinema preview now uses a visible Metal overlay with a capped 30 fps display loop. The badge reports the look only after successful rendering; Loading look and Preview unavailable describe other states. Native tests verify selected Cinema pixels on eight/ten-bit input and a graded frame reaching the visible preview. Confirmation on the reported iPhone requires a new build; capture originals remain untouched.

Movies stay in one column for one to three titles and switch to two columns at four or more. Movie/scene deletion uses centered native alerts. Assembled playback/export uses five-millisecond audio edges to soften hard-cut clicks, with full volume between edges and unchanged scene timing/originals. Inaudibility and the reported click still require phone listening; old cached exports are rebuilt.

The October 12 audits fix late readiness callbacks hiding recording failures, premature/elapsed-time Dolly completion, mixed-profile orphan recovery, the live grade dropping during saving, playback changes during buffering, unopened-library restore metadata loss, unsupported catalog overwrite, restored Cinema naming and false/duplicate Photos export success. Genuine camera recording, measured hardware zoom timing, real Photos writes and live-LUT color accuracy still require an updated TestFlight build and phone acceptance.

Tapping + opens New Movie in Standard on every phone. Apple Log is opt-in on supported cameras; the supplied LUT is called Cinema and is already bundled. The camera and Watch Movie show LOG · Cinema or LOG · Original to match the viewing mode. Dolly has one shared control bar and a right-side 1/2/3/5/8/10-second selector (3 by default). Hands-Free Start is an optional three-second countdown, with cancellation and a prepared Dolly move starting only after recording begins. Saving/Saved/Undo remain beside the recent-take thumbnail. The library action menu attaches to its ellipsis; Watch Movie autoplays from the recording page.

See `AUDIT.md`, `VALIDATION.json`, and `DEVICE_TESTS.md` for evidence and limitations.

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
- Native-style black control areas above/below the portrait `.resizeAspectFill` viewfinder, with a side recording panel in landscape. Display edges can be trimmed to fit the viewfinder, while saved recordings retain their full source frame. Landscape movies require a landscape interface; portrait movies require portrait. Capture rotation is frozen for a take; composed playback/export letterbox differing source geometry rather than crop it. Front preview is mirrored; recorded footage is unmirrored. Verify on device.
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

### Smooth Zoom

Tap the waveform button after the lens buttons to open Dolly. The slider and lens buttons share one expanded glass control bar and leave the viewfinder framing unchanged. While open, tap a lens value to zoom automatically from the current position to that value, including 1× to 8× or the reverse where supported. Endpoint outlines and progress follow measured zoom. The right-side seconds menu offers 1, 2, 3, 5, 8 or 10 seconds (3 by default) for the full automatic move, including eased start and finish. Manual dragging adapts to hand speed; Camera Settings holds Slow/Normal/Fast Manual Dolly Response and the device-dependent Stay on This Lens option. Slider, pinch and automatic retargets preserve motion while Dolly is open. Release to settle; close to stop and hold. The controller applies one trajectory at 60 Hz, preserving the requested lens through temporary range limits. Long capture-queue stalls pause the curve rather than causing catch-up jumps, so completion may be later under load. Closed lens taps remain direct. Zoom is applied during capture. Hardware handoffs, actual saved-frame smoothness and low-light/focus/thermal behavior still require iPhone acceptance.


### Scene review: Light, Color, and FX

Review Scene uses bottom tabs for Light, Color, FX, and Trim. Light holds exposure, brightness, brilliance, push/pull, shadows, and highlights; Color holds warmth and tint. FX contains Halation, Glow, Grain, Optical Softness, and Highlight Roll-Off. Light and Color apply to the selected scene; FX is labeled **All scenes** and uses the movie-wide settings included in exports. The former Film Effects entry in Export has been removed. Hold Original compares without Light, Color, or FX while retaining the selected look. Reset affects the selected tab. Save commits scene and FX edits together; Cancel can discard them. Save to Photos saves and exports the current scene with the complete recipe. Effects start off, preserve values when disabled, and leave recordings unchanged.

The engine uses original, build-time Metal Core Image kernels and Apple Gaussian diffusion, with no third-party dependencies or copied GPL shaders. Grain animation derives from the 30 fps timeline, so paused/seeked frames are reproducible. Optical stages work on a linearized selected SDR rendition; physical-camera visual calibration and encoded export quality require device acceptance. Xcode's Metal Toolchain component is required to build.

### Compare private Rec.709 looks

In an Apple Log movie, open the Look menu and choose **Add Rec.709 Look…** for display-referred Rec.709/sRGB `.cube` files. Import each look once, then select it from the same menu in Camera or Watch Movie. This bakes Apple Log → Apple Standard → creative LUT into one shared preview/playback/export table; imported source comments and titles are retained in the stored look and backups. **Add Apple Log Look…** still imports LUTs that already expect Apple Log without another conversion. Imported assets stay private to the app container; no third-party comparison LUTs are bundled in the repository. Use the same clip, neutral Light adjustments and disabled Film Effects for comparisons. Native build/tests and visual color accuracy require verification.

### Per-scene color balance

Review Scene → Light includes Warmth (blue/yellow) and Tint (green/magenta), centered at zero. Double-tap a value to reset that control. These nondestructive per-scene controls follow the selected look and are shared by preview, playback and export. Existing recipes decode with neutral color balance.

Cinema remains the only built-in creative look. Amber, Heritage and Ember are retired; projects and restored backups selecting those stable built-in IDs fall back to Cinema. Custom imported looks remain available.

### Apple Log dual-camera pipeline

Log PiP selects a compatible front/rear MultiCam pair whose formats support Apple Log at 1080p or higher and 30 fps. Both devices remain in Apple Log and output native 10-bit YCbCr. Spatial inset/split composition uses an unmanaged half-float Core Image working context and renders to 10-bit YCbCr, then records HEVC Main10. The selected Cinema look is applied to the composed viewing image, not baked into original Log recordings.

Before Log PiP preparation, a process-cached encoder check writes a short local test MOV, verifies its Apple Log format-description metadata and HEVC encoded component depths, and checks 10-bit decoding. Unsupported encoders fail preparation with an explanation; there is no SDR recording substitution. Actual captured buffers must also carry verified Apple Log metadata and 10-bit pixels. Saved scenes retain the existing metadata validation on commit.

The implementation requires native simulator encoder tests and physical iPhone acceptance for simultaneous streams, saved color, orientation, audio, thermal behavior and sustained recording. Hardware format advertisements alone do not establish working Log PiP. Apple’s newer explicit AVVideoLogTransferFunctionKey is introduced with iOS 27; the app resolves those documented public constants at runtime on iOS 27 and also supplies a source-format hint and propagated buffer metadata. Earlier OS versions can proceed only if the same encoder check proves that metadata survives writing.
