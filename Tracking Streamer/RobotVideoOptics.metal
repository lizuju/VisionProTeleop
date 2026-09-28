#include <metal_stdlib>
using namespace metal;

struct R1OpticsParameters {
    float4x4 inverseRectification;
    float4 intrinsics;
    float4 distortion;
    float4 imageAndFocal;
};

vertex float4 r1OpticsVertex(uint index [[vertex_id]]) {
    const float2 vertices[] = {float2(-1, -1), float2(3, -1), float2(-1, 3)};
    return float4(vertices[index], 0, 1);
}

fragment float4 r1OpticsFragment(float4 position [[position]],
                                texture2d<float> image [[texture(0)]],
                                constant R1OpticsParameters &p [[buffer(0)]]) {
    float width = p.imageAndFocal.x;
    float height = p.imageAndFocal.y;
    float focal = p.imageAndFocal.z;
    float2 pixel = position.xy - 0.5f;
    float2 principal = (float2(width, height) - 1.0f) * 0.5f;
    float3 ray = (p.inverseRectification * float4((pixel - principal) / focal, 1, 0)).xyz;
    if (ray.z <= 0) return float4(0, 0, 0, 1);
    float2 normalized = ray.xy / ray.z;
    float radius = length(normalized);
    float theta = atan(radius);
    float theta2 = theta * theta;
    float thetaDistorted = theta * (1 + theta2 * (p.distortion.x + theta2 *
        (p.distortion.y + theta2 * (p.distortion.z + theta2 * p.distortion.w))));
    float scale = radius > 1e-8f ? thetaDistorted / radius : 1;
    float2 source = p.intrinsics.xy * normalized * scale + p.intrinsics.zw;
    if (any(source < 0) || source.x > width - 1 || source.y > height - 1) return float4(0, 0, 0, 1);
    // CI's preceding vertical transform makes Metal rows match OpenCV's top-left origin.
    float2 uv = float2(source.x + 0.5f + p.imageAndFocal.w * width, source.y + 0.5f)
        / float2(width * 2, height);
    constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    return float4(image.sample(linearSampler, uv).rgb, 1);
}
