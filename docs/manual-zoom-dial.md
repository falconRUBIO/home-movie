# Ordinary camera zoom dial

Scope: ordinary lens controls only. Dolly buttons, A/B endpoint editing, endpoint scrub previews, return-to-start behavior, countdown, duration, playback and pinch gestures retain their existing paths.

## Research

Apple's iPhone User Guide documents two complementary interactions: tapping model-dependent lens presets, and holding the zoom control then dragging left/right for precise continuous zoom. Its video guide calls this control a dial. The physical Camera Control is a separate interaction; this change concerns the on-screen lens strip.

- https://support.apple.com/guide/iphone/camera-basics-iph263472f78/ios
- https://support.apple.com/guide/iphone/record-a-video-iph61f49e4bb/ios

AVFoundation distinguishes displayed zoom from the raw device zoom factor. `displayVideoZoomFactorMultiplier` is intended for UI presentation. Available limits belong to the active device/configuration. Virtual camera switch-over factors describe where it may change constituent cameras; a wheel cannot guarantee that every intermediate value uses a physical lens. Intermediate and high zoom can involve cropping/upscaling. Front camera and PiP ranges can differ from ordinary rear capture.

- https://developer.apple.com/documentation/avfoundation/avcapturedevice/displayvideozoomfactormultiplier
- https://developer.apple.com/documentation/avfoundation/avcapturedevice/videozoomfactor
- https://developer.apple.com/documentation/avfoundation/avcapturedevice/virtualdeviceswitchovervideozoomfactors

Apple documents native zoom ramp rate in powers of two per second: exponential numeric change gives a visually linear transition. Use proportional travel in our control rather than distributing all raw factors linearly. Keep a single trajectory owner: the existing engine writes smoothed zoom on its capture queue, rather than launching another native ramp for every touch sample.

- https://developer.apple.com/documentation/avfoundation/avcapturedevice/ramp(tovideozoomfactor:withrate:)

Final Cut Camera's ramp dial is different: drag distance controls zoom rate and it stays within one lens. That behavior is inappropriate here; this control maps finger travel to framing across the current device's available range.

- https://support.apple.com/guide/final-cut-camera/adjust-zoom-and-focus-dev35227411d/ios

Apple does not document Camera's exact gesture thresholds, scale, snap behavior, haptic tuning or dismissal timing. The following are our choices, not reverse-engineered Apple constants.

## Interaction

- Quick tap keeps existing lens selection.
- Hold for 0.28 seconds, or begin dragging across a lens, to open the curved scale without switching to the touched preset.
- Leftward travel brings higher zoom marks to the center; 120 points doubles magnification. Rightward travel reverses it. Clamp to active device limits.
- Keep the touch attached to its original strip as the scale opens. Hold and pan can cooperate; a recognized scrub cancels the button tap.
- Show measured zoom, converted with the existing camera multiplier. Major markings identify available lens presets and range endpoints. No invented physical lenses.
- Give a light selection haptic when crossing a lens preset, rate limited to avoid buzzing. No magnetic snapping or release inertia.
- Release settles at the requested framing. The dial fades after 1.4 seconds; releasing does not restore an earlier framing. No timers drive zoom itself.
- Keep record, focus and PiP interactions available. A transparent gesture surface lets the visible wheel be regrabbed; its bounds are protected from viewfinder focus gestures. Disable interaction during camera switching/unavailable states and cancel the touch safely.
- Offer VoiceOver Zoom In/Out actions on each lens button and respect Reduce Motion.

The ordinary dial has token-based begin/end ownership over the existing smoothing engine. Late events from an old control cannot write zoom or cancel a newer control. UIKit teardown defers SwiftUI state changes until after the view update. It bypasses Dolly's optional physical-lens lock without changing that preference. Releasing restores the prior camera switching policy after settling; opening Dolly transfers ownership so a stale manual end cannot close the Dolly session.

## Validation

Portable project/resource/release validation passes. Changed Swift files pass tree-sitter grammar parsing; whole-repository parsing also encounters existing errors in unchanged files. XCTest coverage adds proportional travel, direction/reversal, active device bounds, invalid input and display conversion checks. Xcode compilation and XCTest require the macOS CI job. Physical camera behavior and gesture feel require an iPhone.

Device acceptance:
1. Tap every lens; verify a single preset switch and no dial flash.
2. Hold a nonselected lens; confirm the current framing does not jump.
3. Hold then drag, immediate drag, lift outside the row, cancel with app backgrounding, and flip cameras. No trailing lens tap or stuck input.
4. Scrub both directions, slow and fast, across rear boundaries and high zoom; verify real preview/export continuity. Repeat while recording, in Standard/Log and available PiP modes.
5. Confirm the last framing remains after release and dial collapse. Verify record and focus taps still work.
6. Verify narrow/landscape layouts, Reduce Motion, VoiceOver actions and front-camera bounds.
7. Open Dolly and exercise the existing A/B setup, endpoint scrub/return-to-start, Go, countdown and repeat/reverse flow. Ordinary dial must not appear in Dolly mode.
