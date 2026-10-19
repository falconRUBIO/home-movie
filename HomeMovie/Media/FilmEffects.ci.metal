#include <CoreImage/CoreImage.h>
using namespace metal;

// Original optical shaders and a separate per-scene light-adjustment stage.
float3 decode709(float3 c) {
    c = max(c, 0.0);
    return select(pow((c + 0.099) / 1.099, float3(1.0 / 0.45)), c / 4.5, c < 0.081);
}
float3 encode709(float3 c) {
    c = max(c, 0.0);
    return select(1.099 * pow(c, float3(0.45)) - 0.099, c * 4.5, c < 0.018);
}
float luminance(float3 c) { return dot(c, float3(0.2126, 0.7152, 0.0722)); }
// Apple Log transfer function, from Apple's vendor-supplied ACES input transform.
// Keep negative toe values and highlight headroom until the look is evaluated.
float decodeAppleLog(float x) {
    const float r0 = -0.05641088, rt = 0.01, c = 47.28711236;
    const float beta = 0.00964052, gamma = 0.08550479, delta = 0.69336945;
    const float join = c * (rt - r0) * (rt - r0);
    if (x >= join) { return exp2((x - delta) / gamma) - beta; }
    return x >= 0.0 ? sqrt(x / c) + r0 : r0;
}
float encodeAppleLog(float x) {
    const float r0 = -0.05641088, rt = 0.01, c = 47.28711236;
    if (x >= rt) { return 0.08550479 * log2(x + 0.00964052) + 0.69336945; }
    return x >= r0 ? c * (x - r0) * (x - r0) : 0.0;
}
// Compress along a constant-luminance hue ray, rather than clipping channels.
float3 fitChroma(float3 rgb, float level, float gain) {
    float3 direction = (rgb - float3(level)) * gain;
    float scale = 1.0;
    for (int c = 0; c < 3; ++c) {
        if (direction[c] > 0.000001) { scale = min(scale, (1.0 - level) / direction[c]); }
        else if (direction[c] < -0.000001) { scale = min(scale, -level / direction[c]); }
    }
    return clamp(float3(level) + direction * clamp(scale, 0.0, 1.0), 0.0, 1.0);
}
uint mixBits(uint x) {
    x ^= x >> 16; x *= 0x7feb352du; x ^= x >> 15; x *= 0x846ca68bu; return x ^ (x >> 16);
}
float randomValue(int2 cell, uint seed, uint salt) {
    uint h = mixBits(uint(cell.x) * 0x9e3779b9u ^ uint(cell.y) * 0x85ebca6bu ^ seed ^ salt);
    return float(h >> 8) * (1.0 / 16777216.0);
}
// Jittered, rotated elliptical particles with random radii and signed density.
// Pixel-footprint filtering suppresses aliasing as grain becomes subpixel-sized.
float particles(float2 p, float size, uint seed, uint salt) {
    float spacing = max(size * 2.5, 0.6);
    int2 base = int2(floor(p / spacing));
    float sum = 0.0;
    for (int y = -1; y <= 1; ++y) {
        for (int x = -1; x <= 1; ++x) {
            int2 cell = base + int2(x, y);
            float2 center = (float2(cell) + float2(randomValue(cell, seed, salt), randomValue(cell, seed, salt + 1))) * spacing;
            float theta = randomValue(cell, seed, salt + 2) * 6.2831853;
            float2 q = p - center;
            q = float2(q.x * cos(theta) - q.y * sin(theta), q.x * sin(theta) + q.y * cos(theta));
            float r = size * (0.3 + 0.45 * randomValue(cell, seed, salt + 3));
            float2 variance = float2(r * r, r * r * 0.65);
            float2 filtered = variance + 0.0833333;
            float amplitude = sqrt((variance.x * variance.y) / (filtered.x * filtered.y));
            float density = (randomValue(cell, seed, salt + 4) - 0.5) * 2.0;
            sum += exp(-0.5 * dot(q * q, 1.0 / filtered)) * amplitude * density;
        }
    }
    return sum;
}

