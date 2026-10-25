# Movie editing pipeline

## Processing order

New recipes (pipeline version 3) use ordered, non-destructive stages:

1. Decode Apple Log to linear BT.2020, or Standard's video transfer curve to linear Rec.709.
2. Apply Exposure as linear gain (the slider spans -2 to +2 stops) and relative Warmth/Tint balance. Balance gains are normalized with the source gamut's luminance coefficients.
3. Re-encode to the **same source encoding**. The existing Cinema and Apple Standard LUTs expect Apple Log, not linear RGB. There is no second Log-to-display conversion in front of these LUTs.
4. Apply the selected Log-input LUT, when the scene is Log. Standard recordings skip this node.
5. Apply display finishing: Shadows/Highlights, Brilliance, Brightness, Push/Pull, Contrast, Black Point, White Point, Vibrance, then Saturation.
6. Apply Curves/Fade, then selective HSL, followed by the saved film FX and output rendering.

Exposure and balance before the look let the LUT respond to corrected source values. This can retain source detail that a bright look would otherwise map out of range. It cannot recover information already clipped during capture. Values stay floating point through source balance; an inactive balance node is an exact bypass. Warmth/Tint are relative color-balance controls, not RAW white-balance reconstruction or calibrated Kelvin values.

Contrast and Black Point here are **finishing controls** on the visible image. Running these in the source's Log code values would give different responses for Standard and Log and would depend heavily on the selected LUT. This is a deliberate fixed node order, not an editable Resolve node graph or an ACES implementation. Highlight and shadow sliders remain display trims; they do not claim sensor highlight recovery.

## Control behavior

| Control | Response |
| --- | --- |
| Contrast | A symmetric perceptual S-curve anchored at middle gray, with smooth shoulders and stable black/white endpoints. Operates on luminance rather than independent RGB curves. |
| Black Point | Positive values deepen the toe and can set the darkest values to black. Negative values raise the black pedestal for a faded rendition. A cubic toe reduces influence on brighter tones and leaves white fixed. |
| White Point | Positive values brighten the shoulder toward white; negative values lower the white ceiling. A mirrored cubic shoulder leaves black fixed. |
| Saturation | Constant-luminance chroma scaling. -100 is monochrome, 0 is neutral, +100 doubles chroma where gamut allows. Runs after Vibrance so -100 remains monochrome at every Vibrance setting. |
| Vibrance | Adjusts quieter colors more than already saturated colors, with reduced positive adjustment in broad warm hues. It is not face/skin detection. Neutrals remain neutral. |

Chroma expansion compresses along a constant-luminance hue direction into the display gamut instead of clipping each channel independently. Controls remain bounded and neutral at zero. The shared ruler provides integer steps, a zero detent, tick feedback, and a glass surface during interaction. Physical haptic feel and appearance require an iPhone check.

Version 3 reconstructs primary tonal changes with a shared RGB gain, preserving
channel ratios while the result fits in gamut. At the gamut boundary, chroma is
reduced at constant display luma. Unlike the version-2 white blend, a lift does
not automatically dilute skin or colored surfaces even when headroom is available.
This is display-referred density preservation, not scene-linear highlight recovery.

## Persistence and compatibility

New recipes use stronger monotonic Shadows/Highlights, midtone Brightness, and a color-neutral Brilliance curve with modest local detail. Standard positive exposure has a continuous SDR shoulder; Log balance preserves headroom for the LUT.

All values and the pipeline version are saved with the scene. Versionless recipes with any nonzero adjustment retain pipeline 1, the former all-after-LUT rendering, so already-saved edits do not change appearance. Saved version-2 recipes retain their prior tonal rendering. Versionless neutral recipes adopt version 3 without changing the rendered image; the editor also adopts version 3 for explicitly versioned but unedited clips. The five new controls default to zero for old catalogs. Resetting a tab affects only that tab's controls. Source recordings and LUT tables are never rewritten.

The adjustment engine cache version is incremented. Watch Movie, scene preview, thumbnails, single-scene export, and movie export use `ColorInstruction.applyingColor`; Original bypasses the recipe. Tests cover JSON compatibility, saved/reopened scenes, display behavior, gamut, source-before-LUT order, legacy order, matching rendered preview/export frames, and full exports with the combined recipe.

## Research basis

- [ACES AMF implementation guide](https://docs.acescentral.com/amf/guides/implementation/), Working Location: distinguishes scene-linear corrections such as exposure from creative look/output transforms. This informs the separation above; the app itself does not implement ACES.
- [Apple Log color space](https://developer.apple.com/documentation/avfoundation/avcapturecolorspace/applelog): Apple Log uses BT.2020 primaries and Apple's Log transfer curve.
- [Colour's Apple Log transfer-function reference implementation](https://colour.readthedocs.io/en/latest/_modules/colour/models/rgb/transfer_functions/apple_log_profile.html): equations/constants and 18% gray reference, citing Apple's white paper and vendor-supplied ACES input transform. The shader implements those transfer equations; it does not copy an ACES gamut conversion.
- [Apple Photos Light/Color controls](https://support.apple.com/guide/photos/adjust-light-exposure-and-color-pht806aea6a6/mac): separate Contrast/Black Point and Saturation/Vibrance controls.
- [Apple Core Image filter reference](https://developer.apple.com/library/archive/documentation/GraphicsImaging/Reference/CoreImageFilterReference/index.html), CIVibrance/CIColorCube: useful behavior and working-color-space guidance. The app uses its shared deterministic shader rather than mixing filters with implicit color-management assumptions.

The exact slider strengths, toe curve, and vibrance protection are product choices tested for direction, stability, and parity; they are not a claim to reproduce proprietary Apple or Resolve algorithms.
