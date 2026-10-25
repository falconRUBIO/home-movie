# Lighting grading refinement

## Reference and intended behavior

Blackmagic Design's Colorist Guide and HDR palette documentation provide the reference principles: work in a known color space, express exposure in stops, separate global contrast from tonal zones, preserve color relationships, and keep the signal pipeline explicit. Resolve has several distinct grading palettes; these principles guide this app's simplified controls rather than reproducing proprietary Resolve algorithms.

Sources:

- Blackmagic Design, The Colorist Guide to DaVinci Resolve 20: https://documents.blackmagicdesign.com/UserManuals/DaVinci-Resolve-20-Colorist-Guide.pdf
- Blackmagic Design, Color / HDR grading and tonal ranges: https://www.blackmagicdesign.com/products/davinciresolve/color
- ITU-R BT.2020-2, Table 4: continuous transfer-function join and scene-linear BT.2020 luminance coefficients: https://www.itu.int/dms_pubrec/itu-r/rec/bt/R-REC-BT.2020-2-201510-I!!PDF-E.pdf
- ITU-R BT.709-6, camera transfer and Rec.709 colorimetry: https://www.itu.int/dms_pubrec/itu-r/rec/bt/R-REC-BT.709-6-201506-I!!PDF-E.pdf

## Findings

Exposure and white balance already operated on decoded source light, but Shadows, Highlights and Contrast were applied after the look. A look that had already flattened bright values could therefore prevent these controls from using the source's remaining highlight separation. Contrast in the display fallback pivoted at code value 0.5 instead of scene-linear middle gray.

Display brightening and curves mixed RGB toward white, reducing saturation even with the color controls unchanged. Positive Black Point and White Point clipped ranges of shadow and highlight values. Push/Pull's subtractive density offset could flatten the deepest shadows. Brilliance added neighborhood contrast using a blurred image, potentially producing halos.

The old rounded transfer constants also produced a small discontinuity at the toe/power join. A dense finishing ramp reproduced a brightness reversal of approximately 0.0002. Using a continuous internal transfer removes that reversal.

## Modern production processing

1. Decode Apple Log into scene-linear BT.2020 RGB, or Standard into linear Rec.709 RGB.
2. Apply white balance and global exposure (+/-2 stops).
3. Apply contrast in log-luminance around 18% scene-linear gray. Apply shadow/highlight exposure zones using smooth, four-stop falloffs and up to +/-2 stops of selective adjustment. Their slopes stay positive at full strength. Use one RGB gain to preserve channel ratios.
4. Re-encode into the look's original input transfer. Apple Log headroom is retained before the LUT. Standard receives one shared peak shoulder when the primary grade exceeds SDR headroom.
5. Apply the selected look / Log-to-display conversion.
6. Apply display finishing: Brilliance, midtone Brightness, rendition-level Push/Pull, Black Point, White Point, curves and Fade. Preserve linear RGB ratios where the destination gamut permits; fit chroma as one vector when needed. No spatial blur is used for Brilliance.
7. Apply the shared HSL finishing stage and film effects.

The source primary controls are cleared from the finishing copy so they are never applied twice. Preview and export use the same `ColorInstruction.applyingColor` pipeline. The standalone `SceneAdjustments.apply` display path remains for historical rendering and compatibility; production grading must use the ordered source/finishing methods.

The internal Rec.709-family grading transfer uses the precise smooth-join alpha/beta documented by ITU. It keeps the existing Rec.709 primaries and output tags; it does not turn Standard media into BT.2020 or change Apple Log's transfer function. The tiny difference from rounded video-transfer constants is below a 10-bit code step. Shader arithmetic uses floats; existing half-float Core Image intermediate buffers and 10-bit export remain in place to avoid an unprofiled memory increase.

## Controls, saved edits and limits

Exposure now displays +/-2.00 EV and announces stops to VoiceOver for modern recipes. Existing normalized slider values, zero detents, haptics and glass controls remain. Core light controls are ordered Exposure, Contrast, Highlights, Shadows, Black Point, White Point, Brightness and Brilliance; creative density/fade/curves remain under Advanced.

Modern version-2 recipes retain their values and use the refined renderer; their appearance may change. Historical version-1 primary/tonal processing remains on its compatibility path. No source recording or LUT data is rewritten. The adjustment cache version is bumped so old rendered exports are regenerated.

Lowering highlights can reveal separation still present in the recorded Log signal before a display look clips it. It cannot reconstruct sensor detail already clipped during recording. This remains an SDR delivery pipeline, not Resolve Color Management, RAW development, or HDR mastering.

## Verification

An isolated C++ harness compiled the actual shader function bodies with CPU vector adapters. 462,934 source/finishing cases passed finite-value, monotonicity, middle-gray anchoring, SDR gamut, and linear RGB-ratio checks. The separate HSL harness passed 55,566 cases after the transfer refinement.

Production Core Image XCTest regressions cover source gray anchoring, retained Log headroom, Log channel ratios and alpha, all zone-boundary combinations, highlight recovery before a bounded LUT, source controls applied once, curve/brightness color stability, shadow/highlight endpoint separation, no neighborhood-dependent Brilliance, and the former transfer-join reversal. Existing persistence, legacy rendering and preview/export tests remain.

Portable source/project, release tests and whitespace checks run locally. Xcode/Metal compilation and iPhone simulator tests run in GitHub CI. Physical iPhone footage has not been visually compared against Resolve.
