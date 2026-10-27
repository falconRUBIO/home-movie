# Film FX audit — 25 October 2026

## Scope and processing contract

These are original, film-inspired finishing effects, not calibrated scans of a
particular emulsion or copies of proprietary Resolve/Dehancer algorithms. There
is no single numerical industry standard for a halation or grain plugin.

The existing color contract remains: source balance, Log-to-Rec.709 look where
applicable, display corrections, then FX. Optical scattering and softness decode
that rendition to linear Rec.709 before processing. This is display-referred
finishing, not a scene-referred spectral film simulation. Do not reinterpret Log
code values as linear light or normalize the Log source twice.

Halation and glow sample the same original rendition in parallel. Softness follows
the optical combination, then highlight roll-off, bounded sharpening, vignette and
grain. Grain is last so blur and sharpening do not inadvertently alter its texture.
The renderer and recipe resolution are shared by clip review, Watch Movie and export.

## Findings and corrections

| Effect | Audit result |
| --- | --- |
| Halation | Retain broader red scattering and a tighter orange component, highlight sensitivity, and bright-source protection. Subtract the local highlighted source from each diffused component before adding the halo. This isolates local spill and prevents a uniform bright wall from acquiring a red overlay. |
| Glow/Bloom | Retain source-colored highlight extraction and bounded, linear-light addition. Insert an intermediate after native-resolution highlight extraction, then explicitly request high-quality downsampling. Averaging must not erase a tiny lamp before nonlinear highlight selection. Clamp incoming bloom energy nonnegative to prevent resampling undershoot from becoming a dark ring. |
| Fine 35mm grain | Keep the existing procedural particle mixture and mid-gray strength. Replace asymmetric black/white blending with symmetric luminance perturbation and joint chroma fitting. This corrects unintended average shadow lift and highlight darkening; black/white remain stable. Handle premultiplied alpha consistently with Coarse 16mm. |
| Coarse 16mm grain | Retain its independently seeded, rotated particle layers, tone-dependent response, stable endpoints and existing alpha handling. It is a coarser texture, not a calibrated film-stock profile. |
| Optical Softness | Retain linear-light diffusion blended with the sharp base; flat fields remain unchanged. This is separate from highlight glow. |
| Highlight Roll-Off | Retain the monotonic shoulder, stable shadows and shared RGB gain. It shapes rendered highlights and cannot restore clipped source detail. Correct the UI description to match compression rather than implying whitening. |
| Sharpness | Retain bounded luminance enhancement before grain. Existing checks cover high-contrast edges, flat areas and enhancement-vector color preservation. |
| Vignette | Retain progressive linear-light edge attenuation with center protection, defined relative to the actual content rectangle. This is a finishing vignette, not a calibrated lens profile. |

FX engine version increases from 6 to 8, invalidating cached exports. Saved slider
values and movie/clip FX scope stay intact; existing enabled effects render with
the corrected engine. Fine-grain texture in shadows/highlights and local halation
can therefore differ from an older export.

## Verification

An independent C++ harness compiled the actual transfer, particle, grain and optics
function bodies using vector adapters. At maximum Fine 35mm amount and 2x size on
256x256 patches, averaged over three timeline seeds:

| Input gray | Previous mean | Corrected mean |
| --- | --- | --- |
| 0.15 | 0.16349708 | 0.14995256 |
| 0.85 | 0.83618665 | 0.84995258 |

Corrected black and white were exact. Across 100,000 sampled optics combinations,
outputs remained finite and bounded, and equal local/diffused highlight fields
produced zero added halation in that harness. This checks numerical behavior, not
GPU compilation, Core Image resampling or iPhone appearance.

