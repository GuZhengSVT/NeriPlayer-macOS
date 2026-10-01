#include <metal_stdlib>
using namespace metal;

struct BackgroundUniforms {
    float2 resolution;
    float animTime;
    float padding0;
    float4 bound;
    float translateY;
    float padding1[3];
    float4 points[5];
    float4 colors[5];
    float alphaMulti;
    float saturateOffset;
    float lightOffset;
    float levelEase;
    float beatEase;
    float motionEase;
    float zoom;
    float colorPulse;
    float2 globalMotion;
    float2 padding2;
};

struct VertexOut {
    float4 position [[position]];
    float2 coordinate;
};

vertex VertexOut backgroundVertex(uint vertexID [[vertex_id]]) {
    constexpr float2 positions[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
    VertexOut out;
    out.position = float4(positions[vertexID], 0, 1);
    out.coordinate = positions[vertexID] * 0.5 + 0.5;
    return out;
}

float3 rgbToHsv(float3 c) {
    float4 K = float4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
    float4 p = mix(float4(c.bg, K.wz), float4(c.gb, K.xy), step(c.b, c.g));
    float4 q = mix(float4(p.xyw, c.r), float4(c.r, p.yzx), step(p.x, c.r));
    float d = q.x - min(q.w, q.y);
    float e = 1e-10;
    return float3(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);
}

float3 hsvToRgb(float3 c) {
    constexpr float4 K = float4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
    float3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
    return c.z * mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), c.y);
}

float noise(float2 uv) { return fract(52.9829189 * fract(dot(uv, float2(0.06711056, 0.00583715)))); }

fragment float4 backgroundFragment(VertexOut in [[stage_in]], constant BackgroundUniforms &u [[buffer(0)]]) {
    float2 vUv = in.coordinate;
    vUv.y = 1.0 - vUv.y;
    float2 uv = vUv - float2(0, u.translateY);
    float2 center = float2(0.5);
    uv = (uv - center) / max(0.1, u.zoom) + center;
    float beatWave = sin((vUv.y + u.animTime * 0.12) * 6.2832) * cos((vUv.x - u.animTime * 0.10) * 6.2832);
    float radialPulse = sin((distance(vUv, center) * 5.5 - u.animTime * 0.18) * 6.2832);
    float ribbonWave = sin(((vUv.x * 1.7 + vUv.y * 2.3) - u.animTime * 0.12) * 6.2832);
    uv += u.beatEase * 0.011 * float2(beatWave, -beatWave);
    uv += u.beatEase * 0.0085 * normalize(vUv - center + float2(1e-4)) * radialPulse;
    uv += u.motionEase * 0.0062 * float2(ribbonWave, -ribbonWave * 0.75) + u.globalMotion;
    uv = (uv - u.bound.xy) / max(float2(1e-4), u.bound.zw);

    float4 colorAccum = float4(0);
    float weightSum = 0;
    for (int i = 0; i < 5; i++) {
        float4 pointColor = u.colors[i];
        pointColor.rgb *= pointColor.a;
        float2 delta = uv - u.points[i].xy;
        float radiusSq = max(u.points[i].z * u.points[i].z, 1e-4);
        float weight = 1.0 / (1.0 + dot(delta, delta) / radiusSq * 9.3);
        weight *= weight;
        colorAccum += pointColor * weight;
        weightSum += weight;
    }
    float4 color = colorAccum / max(weightSum, 1e-5);
    color.rgb /= max(color.a, 1e-5);
    float3 hsv = rgbToHsv(color.rgb);
    float pulse = u.colorPulse;
    float boostedSaturation = hsv.y * (1.16 + 0.06 * pulse) + 0.030 * pulse * u.saturateOffset;
    float limit = mix(0.66, 0.82, smoothstep(0.34, 0.74, hsv.z));
    hsv.y = clamp(min(boostedSaturation, limit), 0.0, 1.0);
    hsv.z = clamp((hsv.z - 0.5) * (1.26 + 0.06 * pulse) + 0.5 + 0.018 * pulse, 0.0, 1.0);
    color.rgb = hsvToRgb(hsv);
    color.rgb += 0.010 * pulse * u.lightOffset;
    color.rgb *= mix(0.68, 1.10, smoothstep(0.10, 0.92, vUv.y));
    color.rgb = clamp(color.rgb, 0.0, 1.0);
    color.a = clamp(color.a * u.alphaMulti, 0.0, 1.0);
    color.rgb = clamp(color.rgb + (noise(in.position.xy) - 0.5) * (5.0 / 255.0), 0.0, 1.0);
    return float4(color.rgb * color.a, color.a);
}
