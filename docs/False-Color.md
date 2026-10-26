# False Color exposure preview

Open **Look & Preview → Viewfinder → False Color**, or choose it under
**Movie Settings → Viewfinder**, when recording Apple Log. With Look, Log and
False Color are mutually exclusive preview choices. Existing preference keys are
preserved; an older configuration with both preview switches enabled resolves to
False Color until a new choice is made. Standard movies ignore these Log preview
preferences. Preview choices may change during recording without reconfiguring capture.

The small on-screen False Color button is a static key, not a live chart. It shows
all six colors, including purple, pink and red, and opens a full guide when tapped.
The guide is also available beside the Viewfinder picker. Green is explicitly
labeled 18% middle gray; unmarked exposure ranges remain grayscale. The key's RGB
values and the shader's thresholds/colors come from the same `FalseColorZone`
definitions, so the legend cannot silently omit or substitute a different color.
Movie Look is separate: it controls playback/export and With Look preview.
Import Look opens a secondary screen for choosing Apple Log or Rec.709 LUT input.

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


## Design references

Apple's Final Cut Camera documents false color as a monitoring overlay and shows
a full reference scale, including purple/blue, green/pink, and warm highlight
colors: https://support.apple.com/guide/final-cut-camera/use-video-scopes-and-overlays-deva751720e2/ios

ARRI's published specification distinguishes common color categories from
camera-, encoding-, range- and EI-dependent thresholds:
https://www.arri.com/resource/blob/390448/2d469ae1e98110562fe347cea50a284b/arri-logc-false-color-specification-data.pdf

These references inform the complete, readable key and monitoring-only behavior.
The app retains its stated Apple Log relative-stop ranges rather than applying
another camera's sensor noise/clipping calibration or presenting an IRE scale
that does not describe this mapping. A screenshot alone cannot establish whether
a mostly purple image reflects actual exposure or a capture/metadata problem;
verified Log source-frame testing remains required.
