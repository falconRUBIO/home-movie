# Log grading and output contract

The iPhone UI stays small: Light, Color, HSL are per scene; FX is movie-wide.
Source recordings and LUT files are not rewritten when a scene is edited.

## Processing

1. Decode source samples without automatic display color conversion. For Apple
   Log, retain the captured Rec.2020/Apple Log encoding until source balance.
2. Decode the transfer function, apply the existing linear exposure and relative
   RGB white-balance gains, then re-encode for the LUT's original input.
3. Evaluate the LUT once. Saved look contracts identify Apple Log/Rec.2020 or
   Rec.709 input, with Rec.709 SDR output. Imported Rec.709 looks are composed
   after the technical Apple Log conversion at import, never normalized twice.
   Older stored looks retain their historical Log-to-display interpretation.
4. For custom LUTs with extended output values, compress the upper luminance
   shoulder smoothly and fit chroma along a constant-luminance hue ray before
   bounded display finishing. Bounded LUTs, including Cinema, are unchanged.
   This cannot recover detail already clipped by the source or the LUT itself.
5. Apply finishing Light/Color, Curves/Fade, HSL, and the movie FX recipe.
6. Render through explicitly half-float Core Image intermediates into 10-bit
   YUV compositor buffers. Preview and export use the same composition.
7. Graded Log export uses an explicit HEVC Main10 writer, Rec.709 SDR tags,
   28 Mb/s video and 192 kb/s AAC audio. The exported HEVC component depths are
   checked from the actual hvcC record; a preset name alone is not proof.
   Standard-mode exports retain their existing compatible export path.

This is a 10-bit SDR rendition, not HDR or a scene-linear wide-gamut master.
The built-in LUT already performs the Log-to-SDR rendering. Original Log files
remain available as the ungraded source. New export cache identities prevent
reuse of old 8-bit results. Export failure/cancellation removes partial output.

## White balance

Color > White Balance pauses review and lets the user tap a neutral gray patch.
A separate reader samples source pixels before the LUT, using the same spatial
transform as preview, averages a 9x9 patch in linear light, and solves the
existing Warmth/Tint gain model. Black letterboxes, dark and extreme targets are
rejected. Corrections remain reversible scene settings. This is a relative RGB
balance, not camera RAW white balance or a claim of calibrated CCT/tint. Legacy
version-1 edits keep their historical processing order and manual controls.

## Validation and remaining device checks

Native regressions cover extended-highlight separation/gamut bounds, LUT
contracts and normalization, white-balance gain inversion, a Main10 gradient
retaining more than 256 decoded luma levels, preview/export samples, output
metadata, cancellation, and the existing mixed-audio/gap/trim fixture through the
new exporter. These generated references are repeatable; they do not replace
visual assessment of real skin, skies, neon lights and mixed lighting on iPhone.

On device, check long 4K Log movies with PiP, FX and audio, cancellation, thermal
pressure, Photos playback and sharing. Compare stills from preview and export
with the same display settings. Codec precision does not promise lossless output.

## Primary references

- Apple, custom compositor source/output precision and color properties:
  https://developer.apple.com/videos/play/wwdc2020/10009/
- Apple, explicit AVAssetWriter profile/format control:
  https://developer.apple.com/videos/play/wwdc2020/10010/
- Apple, Core Image working color-space behavior:
  https://developer.apple.com/documentation/coreimage/cicontextoption/workingcolorspace
- Apple, camera LUT versus creative LUT ordering:
  https://support.apple.com/guide/final-cut-pro/ver24f966423/mac
- ARRI, look files and creative versus display transforms:
  https://www.arri.com/en/learn/camera-systems/image-science/look-files
