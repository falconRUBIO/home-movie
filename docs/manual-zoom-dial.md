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

## Revised interaction after hardware feedback

The initial implementation depended on a SwiftUI overlay inside ViewThatFits/ScrollView. Hardware feedback reported that it appeared only after release, missed the first drag, occupied an awkward offset position, and required too much horizontal travel. Those symptoms are addressed structurally rather than by extending the overlay animation.

- One persistent UIKit view owns both recognition and rendering. Pan-began synchronously reveals the wheel before any camera callback. No SwiftUI insertion or layout change is needed for the first frame.
- Ordinary controls use a single layout, outside the scrolling/ViewThatFits fallback used by Dolly. The native wheel fills a fixed 104-point control area, centered across the whole control row. Its crescent replaces the floating rounded card. Collapsed transparent space remains available to viewfinder focus.
- Quick lens taps retain preset behavior. A 0.2-second hold opens the wheel at the existing framing. A pan opens it on the first recognized movement. Lens views stay attached throughout the touch; only their CALayer opacity changes.
- Travel is proportional and compact: 48 points doubles zoom, compared with the previous 120. A 1× to 8× move takes 144 points rather than 360. During touch, the scale draws directly from the requested framing so slower measured camera updates cannot hold the wheel back.
- Higher magnifications sit to the right of the fixed index. Dragging left moves those marks under the index and zooms in; dragging right zooms out. The wheel’s tick spacing uses the same travel constant as the gesture model, so visual motion agrees with finger motion.
- Clamp incremental travel at actual device limits and rebase there. Reversing at a limit responds immediately, even after a large overscroll.
- Lens markings give light, rate-limited haptics. Release settles at the requested framing and the scale closes after 1.1 seconds. No snap back to the touched lens or to a Dolly start point.
- Keep the separate Dolly and PiP buttons reachable. Token-based ownership rejects stale input after a new control or Dolly takes over. Cancellation removes the wheel synchronously and defers SwiftUI teardown notifications.
- VoiceOver zoom actions remain available. The reveal has no motion animation and does not depend on animation accessibility settings.

These travel, hold, drawing and dismissal constants are our tuning. Apple documents the tap/hold/drag interaction but does not publish Camera’s exact implementation or constants.

## Validation

Added native UIView regression coverage for first-pan visibility before release or camera publication, live scale updates while dragging, camera-update isolation, centered placement at narrow/regular widths, stable lens geometry, preview/action hit testing, hold-without-zoom, cancellation and disabled input. Added compact-travel and immediate boundary-reversal coverage. Existing manual session ownership and range/display tests remain.

Dolly setup, endpoint preview/return-to-start, countdown and playback implementations are compared against main and remain unchanged. Source/project checks run locally. Xcode compilation and XCTest run in macOS CI; actual touch feel and physical lens transitions still need an iPhone check.
