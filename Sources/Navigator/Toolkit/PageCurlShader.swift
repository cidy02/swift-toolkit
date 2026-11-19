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
/// ends. `tilt` is radians from vertical; a tap passes the bottom-corner value
/// and a finger drag passes `touchY`. `fold` is the centre of the fold in
/// `along` units, from `PageCurlGeometry.foldCenter`.
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
        float fold;
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

    // Flat outgoing. A centre spine gets a narrow crease. A one-page leaf does
    // not: a wide spine shadow reads as a veil over the unturned page.
    static float3 flatOutgoing(float3 color, float along, float envelope, constant CurlUniforms &u) {
        if (u.twoPage < 0.5) {
            return color;
        }
        float ao = exp(-abs(along) / 0.025) * 0.12 * envelope;
        return color * (1.0 - ao);
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

        float span = max(u.span, 0.05);
        float R = max(u.radius, 1.0e-4);
        float PI = 3.14159265;
        float3 inC = sampleTex(incoming, uv);
        float envelope = sin(clamp(u.progress, 0.0, 1.0) * PI);

        // Distance along the peel, then a fold line tilted in the same units.
        // Positive tilt drops the fold toward the spine at the bottom, so that
        // corner leads. The page image itself is not rotated. `u.fold` already
        // starts past the leading corner and, on two pages, crosses the far half.
        float aspect = max(u.aspect, 0.05);
        float along = (uv.x - u.spineX) * u.peelSign;
        float yOff = (uv.y - 0.5) / aspect;
        float tilt = clamp(u.tilt, -0.5, 0.5);
        float foldLine = u.fold - tan(tilt) * yOff;
        float dist = along - foldLine;

        // Unturned remainder, including the far half of a two-page spread that
        // the fold has not reached. A short shadow sits just ahead of the fold.
        if (dist <= 0.0) {
            float3 color = flatOutgoing(outC, along, envelope, u);
            float ahead = exp(dist / 0.028) * 0.16 * envelope;
            return float4(clamp(color * (1.0 - ahead), 0.0, 1.0), 1.0);
        }

        // Screen width of the roll. Arc length across it is pi*R, so the page is
        // compressed by pi/2 and no more. Mapping x = R*(1-cos) piles a finite
        // arc onto the tangent and reads as stripes.
        float curlWidth = 2.0 * R;
        if (dist >= curlWidth) {
            float past = dist - curlWidth;
            // Short falloff. A wide tail reads as a grey veil on the next page.
            float shadow = exp(-past / 0.038) * 0.20 * envelope;
            return float4(clamp(inC * (1.0 - shadow), 0.0, 1.0), 1.0);
        }

        float t = dist / curlWidth;
        float orig = foldLine + t * PI * R;
        float crest = sin(t * PI);
        float spec = pow(max(crest, 0.0), 2.5) * u.specular * 0.35 * envelope;
        float3 specColor = spec * float3(1.0, 0.98, 0.94);

        // The roll has run off the outer edge. Clamping that sample streaks
        // the margin pixel across the cylinder; the page underneath is inC.
        if (orig > span) {
            return float4(inC, 1.0);
        }

        // Front of the roll. Shade starts at 1 so it meets the flat page.
        if (t < 0.5) {
            float frontX = u.spineX + u.peelSign * orig;
            if (frontX < 0.0 || frontX > 1.0) {
                return float4(inC, 1.0);
            }
            float3 front = sampleTex(outgoing, leafUV(orig, uv.y, u));
            float shade = mix(1.0, 0.90, smoothstep(0.0, 0.5, t));
            return float4(clamp(front * shade + specColor, 0.0, 1.0), 1.0);
        }

        // Back of the roll. Opaque: it covers the next page, it is not mixed with it.
        // One page is a paper ghost. Two pages are the real verso.
        float backLeaf = (u.realVerso > 0.5) ? -orig : (span - orig);
        float backX = u.spineX + u.peelSign * backLeaf;
        if (backX < 0.0 || backX > 1.0) {
            return float4(inC, 1.0);
        }
        float3 back;
        float specScale;
        if (u.realVerso > 0.5) {
            back = sampleTex(incoming, leafUV(-orig, uv.y, u));
            specScale = 1.0;
        } else {
            back = paperBack(sampleTex(outgoing, leafUV(backLeaf, uv.y, u)), u);
            specScale = 0.40;
        }
        float backT = clamp((t - 0.5) / 0.5, 0.0, 1.0);
        float shade = mix(0.90, 0.98, smoothstep(0.0, 1.0, backT));
        return float4(clamp(back * shade + specColor * specScale, 0.0, 1.0), 1.0);
    }
    """#
}
