# Landscape camera and flip audit

Reference: user-provided screenshots IMG_5913 (MOVIE ROLL) and IMG_5915 (Apple Camera). The app fitted a 16:9 preview inside safe-area height and a 112-point review rail. This produced visible top/bottom margins and an overly wide right region. Apple's screenshot fills the usable landscape height, retaining the leading notch area and a compact trailing control rail.

## Layout

Landscape now extends to the top, bottom and home-button-side edge while retaining the hardware-cutout safe area. The rail and Record placement mirror in the opposite landscape orientation, using the actual UIWindowScene orientation rather than a camera sensor angle. Ordinary preview fills the remaining viewport beside one 96-point rail; it is not fitted inside another letterboxed rectangle. Explicit PiP movie canvases still fit their selected aspect. Portrait behavior retains its footer/aspect layout.

The landscape rail places Flip at top, a compact Watch Movie/play control and runtime in the center, and recent-clip review at bottom. Saved/Undo feedback sits above the thumbnail. The Record control remains over the right edge of the live view. Camera-preview identity is stable across layout/orientation updates.

## Flip

- `CameraModel.busy` includes camera switching. Using it to apply `takeFormat` also applied a previous recording's stale portrait lock during an idle landscape flip. Only starting/recording/finalizing states now own the take orientation. A flip separately holds the current interface format.
- Lock the current landscape side rather than allowing an unintended 180-degree turn. Compatible locks do not request a new geometry transition. Unlocking a take or page retains the existing auto-rotation request; idle flips never apply the previous take’s portrait mask.
- Ignore stale PiP presentation opacity when the ordinary camera is active; clear it when preparing/receiving ordinary-camera readiness. An actual PiP composition or dual-camera fade still blocks a conflicting flip. UI and model share one availability predicate; switching shows feedback immediately.
- The capture handoff waits for correctly oriented source pixel geometry before releasing replacement frames. This handles landscape rear pixels and portrait-native front sensors separately rather than assuming a source angle equals interface orientation. The outgoing preview stays visible during the handoff, including a delayed orientation update. Input, microphone and writer continuity remain on the existing paths.
- Dual-camera flip availability now reflects whether both cameras are actually ready.

## Validation

Added tests for full-height landscape geometry, one trailing rail, portrait/PiP aspect preservation, front/rear source rotation matching, stale take-orientation exclusion, both landscape-side locks, stale PiP flip availability and recording flip capability. Local Swift grammar/project/resource checks and Python release checks run before publication. Xcode and XCTest run in macOS CI. Physical front/rear handoff, both landscape directions and saved recording orientation still require iPhone acceptance.

Device pass: rotate both ways before and during capture; repeatedly flip while idle and while recording; return from Watch Movie; toggle PiP then return to ordinary capture; confirm no portrait UI flash, no black frame, preserved audio/timer, matching saved landscape playback, working focus/zoom/dolly/record and reachable Watch/thumbnail/flip controls.
