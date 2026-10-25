# Grading and reliability pass — 25 October 2026

## Lighting and HSL

Exposure remains a ±2-stop scene-linear gain before the Log-to-display look.
White balance remains before that look, in its original input encoding. Brightness,
shadows, highlights, contrast, endpoints and HSL are display finishing controls.
These are original controls, not a reproduction of Resolve's proprietary algorithms.

New version-3 recipes raise display tones with shared RGB gain, then reduce chroma
only as needed to fit the display gamut. This avoids mixing every lifted color
toward white. Saved version-1 and version-2 recipes keep their historical rendering.
Black/White Point remain separate endpoint trims; a lifted black pedestal does not
multiply near-black chroma noise. Exact neutrals bypass color reconstruction to
retain monotonic tonal steps at half-float precision.
Unedited clips adopt version 3 on entering the editor; opening alone is not an edit.
The export cache engine version increases to prevent reuse of obsolete renders.

HSL's original-pixel hue masks, normalized overlap, relative chroma, near-neutral
protection and linear-luminance preservation remain intact. Additional regressions
cover warm adjacent bands and extreme combined lighting/HSL on skin-like, muted,
near-white, near-black and saturated RGB patches. No extra HSL transformation is
introduced before the look or in the export-only path.

## Recording and editor

Flip readiness now requires recent frames from both cameras. A frame seen at setup
does not establish readiness indefinitely. Recording preview uses the same locked
per-camera source angle as the writer in both single- and dual-camera pipelines.
The existing continuous microphone and fixed recording canvas remain in place.

Done and Cancel can cancel a pending white-balance sample. A canceled or obsolete
sample cannot apply a late result, clear a newer request or report a stale error.
Actual save/export/Photos operations still prevent conflicting commits. Existing
clip deletion continues to replace the editing session inside its enclosing sheet,
including the empty state after the last clip.

## Export

The Main10 exporter drains each media sample inside an autorelease pool, checks
reader failure/cancellation at EOF, rejects invalid duration and unexpected writer
termination, and reports bounded finite progress. Audio and video still drain
independently. Regression coverage exports grain + halation + bloom with lighting
and HSL twice and compares the encoded result with the preview composition.

## Validation boundary

Portable checks cover Swift grammar, project/resources, release metadata and the
release-check tests. The GitHub iPhone simulator workflow compiles Swift/Metal and
runs XCTest. Its result must be checked for the final commit; portable checks alone
do not establish GPU or AVFoundation correctness.

Physical iPhone acceptance remains necessary: Standard and Log; PiP off/on;
portrait and both landscape sides; repeated front/rear flips; clip deletion and
Done after sampling; a long movie with grain, halation and bloom; cancellation,
thermal pressure, and Photos save. Simulator fixtures do not establish long-take
memory stability or real camera behavior.

## Reference contracts

- [Blackmagic Design color tools](https://www.blackmagicdesign.com/products/davinciresolve/color)
- [Apple capture rotation](https://developer.apple.com/documentation/avfoundation/avcaptureconnection/videorotationangle)
- [Apple reader status at EOF](https://developer.apple.com/documentation/avfoundation/avassetreader/status-swift.property/)

