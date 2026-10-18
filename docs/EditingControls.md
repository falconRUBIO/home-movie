# Editing controls

## Primary research

- [Apple Photos: light, exposure, and color](https://support.apple.com/guide/photos/adjust-light-exposure-and-color-pht806aea6a6/mac) distinguishes exposure, brightness, brilliance, contrast, black point, saturation, and vibrance. Brilliance is color neutral.
- [Apple Core Image Filter Reference](https://developer.apple.com/library/archive/documentation/GraphicsImaging/Reference/CoreImageFilterReference/index.html): exposure multiplies linear values by `2^EV`; gamma shapes midtones; vibrance protects pleasing skin tones. Working color space matters.
- [Apple Photos: levels](https://support.apple.com/guide/photos/apply-levels-adjustments-pht362f9034f/mac): black and white points establish the ends of the tonal range.
- [Tiffen diffusion guide](https://tiffen.com/pages/diffusion-guide) distinguishes highlight scattering, optical resolution, and contrast. Keep a sharp base beneath optical scattering and fine-detail reduction.

These references inform the controls' purpose. Curve coefficients and shaders are independently designed, not reproductions of Apple's proprietary algorithms or calibrated simulations of named physical filters.

## Response

| Control | Behavior |
| --- | --- |
| Exposure | ±2 stops in linear Rec.709 with a continuous positive SDR shoulder |
| Brightness | Midtone lift/darkening with black and white held stable |
| Brilliance | Opens lower tones, restrains upper tones, adds modest local detail; negative reverses the balance; no saturation adjustment |
| Shadows / Highlights | Separate monotonic toe and shoulder curves leave the opposite range untouched |
| Push/Pull | Softer print to denser contrast; a rendition effect, not physical development or sensor exposure |
| Contrast | Expands/compresses tonal separation around the middle |
| Black Point | Lifted print floor to deeper blacks |
| White Point | Lower white ceiling to brighter whites |
| Warmth / Tint | Blue–yellow and green–magenta balance, preserving luminance |
| Saturation | Monochrome at −100, neutral at zero, doubled chroma at +100 |
| Vibrance | Preferentially boosts muted colors, reducing the boost in vivid colors and warm skin hues |

Chroma is compressed toward neutral to avoid channel clipping changing hue. Highlights cannot reconstruct information already clipped during capture. Existing edits render with the revised curves; reset or compare to judge the new response. Engine versions invalidate old export caches.

All FX use zero as off and progressively increase to a strong maximum. Legacy enable flags remain readable: old disabled effects display zero and stay inactive. No enable switches. Spread, sensitivity, size, and texture remain available in disclosure rows so starting a drag does not shift the controls. Stronger glow/halation remain highlight-driven; grain remains deterministic and resolution-scaled; softness retains a sharp base. Added luminance sharpness and a soft linear-light vignette that respects content bounds. High sharpness can emphasize noise.

The shared preview/export recipe order remains look conversion → scene adjustments → optics → detail/vignette → grain. Originals remain untouched.

## Interaction and validation

The page arrangement stays the same. Light/Color rulers and native sliders show Liquid Glass only during a drag. Crossed value ticks give selection feedback, neutral gives a distinct soft impact, and a small hysteresis band catches neutral and releases in either direction. Rulers settle exactly on zero when released nearby. FX neutral is zero; grain size and zoom use 1×. Pickers/toggles provide feedback on user changes, not restored values. Accessibility adjustments remain available.

Native tests cover exposure stops/zero continuity, neutral bypass, monotonic tonal ramps, gamut bounds, warm/tint direction and luminance, monochrome saturation, vibrance, black/white points, legacy decoding and persistence, independent optical effects, deterministic grain, vignette center protection, detent hysteresis, and preview/export ordering.

Device acceptance: compare a face, foliage, a bright window, and night practical lights at 0/25/50/100; inspect moving grain at full resolution; compare preview with export; feel ticks and neutral release on iPhone; check VoiceOver. Simulator tests cannot certify physical haptics or the subjective look on real recordings.
