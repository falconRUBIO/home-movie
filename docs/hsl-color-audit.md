# Selective HSL color correction

## Findings

The old positive Saturation response interpolated HSL saturation toward 1. A muted red `(0.52, 0.48, 0.48)` could become strongly red instead of receiving a proportional increase. Hue rotation kept the midpoint of the highest and lowest encoded channels fixed, which does not preserve visual brightness. Positive Lightness mixed up to 60% toward white, washing out selected colors. The kernel also operated on premultiplied RGB without accounting for alpha.

## Correction

- Keep the existing eight named bands and original-pixel, circular smooth masks. Do not cascade band selections after moving a hue.
- Rotate at most 30 degrees in either direction, then restore the pixel's original linear Rec.709 luminance.
- Scale existing linear chroma: full negative removes chroma, full positive doubles it before gamut fitting. Protect low saturation and low chroma pixels so neutral highlights and dark noise do not acquire exaggerated color.
- Adjust selected luminance by up to one stop, with a continuous highlight shoulder instead of blending toward white.
- Fit all RGB channels together along a constant-luminance chroma ray, avoiding independent channel clipping and the resulting hue shifts.
- Unpremultiply before nonlinear operations, restore alpha afterward, and return unselected pixels unchanged.
- Increment the adjustment engine cache version so previously cached exports are regenerated.

This is a photographic selective-color control, rather than a claim that HSL lightness is perceptually uniform. The compositor explicitly disables Core Image color management and supplies display-encoded Rec.709 at this finishing stage. Preview and export share `ColorInstruction.applyingColor` and `SceneAdjustments.applyingFinishing`.

Existing saved slider values are retained and use the corrected response. Previously edited scenes may therefore look different; resetting a band returns it to neutral.

## Sources

- W3C CSS Color 4, HSL conversions and limitations: https://www.w3.org/TR/css-color-4/#the-hsl-notation
- Apple, Writing Kernels, nonlinear operations and premultiplied alpha: https://developer.apple.com/library/archive/documentation/GraphicsImaging/Conceptual/ImageUnitTutorial/WritingKernels/WritingKernels.html
- Apple, Core Image working color space: https://developer.apple.com/documentation/coreimage/cicontextoption/workingcolorspace

## Verification

An isolated CPU harness compiled the actual `sceneHSL`, transfer, luminance, and gamut-fitting function bodies with C++ vector adapters. Across 55,566 RGB/control cases (21 samples per RGB channel; hue, saturation, and lightness at both endpoints), all outputs were finite and in gamut, brightness controls moved luminance in the correct direction, and the maximum hue/saturation luminance error was 2.98e-7. This verifies the numerical algorithm, not Metal compilation or iPhone appearance.

XCTest coverage exercises the production Core Image kernel: luminance preservation, muted-color saturation, neutral highlights, ordered lightness, all hue-band boundaries, unrelated extended-range pixels, alpha handling, existing serialization, and the shared finishing path. Xcode/Metal and simulator execution must run on the GitHub Mac runner; physical footage still needs visual review on iPhone.