New production-kernel XCTest coverage checks fine-grain patch means and endpoints,
both grain textures with premultiplied alpha, uniform bright fields with halation,
and a one-pixel light at all sixteen phases of the quarter-resolution diffusion
grid. The initial GPU run found that a downsampling quality flag alone still lost
the tiny source; an explicit highlight intermediate enforces extraction before
reduction and respects the compositor's disabled intermediate cache across frames.
Existing coverage includes moving/repeatable grain, warm halos versus neutral
glow, saturated neon, softness, roll-off, vignette, sharpness, saved settings,
clip/movie FX scope, and preview/export parity with combined FX. The full iPhone
simulator workflow must pass on the final code commit.

Real footage on iPhone 17 remains the visual/performance acceptance step: skin and
bright walls, windows, night lamps/neon, fine texture, gradients, both orientations,
and long Log movies with grain, halation and glow combined. CPU and simulator checks
do not establish physical-device memory, heat or sustained export performance.

## Reference basis

- [Dehancer Halation](https://www.dehancer.com/learn/article/halation): local red-orange halos, source/background controls and differing diffusion scales.
- [Dehancer Bloom](https://www.dehancer.com/learn/article/bloom): source-colored highlight diffusion, separate from general softness, with highlight protection.
- [Dehancer Film Grain](https://www.dehancer.com/learn/article/grain): size, tonal distribution, image/texture interaction and format-dependent profiles.
- [Dehancer separate-node workflow](https://www.dehancer.com/learn/article/davinci-resolve-node-sequence): interpreting Log before separate Rec.709 bloom/halation and combining optical branches in parallel.
- [Apple high-quality downsampling](https://developer.apple.com/documentation/coreimage/cicontextoption/highqualitydownsample): multipass antialiasing and platform-dependent defaults.
- [Apple explicit transform quality](https://developer.apple.com/documentation/coreimage/ciimage/transformed(by:highqualitydownsample:)): selecting downsampling quality at the image transform.
- [Apple image intermediate](https://developer.apple.com/documentation/coreimage/ciimage/insertingintermediate(cache:)): an explicit processing boundary with cache control.


## Grain refinement (engine 9)

Both existing 35mm-inspired and 16mm-inspired textures now use a shared response.
The original deterministic particle fields, timeline seeds, size controls, and
format-dependent strength remain. Two particle differences add a restrained color
component, projected to zero Rec.709 luminance. Symmetric per-channel headroom
limits color variation near gamut boundaries without an asymmetric clipping bias.
A small Gaussian neighborhood measures image detail and reduces added grain by at
most 35% on strong detail. The sharp base image is never replaced by that sample.
Grain remains the last stage, shared by preview and export; engine-version cache
invalidation ensures existing previews regenerate. No additional user controls or
film-stock accuracy claims are introduced.

Added native checks cover channel means, restrained chroma versus luminance energy,
amount scaling, finite bounded output, fine-detail protection without blurred black
stripes, plus existing alpha, animation, endpoints, and combined-effect regressions.
Physical iPhone texture, export performance, and final encoded-video review remain
necessary; these automated checks cannot establish aesthetic film-stock fidelity.

## Local glow refinement (engine 10)

Glow now adds the positive difference between diffused highlights and the native
local highlight mask, independently per color channel. Previously it added the
entire blurred mask, including each pixel's own highlight energy. That lifted
uniform bright surfaces and compressed their detail even without nearby lights.
The refinement preserves flat bright fields and the interior of broad lights,
while retaining source-colored spill around lamps and windows. It is a localized
display-referred finishing effect, not an energy-conserving optical simulation.

The existing native-resolution extraction intermediate is reused: no new blur or
particle passes, settings, presets, motion, or exposure fluctuations are added.
Grain, halation, softness, and the shared preview/export path remain intact.
Engine 10 invalidates cached exports so existing enabled Glow settings receive
the refinement. Saved slider values retain their meaning, but broad highlights
can look less washed out than in older renders.

New production-kernel tests cover bright neutral, warm skin-colored and saturated
flat fields at both spread extremes, bright-source interior detail and colored
spill. Existing tiny-light sampling-phase, amount-response, grain, combined FX,
and preview/export checks must also pass. Device appearance and long-export heat
and memory behavior still require iPhone footage testing.
