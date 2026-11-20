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
/// ends. The fold is the perpendicular bisector of `p0`→`p`; the leaf wraps a
/// cylinder whose axis is that line moved `π/2 · radius` toward the finger
/// (see `PageCurlGeometry.spreadSample` and `rollArc`, which this fragment
/// matches). The back of the leaf is opaque. The next page is drawn only where
/// the leaf does not cover it.
enum PageCurlShader {
    private static func f(_ value: CGFloat) -> String {
        String(format: "%.4f", value)
    }

    private static let crestDarkening = f(PageCurlGeometry.rollCrestDarkening)
    private static let rollShadowStrength = f(PageCurlGeometry.rollShadowStrength)
    private static let rollShadowWidth = f(PageCurlGeometry.rollShadowWidth)
    private static let flapShadowStrength = f(PageCurlGeometry.flapShadowStrength)
    private static let flapShadowWidth = f(PageCurlGeometry.flapShadowWidth)

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

    // Distance from the leaf's rectangle, 0 inside.
    static float leafGap(float2 q, float spineX, float sign, float span, float pageH) {
        float along = (q.x - spineX) * sign;
        float dx = 0.0;
        if (along < 0.0) dx = -along;
        else if (along > span) dx = along - span;
        float dy = 0.0;
        if (q.y < 0.0) dy = -q.y;
        else if (q.y > pageH) dy = q.y - pageH;
        return length(float2(dx, dy));
    }

    static bool inLeaf(float2 q, float spineX, float sign, float span, float pageH) {
        float along = (q.x - spineX) * sign;
        return along >= -0.004 && along <= span + 0.004 && q.y >= -0.004 && q.y <= pageH + 0.004;
    }

    // Keep this in lockstep with PageCurlGeometry.spreadSample / rollArc.
    // w is the distance from the cylinder axis toward the held edge. The
    // sheet is flat for w < 0, wraps the cylinder over 0 ... R, and its back
    // comes over the top toward the finger. Topmost surface wins.
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

        // `finger` is already within reach of the spine
        // (PageCurlGeometry.attachedHeldPoint), so the bisector never crosses it.
        float2 N = delta / len;
        float R = max(u.radius, 0.0);
        float2 axis = (p0 + finger) * 0.5 + N * (R * 1.57079633);
        float w = dot(axis - iso, N);
        float sinT = clamp(w / R, 0.0, 1.0);
        float theta = asin(sinT);
        // Darker only where the sheet turns edge-on (PageCurlGeometry.rollShade).
        float rollShade = w >= 0.0 ? 1.0 - \#(crestDarkening) * sinT * sinT : 1.0;

        // Back: flat over the page (w < 0) or over the top of the roll.
        if (w <= R) {
            float t = w < 0.0 ? 3.14159265 * R - w : R * (3.14159265 - theta);
            float2 q = iso - N * (t - w);
            if (inLeaf(q, u.spineX, sign, span, pageH)) {
                float3 back;
                if (u.realVerso > 0.5) {
                    float along = (q.x - u.spineX) * sign;
                    float far = max(1.0 - span, 0.0);
                    float versoAlong = -along * (far / span);
                    float versoX = u.spineX + sign * versoAlong;
                    back = sampleTex(incoming, float2(versoX, clamp(q.y * aspect, 0.0, 1.0)));
                } else {
                    back = paperBack(sampleTex(outgoing, paperUV(q, aspect)), u);
                }
                return float4(clamp(back * rollShade, 0.0, 1.0), 1.0);
            }
        }
        // Front, squeezing onto the near side of the roll.
        if (w >= 0.0 && w <= R) {
            float2 q = iso - N * (R * theta - w);
            if (inLeaf(q, u.spineX, sign, span, pageH)) {
                float3 front = sampleTex(outgoing, paperUV(q, aspect));
                return float4(clamp(front * rollShade, 0.0, 1.0), 1.0);
            }
        }
        // Flat front of the leaf, with a faint shadow along the flap's edge.
        if (w < 0.0 && inLeaf(iso, u.spineX, sign, span, pageH)) {
            float2 q = iso - N * (3.14159265 * R - 2.0 * w);
            float gap = leafGap(q, u.spineX, sign, span, pageH);
            float shadow = exp(-gap / \#(flapShadowWidth)) * \#(flapShadowStrength) * envelope;
            return float4(clamp(outC * (1.0 - shadow), 0.0, 1.0), 1.0);
        }
        // The other half of a spread is not peeled. The fold stops at the spine.
        if (u.realVerso > 0.5) {
            float along = (iso.x - u.spineX) * sign;
            if (along < -0.004 && iso.x >= -0.02 && iso.x <= 1.02
                && iso.y >= -0.02 && iso.y <= pageH + 0.02) {
                return float4(outC, 1.0);
            }
        }

        // Next page, full contrast, with a faint shadow past the roll.
        float3 inC = sampleTex(incoming, uv);
        float2 crest = iso - N * (R * 1.57079633 - w);
        float gap = max(w - R, 0.0) + leafGap(crest, u.spineX, sign, span, pageH);
        float shadow = exp(-gap / \#(rollShadowWidth)) * \#(rollShadowStrength) * envelope;
        return float4(clamp(inC * (1.0 - shadow), 0.0, 1.0), 1.0);
    }
    """#
}
