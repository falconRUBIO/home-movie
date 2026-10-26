# PiP settings toggle audit

The settings switch exposed two independent problems:

- CameraModel treated an identical preparation request as complete even when the
  live PiP state had changed since that request. On → Off → On could therefore
  skip re-enabling the inset.
- The settings renderer and metering presentation always described PiP as on,
  so turning it off did not remove the presenter from the settings preview.

Ready sessions now reconcile their actual state rather than returning from the
configuration cache. Settings sends explicit On/Off targets and reuses an already
prepared dual-camera session. A pending target keeps the switch, layout controls
and dismissal busy until a matching camera publication arrives. Stale publications
cannot acknowledge the opposite target; failure, interruption and suspension
clear pending work. The switch displays the requested target while the preview
continues to display the confirmed state.

Settings rendering and metering share an enabled-aware presentation. Off shows
only the rear view for all layouts, including swapped splits; both feeds remain
warm until the sheet closes. Closing while Off restores ordinary capture. No
encoder, frame routing, audio or recording timeline changes were made.

Regression coverage exercises Standard and Apple Log On/Off/On against the real
CameraModel reuse path with a command spy, delayed acknowledgements, duplicate
input, failure recovery, recording-state preservation, and rendered pixels in
inset and both split orders. These tests do not validate physical camera startup
or timing. On-device acceptance still needs repeated toggles, dismissal/reopen,
front/rear readiness and Standard/Log recording checks.

## Native quick menu

The camera button now opens one native Menu with an inline, checkmarked Picker:
Off, Inset, Top & Bottom, Side by Side. Its icon follows the confirmed active
layout. Re-selecting a layout leaves it unchanged. Split layouts expose a
separate Swap Cameras action. PiP Settings opens the existing live sheet for
size, position and orientation; it is unavailable during a take.

Prepared dual-camera takes may switch layouts/swap without changing their
writer, canvas, orientation or audio. Stop Recording remains available during
PiP acknowledgement. Quick Off while idle restores ordinary capture; Off inside
settings keeps the live feeds warm until dismissal. Cameras are not newly
configured during an active take.

The existing saved-movie/export regression now changes from inset to both split
layouts and swaps each during one audio/video take, then checks exported pixels
and continuous audio. Native menu structure follows Apple's Menu guidance and
SwiftUI's inline Picker pattern:
https://developer.apple.com/design/human-interface-guidelines/menus
https://developer.apple.com/documentation/swiftui/populating-swiftui-menus-with-adaptive-controls
