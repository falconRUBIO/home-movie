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
    float4 sceneLight(sample_t input, sample_t local, float exposure, float shadows, float highlights, float warmth, float tint, float brightness, float brilliance, float pushPull, float contrast, float blackPoint, float whitePoint, float saturation, float vibrance) {
        float3 rgb = clamp(input.rgb, 0.0, 1.0);
        // Exposure is ±2 stops in linear Rec.709, with a smooth SDR shoulder.
        // Do not implement EV as an additive offset in display code values.
        if (exposure != 0.0) {
            float3 linear = decode709(rgb) * exp2(exposure * 2.0);
            float peak = max(linear.r, max(linear.g, linear.b));
            float knee = 1.0 - 0.2 * (1.0 - exp2(-max(exposure, 0.0) * 2.0));
            if (peak > knee && exposure > 0.0) {
                float shoulder = knee + (1.0 - knee) * (1.0 - exp(-(peak - knee) / (1.0 - knee)));
                linear *= shoulder / peak;
            }
            rgb = encode709(linear);
        }
        float l = clamp(luminance(rgb), 0.0, 1.0);
        float target = l;
        // Independent, monotonic toe/shoulder curves; the opposite range is untouched.
        if (target < 0.55 && shadows != 0.0) {
            target = 0.55 * (1.0 - pow(1.0 - target / 0.55, exp2(shadows * 1.6)));
        }
        if (target > 0.45 && highlights != 0.0) {
            target = highlights < 0.0 ? target + highlights * 0.30 * smoothstep(0.45, 1.0, target)
                : 0.45 + 0.55 * pow((target - 0.45) / 0.55, exp2(-highlights * 1.6));
        }
        // Color-neutral brilliance opens the lower half and restrains the upper half.
        if (brilliance != 0.0) {
            float power = exp2(brilliance * 0.9);
            target = target < 0.5 ? 0.5 * (1.0 - pow(1.0 - target * 2.0, power))
                : 0.5 + 0.5 * pow(target * 2.0 - 1.0, power);
        }
        target = clamp(target + brilliance * 0.25 * (luminance(input.rgb) - luminance(local.rgb)) * 4.0 * target * (1.0 - target), 0.0, 1.0);
        // Midtone brightness protects both endpoints and stays monotonic at ±100.
        target += brightness * 0.28 * pow(sin(target * 3.14159265), 2.0);
        if (pushPull != 0.0 || contrast != 0.0) {
            float power = exp2(pushPull * 0.85 + contrast * 1.0);
            float low = pow(target, power), high = pow(1.0 - target, power);
            target = low / max(low + high, 0.00001);
            target -= pushPull * 0.12 * target * (1.0 - target);
        }
        // Positive black point deepens the floor; negative lifts it for a faded print.
        target = blackPoint >= 0.0 ? max(0.0, (target - blackPoint * 0.18) / (1.0 - blackPoint * 0.18))
            : target + (-blackPoint) * 0.18 * (1.0 - target);
        target = whitePoint >= 0.0 ? min(1.0, target / (1.0 - whitePoint * 0.22))
            : target * (1.0 + whitePoint * 0.22);
        target = clamp(target, 0.0, 1.0);
        float3 result = target >= l ? rgb + (1.0 - rgb) * ((target - l) / max(1.0 - l, 0.00001))
            : rgb * (target / max(l, 0.00001));
        if (warmth != 0.0 || tint != 0.0) {
            float3 cast = warmth * float3(0.24, 0.04, -0.28) + tint * float3(0.16, -0.20, 0.16);
            result *= exp2(cast * 2.0);
            result *= target / max(luminance(result), 0.00001);
        }
        // Vibrance gives muted colors more room and reduces boosts in orange skin hues.
        float peak = max(result.r, max(result.g, result.b));
        float floor = min(result.r, min(result.g, result.b));
        float chroma = (peak - floor) / max(peak, 0.00001);
        float skin = smoothstep(0.0, 0.12, result.r - result.g) * smoothstep(0.0, 0.12, result.g - result.b);
        float vibranceGain = vibrance >= 0.0 ? 1.0 + vibrance * 1.5 * (1.0 - chroma) * (1.0 - skin * 0.7)
            : 1.0 + vibrance * 0.9;
        float3 direction = (result - float3(target)) * (1.0 + saturation) * vibranceGain;
        // Compress chroma toward neutral rather than clipping channels and changing hue.
        float scale = 1.0;
        for (int c = 0; c < 3; ++c) {
            if (direction[c] > 0.000001) scale = min(scale, (1.0 - target) / direction[c]);
            else if (direction[c] < -0.000001) scale = min(scale, -target / direction[c]);
        }
        return float4(clamp(float3(target) + direction * clamp(scale, 0.0, 1.0), 0.0, 1.0), input.a);
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
