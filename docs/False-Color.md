# False Color exposure preview

Enable **False Color** in the camera menu or **Movie Settings → Live Preview**
when recording Apple Log. It defaults off and remembers the preference. Standard
movies ignore that preference. Turning it off restores the Cinema/Original Log
selection. It may be toggled during recording without reconfiguring capture.

The map decodes verified Apple Log RGB to scene-linear values and computes
BT.2020 luminance (0.2627 R + 0.6780 G + 0.0593 B). Exposure is
`log2(max(luminance, 1e-8) / 0.18)`. Core Image handles native YCbCr pixel range
conversion; the preview disables further color management before classification.

| Color | Stops relative to 18% gray |
| --- | --- |
| Purple | Below −6 |
| Blue | −6 to below −4 |
| Green | −0.15 to +0.15 |
| Pink | +0.85 to +1.15 |
| Orange | +3 to below +4 |
| Red | +4 and above |
| Grayscale | All remaining values |

These are fixed **relative exposure bands**, not measured iPhone sensor clipping
or noise-floor thresholds. Red must not be presented as proof of irrecoverable
highlights, nor purple as proof of lost shadow detail. A saturated individual
color channel can clip without bright luminance. This feature does not claim to
detect that. The map does not automatically adjust exposure.

## Isolation and failure behavior

- The monitoring renderers bypass the viewing LUT while the map is active.
- PiP maps each visible, verified Log source before spatial composition/fades.
- Original CVPixelBuffers are read only. The writer, export, grading, and
  thumbnail paths do not call FalseColorPreview.
- Preview uses the existing bounded latest-frame rendering loop. It does not
  queue additional capture frames or restart the camera/audio session.
- Untagged/non-Log frames and kernel failures fail explicitly. CameraView turns
  the tool off and shows a notice so a failed map is not mistaken for a valid one.
- Focus, exposure, pinch, and PiP touch routing remain on their existing surfaces.

## Validation

XCTest exercises GPU color output for full- and video-range 10-bit neutral
patches, LUT bypass/restoration, invalid tags, invisible PiP feeds, both split
orders, insets, source-buffer preservation, and the clean writer compositor.
Existing PiP geometry and recording tests cover the shared spatial path.

Before claiming device-calibrated clipping detection, measure gray-card and
exposure-ramp recordings for each supported camera/format/ISO combination. Test
bright windows, faces, saturated colored lights, low-light noise, front/rear
handoffs, orientation changes, and continuous PiP/dolly recording. Compare saved
clips with monitoring on/off and measure preview latency/thermal behavior.
Simulator checks cannot establish sensor limits or real-device performance.
