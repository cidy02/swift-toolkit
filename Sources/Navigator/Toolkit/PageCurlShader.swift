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
/// ends. The fold is the perpendicular bisector of `p0`→`p` (see
/// `PageCurlGeometry.spreadSample`, which this fragment matches). The back of
/// the leaf is opaque. The next page is drawn only where the leaf does not cover it.
enum PageCurlShader {
    private static let backFoldShade = String(format: "%.4f", PageCurlGeometry.backFoldShade)
    private static let backShadeBand = String(format: "%.4f", PageCurlGeometry.backShadeBand)

    static let source = #"""
    #include <metal_stdlib>
    using namespace metal;

    struct CurlUniforms {
        float progress;
        float spineX;
        float peelSign;
        float radius;
        float p0x;
        float p0y;
        float px;
        float py;
        float span;
        float realVerso;
        float specular;
        float paperR;
        float paperG;
        float paperB;
        float paperMix;
        float aspect;
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

    static float3 paperBack(float3 src, constant CurlUniforms &u) {
        float3 paper = float3(u.paperR, u.paperG, u.paperB);
        return mix(src, paper, clamp(u.paperMix, 0.0, 1.0));
    }

    static float2 paperUV(float2 paper, float aspect) {
        return float2(clamp(paper.x, 0.0, 1.0), clamp(paper.y * aspect, 0.0, 1.0));
    }

    // Keep this in lockstep with PageCurlGeometry.spreadSample. s > 0 is the
    // finger's side of the bisector. The flap is the reflection of the peeled
    // leaf and is drawn opaque. The next page is only the uncovered part.
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
        // A vanishing cylinder is a hard crease across the page. Stay flat.
        if (u.radius < 0.004) {
            float3 flat = u.progress > 0.5 ? sampleTex(incoming, uv) : outC;
            return float4(flat, 1.0);
        }

        float aspect = max(u.aspect, 0.05);
        float pageH = 1.0 / aspect;
        float span = max(u.span, 0.05);
        float sign = u.peelSign >= 0.0 ? 1.0 : -1.0;
        float2 iso = float2(uv.x, uv.y / aspect);
        float2 p0 = float2(u.p0x, u.p0y);
        float2 finger = float2(u.px, u.py);
        float2 delta = finger - p0;
        float len = length(delta);
        float envelope = sin(clamp(u.progress, 0.0, 1.0) * 3.14159265);
        if (len <= 0.0008) {
            float3 flat = u.progress > 0.5 ? sampleTex(incoming, uv) : outC;
            return float4(flat, 1.0);
        }

        float2 N = delta / len;
        float2 M = (p0 + finger) * 0.5;
        float sTop = dot(float2(u.spineX, 0.0) - M, N);
        float sBot = dot(float2(u.spineX, pageH) - M, N);
        float minS = min(sTop, sBot);
        if (minS < 0.0) {
            M += N * minS;
        }

        float R = max(u.radius, 0.0);
        float s = dot(iso - M, N);
        float2 pre = iso - N * (2.0 * s);

        bool peeled = false;
        {
            float along = (pre.x - u.spineX) * sign;
            bool insideX = along >= -0.004 && along <= span + 0.004;
            bool insideY = pre.y >= -0.004 && pre.y <= pageH + 0.004;
            peeled = insideX && insideY;
        }

        // Back of the leaf. Opaque: one page is a paper ghost of the mirrored
        // front, two pages are the incoming facing half. Darker only near the fold.
        // A soft highlight sits on the cylinder axis (the bisector, offset by R).
        if (s > 0.0 && peeled) {
            float3 back;
            if (u.realVerso > 0.5) {
                float along = (pre.x - u.spineX) * sign;
                float far = max(1.0 - span, 0.0);
                float versoAlong = -along * (far / span);
                float versoX = u.spineX + sign * versoAlong;
                back = sampleTex(incoming, float2(versoX, clamp(pre.y * aspect, 0.0, 1.0)));
            } else {
                back = paperBack(sampleTex(outgoing, paperUV(pre, aspect)), u);
            }
            // Paper everywhere but a band next to the fold
            // (PageCurlGeometry.backShade).
            float shade = mix(\#(backFoldShade), 1.0, smoothstep(0.0, \#(backShadeBand), s));
            float axisDist = abs(s - R);
            float crest = exp(-pow(axisDist / max(R * 1.1, 0.015), 2.0));
            float spec = crest * u.specular * 0.22 * envelope;
            float3 specColor = spec * float3(1.0, 0.98, 0.94);
            return float4(clamp(back * shade + specColor, 0.0, 1.0), 1.0);
        }

        bool onLeaf = false;
        {
            float along = (iso.x - u.spineX) * sign;
            onLeaf = along >= -0.004 && along <= span + 0.004
                && iso.y >= -0.004 && iso.y <= pageH + 0.004;
        }
        if (onLeaf && s >= 0.0) {
            return float4(outC, 1.0);
        }
        // The other half of a spread is not peeled. The fold stops at the spine.
        if (u.realVerso > 0.5) {
            float along = (iso.x - u.spineX) * sign;
            if (along < -0.004 && iso.x >= -0.02 && iso.x <= 1.02
                && iso.y >= -0.02 && iso.y <= pageH + 0.02) {
                return float4(outC, 1.0);
            }
        }

        // Next page, full contrast, with a short shadow along the leaf's edge.
        float3 inC = sampleTex(incoming, uv);
        float gap = -s;
        if (s >= 0.0) {
            float along = (pre.x - u.spineX) * sign;
            float dx = 0.0;
            if (along < 0.0) dx = -along;
            else if (along > span) dx = along - span;
            float dy = 0.0;
            if (pre.y < 0.0) dy = -pre.y;
            else if (pre.y > pageH) dy = pre.y - pageH;
            gap = length(float2(dx, dy));
        }
        float shadow = exp(-max(gap, 0.0) / 0.020) * 0.18 * envelope;
        return float4(clamp(inC * (1.0 - shadow), 0.0, 1.0), 1.0);
    }
    """#
}