extern "C" { namespace coreimage {
    float4 sceneTone(sample_t input, float4 levels, float4 slopes, float lastSlope, float fade) {
        float3 rgb = clamp(input.rgb, 0.0, 1.0);
        float l = clamp(luminance(rgb), 0.0, 1.0);
        int i = min(3, int(l * 4.0));
        float t = l * 4.0 - float(i), t2 = t * t, t3 = t2 * t;
        float nextLevel = i == 3 ? 1.0 : levels[i + 1];
        float nextSlope = i == 3 ? lastSlope : slopes[i + 1];
        float target = (2.0 * t3 - 3.0 * t2 + 1.0) * levels[i]
            + (t3 - 2.0 * t2 + t) * slopes[i] * 0.25
            + (-2.0 * t3 + 3.0 * t2) * nextLevel + (t3 - t2) * nextSlope * 0.25;
        // Fade is an output pedestal, unlike Black Point's shadow threshold.
        // White stays fixed; adjacent tones keep their ordering and headroom.
        target = mix(clamp(target, 0.0, 1.0), 1.0, fade * 0.22);
        float3 result = target >= l ? rgb + (1.0 - rgb) * ((target - l) / max(1.0 - l, 0.000001))
            : rgb * (target / max(l, 0.000001));
        return float4(result, input.a);
    }
    float4 sceneHSL(sample_t input, float4 red, float4 orange, float4 yellow,
                    float4 green, float4 aqua, float4 blue, float4 purple, float4 magenta) {
        float3 rgb = clamp(input.rgb, 0.0, 1.0);
        float hi = max(rgb.r, max(rgb.g, rgb.b)), lo = min(rgb.r, min(rgb.g, rgb.b));
        float chroma = hi - lo;
        // Achromatic pixels have no meaningful hue. Avoid coloring gray noise.
        if (chroma < 0.00001) return input;
        float light = (hi + lo) * 0.5;
        float sat = chroma / max(1.0 - abs(2.0 * light - 1.0), 0.00001);
        float hue = hi == rgb.r ? (rgb.g - rgb.b) / chroma :
                    (hi == rgb.g ? (rgb.b - rgb.r) / chroma + 2.0 : (rgb.r - rgb.g) / chroma + 4.0);
        hue = fract(hue / 6.0 + 1.0);
        float4 bands[8] = {red, orange, yellow, green, aqua, blue, purple, magenta};
        float3 adjustment = float3(0.0); float total = 0.0;
        // All masks use the original hue, wrap across red, and have smooth edges.
        for (int i = 0; i < 8; ++i) {
            float delta = fract(hue - bands[i].w + 1.5) - 0.5;
            float previous = bands[(i + 7) % 8].w;
            float next = bands[(i + 1) % 8].w;
            float reach = delta < 0.0 ? fract(bands[i].w - previous + 1.0) : fract(next - bands[i].w + 1.0);
            float weight = 1.0 - smoothstep(0.0, reach, abs(delta));
            adjustment += bands[i].xyz * weight; total += weight;
        }
        adjustment /= max(total, 0.00001);
        float protection = smoothstep(0.0, 0.08, chroma);
        hue = fract(hue + adjustment.x * protection / 6.0 + 1.0);
        sat = adjustment.y < 0.0 ? sat * (1.0 + adjustment.y * protection) :
              sat + (1.0 - sat) * adjustment.y * protection;
        light = adjustment.z < 0.0 ? light * (1.0 + adjustment.z * protection * 0.6) :
                light + (1.0 - light) * adjustment.z * protection * 0.6;
        float c = (1.0 - abs(2.0 * light - 1.0)) * sat;
        float3 wave = clamp(abs(fract(hue + float3(0.0, 2.0/3.0, 1.0/3.0)) * 6.0 - 3.0) - 1.0, 0.0, 1.0);
        return float4((wave - 0.5) * c + light, input.a);
    }

    // Only extended-output custom LUTs use this display rendering transform.
    // Compress the luminance shoulder, then fit chroma along a constant-hue ray.
    // Bounded LUTs remain numerically unchanged, including the bundled Cinema look.
    float4 lookDisplay(sample_t input) {
        float l = max(luminance(input.rgb), 0.0);
        float target = l > 0.85 ? 0.85 + 0.15 * (1.0 - exp(-(l - 0.85) / 0.15)) : l;
        float3 rgb = l > 0.000001 ? input.rgb * (target / l) : float3(0.0);
        return float4(fitChroma(rgb, target, 1.0), input.a);
    }

    float4 neutralSource(sample_t input, float logEncoded) {
        float3 rgb = logEncoded > 0.5 ? float3(decodeAppleLog(input.r), decodeAppleLog(input.g), decodeAppleLog(input.b)) : decode709(input.rgb);
        return float4(rgb, input.a);
    }
    float4 sceneBalance(sample_t input, float exposure, float warmth, float tint, float logEncoded) {
        float3 rgb;
        if (logEncoded > 0.5) {
            rgb = float3(decodeAppleLog(input.r), decodeAppleLog(input.g), decodeAppleLog(input.b));
        } else { rgb = decode709(input.rgb); }
        // ±2 stops of actual linear gain. Warmth/tint are relative RGB balance,
        // not a claim to reconstruct the camera's measured white balance.
        float3 cast = warmth * float3(0.22, 0.025, -0.245) + tint * float3(0.13, -0.16, 0.13);
        float3 gains = exp2(cast * 2.0);
        float3 weights = logEncoded > 0.5 ? float3(0.2627, 0.6780, 0.0593) : float3(0.2126, 0.7152, 0.0722);
        gains /= dot(gains, weights); // Neutral brightness remains stable as color is balanced.
        rgb *= gains * exp2(exposure * 2.0);
        if (logEncoded > 0.5) {
            rgb = float3(encodeAppleLog(rgb.r), encodeAppleLog(rgb.g), encodeAppleLog(rgb.b));
        } else {
            // Standard is display-referred. Exposure AND RGB balance can exceed
            // SDR headroom. Compress the peak with one shared gain so channel
            // ratios survive; the knee converges to white as controls approach zero.
            float peak = max(rgb.r, max(rgb.g, rgb.b));
            float strength = max(max(exposure, 0.0), max(abs(warmth), abs(tint)));
            float knee = 1.0 - 0.2 * (1.0 - exp2(-strength * 2.0));
            if (peak > knee && strength > 0.0) {
                float shoulder = knee + (1.0 - knee) * (1.0 - exp(-(peak - knee) / (1.0 - knee)));
                rgb = (rgb / peak) * shoulder;
            }
            rgb = encode709(rgb);
        }
        return float4(rgb, input.a);
    }
    float4 sceneLight(sample_t input, sample_t local, float exposure, float shadows, float highlights, float warmth, float tint, float brightness, float brilliance, float pushPull,
                      float contrast, float blackPoint, float whitePoint, float saturation, float vibrance, float pipelineVersion) {
        float3 rgb = clamp(input.rgb, 0.0, 1.0);
        // Display-only entry points can still use the new exposure response.
        // Production version-2 recipes apply Exposure in sceneBalance and pass zero here.
        if (pipelineVersion >= 2.0 && exposure != 0.0) {
            float3 linear = decode709(rgb) * exp2(exposure * 2.0);
            float peak = max(linear.r, max(linear.g, linear.b));
            float knee = 1.0 - 0.2 * (1.0 - exp2(-max(exposure, 0.0) * 2.0));
            if (peak > knee && exposure > 0.0) {
                float shoulder = knee + (1.0 - knee) * (1.0 - exp(-(peak - knee) / (1.0 - knee)));
                linear = (linear / peak) * shoulder;
            }
            rgb = encode709(linear);
        }
        float l = clamp(luminance(rgb), 0.0, 1.0);
        float target = l;
        if (pipelineVersion >= 2.0) {
            // Monotonic tonal curves with continuous slopes at their joins.
            if (target < 0.55 && shadows != 0.0) {
                float x = target / 0.55;
                float strength = shadows >= 0.0 ? shadows * 2.4 : shadows * 0.9;
                target = 0.55 * (x + strength * x * (1.0 - x) * (1.0 - x));
            }
            if (target > 0.45 && highlights != 0.0) {
                float x = (target - 0.45) / 0.55;
                target = highlights < 0.0 ? target + highlights * 0.30 * smoothstep(0.45, 1.0, target)
                    : 0.45 + 0.55 * (x + highlights * 0.9 * x * x * (1.0 - x));
            }
            if (brilliance != 0.0) {
                float strength = brilliance >= 0.0 ? brilliance * 1.5 : brilliance * 0.8;
                if (target < 0.5) {
                    float x = target * 2.0;
                    target = 0.5 * (x + strength * x * (1.0 - x) * (1.0 - x));
                } else {
                    float x = target * 2.0 - 1.0;
                    target = 0.5 + 0.5 * (x - strength * x * x * (1.0 - x));
                }
            }
            target = clamp(target + brilliance * 0.25 * (luminance(input.rgb) - luminance(local.rgb)) * 4.0 * target * (1.0 - target), 0.0, 1.0);
            target += brightness * 0.28 * pow(sin(target * 3.14159265), 2.0);
        } else {
        // Preserve the historical rendition for already-saved version-1 recipes.
        // Gentle luminance-only changes. Smooth tonal masks avoid hard thresholds;
        // endpoint headroom keeps whites and blacks stable and limits hue shifts.
        float shadowMask = 1.0 - smoothstep(0.15, 0.55, l);
        float highlightMask = smoothstep(0.45, 0.85, l);
        float delta = l * (1.0 - l) * (exposure * 0.3 + shadows * shadowMask * 0.4 + highlights * highlightMask * 0.4);
        target = clamp(l + delta, 0.0, 1.0);
        // Brilliance opens darker tones while holding bright tones; negative reverses it.
        target += brilliance * 0.9 * target * (1.0 - target) * (0.65 - target);
        // Brightness favors midtones, unlike the broader exposure adjustment above.
        float middle = 1.0 - (2.0 * target - 1.0) * (2.0 * target - 1.0);
        target += brightness * 0.65 * target * (1.0 - target) * middle;
        }
        if (pushPull != 0.0) {
            // A rendition-level density/contrast curve, not a sensor exposure change.
            float power = exp2(pushPull * (pipelineVersion >= 2.0 ? 0.85 : 0.65));
            float low = pow(target, power);
            float high = pow(1.0 - target, power);
            target = low / max(low + high, 0.00001);
            target -= pushPull * (pipelineVersion >= 2.0 ? 0.12 : 0.08) * target * (1.0 - target);
        }
        if (contrast != 0.0) {
            // Symmetric perceptual S-curve around middle gray. Smooth shoulders,
            // exact endpoints, and no RGB-channel contrast that would shift hues.
            float power = exp2(contrast * 1.5);
            float low = pow(target, power), high = pow(1.0 - target, power);
            target = low / max(low + high, 0.00001);
        }
        if (blackPoint != 0.0) {
            // Positive sets a deeper black threshold; negative lifts the pedestal.
            // The cubic toe falls away rapidly, leaving white unchanged.
            target = max(0.0, target - blackPoint * 0.12 * pow(1.0 - target, 3.0));
        }
        // A mirrored shoulder controls the white ceiling while preserving black.
        if (whitePoint != 0.0) { target = min(1.0, target + whitePoint * 0.22 * pow(target, 3.0)); }
        target = clamp(target, 0.0, 1.0);
        float3 result;
        if (target >= l) {
            result = rgb + (1.0 - rgb) * ((target - l) / max(1.0 - l, 0.000000000001));
        } else {
            result = rgb * (target / max(l, 0.000000000001));
        }
        if (warmth != 0.0 || tint != 0.0) {
            // Independent rendition-level color balance: +warmth yellow, +tint magenta.
            // Preserve luminance and compress chroma into gamut, avoiding channel clipping.
            float3 cast = warmth * float3(0.12, 0.02, -0.14) + tint * float3(0.08, -0.10, 0.08);
            float3 balanced = result * exp2(cast * 2.0);
            balanced *= target / max(luminance(balanced), 0.00001);
            float3 direction = balanced - float3(target);
            float scale = 1.0;
            for (int c = 0; c < 3; ++c) {
                if (direction[c] > 0.000001) { scale = min(scale, (1.0 - target) / direction[c]); }
                else if (direction[c] < -0.000001) { scale = min(scale, -target / direction[c]); }
            }
            result = clamp(float3(target) + direction * clamp(scale, 0.0, 1.0), 0.0, 1.0);
        }
        if (vibrance != 0.0) {
            float peak = max(result.r, max(result.g, result.b));
            float floor = min(result.r, min(result.g, result.b));
            float chroma = peak - floor;
            float colorfulness = chroma / max(peak, 0.00001);
            float muted = 1.0 - smoothstep(0.05, 0.9, colorfulness);
            // Broad warm-hue protection, not face detection. Saturated colors
            // receive less boost; neutrals have no chroma to amplify.
            float warmRatio = (result.r - result.g) / max(chroma, 0.00001);
            float warm = smoothstep(0.1, 0.35, warmRatio) * (1.0 - smoothstep(0.65, 0.9, warmRatio));
            warm *= (result.r >= result.g && result.g >= result.b) ? 1.0 : 0.0;
            float strength = vibrance > 0.0 ? 1.5 : 0.8;
            float gain = 1.0 + vibrance * strength * muted * (1.0 - 0.65 * warm);
            result = fitChroma(result, target, max(gain, 0.0));
        }
        if (saturation != 0.0) {
            // -100 is genuinely monochrome even when Vibrance is also active.
            float gain = saturation < 0.0 ? 1.0 + saturation : exp2(saturation);
            result = fitChroma(result, target, gain);
        }
        return float4(result, input.a);
    }
    float4 filmLinear(sample_t input) { return float4(decode709(input.rgb), input.a); }
    float4 filmHighlights(sample_t input, float threshold, float warm) {
        float t = decode709(float3(threshold)).x;
        float l = luminance(input.rgb);
        // A saturated neon source can be bright in one channel but have low luma.
        float peak = max(input.r, max(input.g, input.b));
        float sourceEnergy = max(l, peak * 0.8);
        float gate = smoothstep(t, min(1.0, t + 0.18), sourceEnergy);
        // Warm-rich sources scatter more red than equally bright saturated blue sources.
        float spectral = mix(1.0, clamp(input.r / max(l, 0.001), 0.15, 1.0), warm);
        return float4(input.rgb * gate * spectral, 1.0);
    }
    float4 filmOptics(sample_t base, sample_t bloom, sample_t red, sample_t orange, float bloomAmount, float halationAmount) {
        float l = luminance(base.rgb);
        float sourceProtection = 1.0 - smoothstep(0.65, 0.995, l);
        float localContrast = smoothstep(0.001, 0.035, max(luminance(red.rgb) - l * 0.18, 0.0));
        float3 halo = float3(luminance(red.rgb), luminance(orange.rgb) * 0.32, luminance(orange.rgb) * 0.025);
        float3 energy = bloom.rgb * bloomAmount * 2.8 + halo * halationAmount * 4.0 * sourceProtection * localContrast;
        // Channel-relative headroom protection, no whole-frame tone or saturation changes.
        float3 result = base.rgb + max(1.0 - base.rgb, 0.0) * (1.0 - exp(-energy));
        return float4(encode709(result), base.a);
    }
    float4 filmSoftness(sample_t base, sample_t soft, float amount) {
        float l = luminance(base.rgb);
        // Retain a sharp base and avoid turning dark scenes into a milky wash.
        float blend = amount * (0.55 + 0.35 * smoothstep(0.08, 0.75, l));
        return float4(encode709(mix(base.rgb, soft.rgb, blend)), base.a);
    }
    float4 filmDetail(sample_t base, sample_t sharp) {
        // A luminance sharpen can create negative/over-white edge excursions.
        // Bound the enhancement vector smoothly, rather than clipping each
        // channel independently or changing unsharpened pixels elsewhere.
        float3 rgb = clamp(base.rgb, 0.0, 1.0);
        float3 delta = sharp.rgb - rgb;
        float ratio = 0.0;
        for (int c = 0; c < 3; ++c) {
            float room = delta[c] >= 0.0 ? 1.0 - rgb[c] : rgb[c];
            ratio = max(ratio, abs(delta[c]) / max(room, 0.000001));
        }
        float gain = ratio > 0.0001 ? (1.0 - exp(-ratio)) / ratio : 1.0 - ratio * 0.5;
        return float4(clamp(rgb + delta * gain, 0.0, 1.0), base.a);
    }
    float4 filmRolloff(sample_t input, float amount) {
        float3 rgb = decode709(input.rgb);
        float peak = max(rgb.r, max(rgb.g, rgb.b));
        // A smooth shoulder with unit slope at its join. Channel ratios stay intact.
        // This is rendition shaping; it cannot recover clipped sensor information.
        const float knee = 0.35;
        float above = max(peak - knee, 0.0);
        float shoulder = knee + above / (1.0 + above * 1.8 * amount);
        float gain = peak > knee ? shoulder / max(peak, 0.00001) : 1.0;
        return float4(encode709(rgb * gain), input.a);
    }
    float4 filmVignette(sample_t input, float amount, float4 bounds, destination dest) {
        float2 p = (dest.coord() - bounds.xy) / max(bounds.zw, float2(1.0));
        float distance = length((p - 0.5) * 1.41421356);
        float edge = smoothstep(0.25, 1.0, distance);
        return float4(encode709(decode709(input.rgb) * exp2(-amount * 2.5 * edge)), input.a);
    }
    float4 filmGrain(sample_t input, float amount, float size, float seedLow, float seedHigh, float4 bounds, destination dest) {
        float2 p = dest.coord();
        if (p.x < bounds.x || p.y < bounds.y || p.x >= bounds.x + bounds.z || p.y >= bounds.y + bounds.w) return input;
        uint seed = uint(seedLow) | (uint(seedHigh) << 16);
        float fine = particles(p - bounds.xy, size, seed, 17u);
        float cluster = particles(p - bounds.xy + float2(13.7, 29.1), size * 1.8, seed, 103u);
        float coarse = particles(p - bounds.xy + float2(41.3, 7.9), size * 3.1, seed, 271u);
        float l = clamp(luminance(input.rgb), 0.0, 1.0);
        float response = 0.25 + 0.75 * pow(max(4.0 * l * (1.0 - l), 0.0), 0.65);
        float g = (fine * 0.65 + cluster * 0.25 + coarse * 0.10) * amount * 0.38 * response;
        // Mostly luminance grain: preserve hue and underlying detail, limit endpoint bias.
        // Scale toward black or white instead of suppressing all grain whenever
        // a single channel is saturated. Neutral patches remain neutral.
        float3 rgb = clamp(input.rgb, 0.0, 1.0);
        float3 result = g >= 0.0 ? rgb + (1.0 - rgb) * g * 2.0 : rgb + rgb * g * 2.0;
        return float4(result, input.a);
    }
}}
