# Editing correctness audit

This audits the implemented controls, not a certification that their artistic
response matches Apple's or Resolve's proprietary grading algorithms. Automated
fixtures establish specific properties; real footage remains necessary to judge
skin, mixed illumination, noise, halos, texture, banding and excessive settings.
The interface stays small. Light/Color/HSL are per scene, FX are movie-wide.

## Findings and corrections

- Standard white balance previously applied linear RGB gains without the exposure
  shoulder when Exposure was zero. Bright channels could exceed SDR and later
  clip independently. Balance now shares a peak-based, ratio-preserving shoulder
  with positive exposure. Its knee approaches white as control values approach
  zero. Below the knee, existing gains remain unchanged. Log balance is unchanged.
- Luminance sharpening can produce out-of-range edge excursions. A new smooth
  limiter bounds the enhancement vector against available headroom rather than
  allowing later per-channel clipping. Flat pixels stay unchanged; enhancement
  direction stays consistent. This reduces overshoot, not a promise of zero halos.
- Engine cache versions advance so earlier rendered exports are not reused.
  Saved slider values and recipe ordering remain unchanged.

## Control review

| Controls | Defined behavior and evidence | Limits |
| --- | --- | --- |
| Exposure | Linear gain before LUT for version 2; stop response and LUT input encoding tested | Cannot recover clipped capture/LUT data; version 1 keeps historical order |
| Warmth, Tint, White Balance picker | Relative source RGB gains before LUT; gray-patch solver, neutral continuity, bright-channel ratios tested | Not RAW/CCT calibration; one global balance cannot correct mixed lighting |
| Shadows, Highlights | Smooth bounded tonal masks; monotonic ramps, endpoint behavior, join continuity tested | Rendition shaping after LUT, not sensor highlight reconstruction |
| Brilliance, Brightness | Tonal/local contrast balance versus midtone brightness; independent responses tested | Brilliance is spatial; aggressive settings can emphasize edges/noise |
| Contrast, Push/Pull | Monotone density/S-curves; independent responses and combined ramp order tested | Creative contrast choices; overlapping purpose is kept under Advanced |
| Black Point, White Point | Toe/shoulder controls, bounded output; ramp and endpoint tests | Positive endpoints deliberately sacrifice some detail |
| Curves, Fade | Monotone cubic anchors and output pedestal; graph/render agreement tested | Fade intentionally lifts blacks; curves are luminance finishing, not RGB channel curves |
| Saturation, Vibrance | Chroma fitting with gray protection; luminance/gamut tests; broad warm-hue protection for vibrance | Warm-hue protection is not face/skin detection |
| HSL | Eight smooth, original-hue masks; wrap, selected color and gray-protection tests | Conventional HSL lightness, not perceptually uniform luminance grading |
| Glow, Halation | Thresholded diffusion in linearized SDR; independent amount, spectral and dark-area tests | Artistic rendition effects after LUT, not measured film-stock scattering |
| Optical Softness | Linear-light detail diffusion; neutral and detail-response tests | Does not detect/preserve faces specifically |
| Highlight Roll-Off | Smooth peak-based shoulder, RGB ratios retained | Cannot recover clipped information |
| Sharpness | Luminance detail enhancement followed by smooth vector limiter; bounds, flats, neutral/color direction tests | Can still emphasize noise; excessive sharpening remains a subjective choice |
| Vignette | Position-relative linear-light darkening, independent of output orientation | Creative effect; no lens-specific optical calibration |
| Grain | Deterministic timestamp/seed and resolution-scaled particles, applied last; temporal/neutral tests | Artistic texture, not a calibrated emulsion or a denoiser |

## Pipeline and export verification

See [Log-Grading.md](Log-Grading.md) for the explicit LUT contracts, source
balance order, half-float intermediates, actual HEVC Main10/Rec.709 verification,
preview/export gradient parity and audio/cancellation checks. Standard retains
its existing compatible export encoder; graded Log uses the Main10 path.

## Remaining visual validation

Use actual iPhone Log clips of skin/gray cards, backlit interiors, skies, neon,
low light and fine texture. Compare paused preview and exported frames at the
same time, frame size and display settings. Check moderate settings before
extremes, moving grain/halos as well as stills, and long export/thermal behavior.
Do not describe the whole editor as fully visually validated from synthetic
fixtures alone. No additional desktop-style controls are needed for this audit.

## Primary research

- Apple Color Adjustments: control roles and selecting the correct color space:
  https://support.apple.com/guide/final-cut-pro/ver21fdaa1d9/mac
- Apple working space/gamut contract for video effects:
  https://developer.apple.com/documentation/professional-video-applications/managing-color-space-and-gamut-in-plug-ins
- ARRI Textures: grain, detail contrast and perceived sharpness are related;
  ARRI's camera texture stage is distinct from these post-LUT artistic FX:
  https://www.arri.com/en/learn/camera-systems/image-science/arri-textures
