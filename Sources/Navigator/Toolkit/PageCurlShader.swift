//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import Foundation

/// Cylinder curl, compiled at runtime with `makeLibrary(source:)`.
/// A `.metal` resource would need a `Package.swift` change; this string does not.
///
/// The shader has no duration and no easing. `progress` is already the visual
/// position, 0 = outgoing flat, 1 = incoming flat. `radius` is zero at both
/// ends. Task 4 sets `tilt` from the finger; a tap leaves it at 0.
enum PageCurlShader {
    static let source = #"""
    #include <metal_stdlib>
    using namespace metal;

    struct CurlUniforms {
        float progress;
        float spineX;
        float peelSign;
        float radius;
        float tilt;
        float span;
        float realVerso;
        float specular;
        float paperR;
        float paperG;
        float paperB;
        float paperMix;
        float aspect;
        float twoPage;
        float pad0;
        float pad1;
    };

    struct CurlVertexOut {
        float4 position [[position]];
        float2 uv;
    };

    vertex CurlVertexOut curlVertex(uint vid [[vertex_id]]) {
        float2 pos[3] = {
            float2(-1.0, -1.0),
            float2( 3.0, -1.0),
            float2(-1.0,  3.0)
        };
        CurlVertexOut out;
        out.position = float4(pos[vid], 0.0, 1.0);
        // Texture origin is top-left. Clip y is up.
        out.uv = float2((pos[vid].x + 1.0) * 0.5, (1.0 - pos[vid].y) * 0.5);
        return out;
    }

    constexpr sampler curlSampler(filter::linear, address::clamp_to_edge);

    static float3 sampleTex(texture2d<float> tex, float2 uv) {
        return tex.sample(curlSampler, clamp(uv, float2(0.0), float2(1.0))).rgb;
    }

    static float2 leafUV(float leaf, float y, constant CurlUniforms &u) {
        float x = u.spineX + u.peelSign * leaf;
        return float2(clamp(x, 0.0, 1.0), clamp(y, 0.0, 1.0));
    }

    static float3 paperBack(float3 src, constant CurlUniforms &u) {
        float3 paper = float3(u.paperR, u.paperG, u.paperB);
        return mix(src, paper, clamp(u.paperMix, 0.0, 1.0));
    }

    fragment float4 curlFragment(
        CurlVertexOut in [[stage_in]],
        texture2d<float> outgoing [[texture(0)]],
        texture2d<float> incoming [[texture(1)]],
        constant CurlUniforms &u [[buffer(0)]]
    ) {
        float2 uv = in.uv;
        float3 outC = sampleTex(outgoing, uv);
        if (u.progress <= 0.001) {
            return float4(outC, 1.0);
        }
        if (u.progress >= 0.999) {
            return float4(sampleTex(incoming, uv), 1.0);
        }
        if (u.radius < 1.0e-4) {
            float3 flat = u.progress > 0.5 ? sampleTex(incoming, uv) : outC;
            return float4(flat, 1.0);
        }

        float aspect = max(u.aspect, 0.05);
        float dx = uv.x - u.spineX;
        float dy = (uv.y - 0.5) / aspect;
        float ct = cos(-u.tilt);
        float st = sin(-u.tilt);
        float rotatedX = dx * ct - dy * st;
        float leafX = rotatedX * u.peelSign;

        float span = max(u.span, 0.05);
        float R = max(u.radius, 1.0e-4);
        float PI = 3.14159265;
        // Peel travel is linear in progress. Radius only fattens the roll,
        // so the ridge can close at the ends without the peel jumping back.
        float travel = u.twoPage > 0.5 ? (span * 2.0) : (span + 0.36);
        float pulled = u.progress * travel;
        float lift = span - pulled;

        float3 inC = sampleTex(incoming, uv);
        float envelope = sin(clamp(u.progress, 0.0, 1.0) * PI);

        // Free-edge side of the peel: the page underneath.
        if (leafX > lift) {
            float dist = leafX - lift;
            float shadow = exp(-dist / max(R * 2.2, 0.015)) * 0.50 * envelope;
            return float4(clamp(inC * (1.0 - shadow), 0.0, 1.0), 1.0);
        }

        float arc = PI * R;
        float flatLen = max(pulled - arc, 0.0);
        float backTangent = lift - 2.0 * R;
        float backTip = backTangent - flatLen;

        // On the cylinder, between the peel and the back tangent.
        if (leafX >= backTangent) {
            float local = lift - leafX;
            float cosTheta = clamp(1.0 - local / R, -1.0, 1.0);
            float theta = acos(cosTheta);
            float orig = lift + theta * R;
            float ridge = sin(theta);
            float spec = pow(max(ridge, 0.0), 16.0) * u.specular * envelope;
            float3 specColor = spec * float3(1.0, 0.98, 0.94);

            if (theta <= PI * 0.5) {
                float3 front = sampleTex(outgoing, leafUV(orig, uv.y, u));
                float shade = 0.58 + 0.42 * ridge;
                return float4(clamp(front * shade + specColor, 0.0, 1.0), 1.0);
            }

            float3 back;
            if (u.realVerso > 0.5) {
                // The printed verso, right-reading, symmetric across the spine.
                back = sampleTex(incoming, leafUV(-orig, uv.y, u));
            } else {
                float mirrored = span - orig;
                back = paperBack(sampleTex(outgoing, leafUV(mirrored, uv.y, u)), u);
            }
            float shade = 0.70 + 0.22 * ridge;
            return float4(clamp(back * shade + specColor * 0.35, 0.0, 1.0), 1.0);
        }

        // Flat underside that has already folded past the cylinder.
        if (leafX >= backTip) {
            float s = arc + (backTangent - leafX);
            float orig = lift + s;
            float3 back;
            if (u.realVerso > 0.5) {
                back = sampleTex(incoming, leafUV(-orig, uv.y, u));
            } else {
                float mirrored = span - orig;
                back = paperBack(sampleTex(outgoing, leafUV(mirrored, uv.y, u)), u);
            }
            float shade = 0.86;
            float spineAO = u.twoPage > 0.5
                ? exp(-abs(leafX) / 0.045) * 0.16 * envelope
                : 0.0;
            return float4(clamp(back * shade * (1.0 - spineAO), 0.0, 1.0), 1.0);
        }

        // Still-flat outgoing, with the curl's shadow and a spine crease.
        float gap = backTip - leafX;
        float shadow = exp(-max(gap, 0.0) / max(R * 3.0, 0.02)) * 0.32 * envelope;
        float spineAO = u.twoPage > 0.5
            ? exp(-abs(leafX) / 0.045) * 0.18 * envelope
            : exp(-max(leafX, 0.0) / 0.08) * 0.06 * envelope;
        return float4(clamp(outC * (1.0 - shadow - spineAO), 0.0, 1.0), 1.0);
    }
    """#
}
