//! Full-frame "assistant is thinking" glow.
//!
//! A breathing rim light around the window edge, driven entirely by the
//! post-process shader that `main.zig` registers via `.custom_shaders`.
//! While a request is in flight the window border breathes in the theme
//! accent; the rest of the time the shader is a passthrough.
//!
//! Gooey's shader system is full-frame only — there is no per-widget or
//! region-scoped pass (see `post_process.renderFullPipeline`, which runs
//! every registered pipeline over the whole drawable). So the effect is
//! masked to the border in the shader instead, which also keeps it off
//! the message text in the middle of the window.
//!
//! The only app-writable uniform is `iAccentColor` (`Window.setAccentColor`),
//! whose alpha channel is documented as a mode selector. We use rgb for the
//! theme accent and alpha as the on/off gate.

const std = @import("std");
const gooey = @import("gooey");
const Cx = gooey.Cx;
const Color = gooey.Color;

const pulse_dot = @import("components/pulse_dot.zig");

/// Breath period, shared with `PulseDot` so the border and the dot move at
/// the same tempo. They won't share a phase — `iTime` counts from process
/// start while the dot's tween starts when it mounts — but matching the
/// period keeps them from visibly fighting each other.
const BREATH_PERIOD_SECONDS: f32 =
    @as(f32, @floatFromInt(pulse_dot.PERIOD_MS_DEFAULT)) / 1000.0;

/// How far inward the glow reaches, in device pixels. Measured in pixels
/// rather than UV so the rim stays the same thickness on all four sides of
/// a non-square window.
const RIM_WIDTH_PIXELS: f32 = 150.0;

/// Maximum accent coverage at the hottest packet and bracket pixels. Motion
/// should read before color, so the underlying glass remains dominant.
const RIM_STRENGTH: f32 = 0.42;

/// Floor under the breath, so the frame remains legible between sweeps.
const BREATH_MIN: f32 = 0.3;

/// Height of each candidate glitch slice in device pixels. Only a sparse,
/// deterministic subset activates on each quantized time step.
const GLITCH_SLICE_HEIGHT_PIXELS: f32 = 12.0;

/// Maximum horizontal sample displacement for an active slice.
const GLITCH_SHIFT_PIXELS: f32 = 6.0;

/// Drive the shader's gate for this frame.
///
/// Call once per frame from the root layout, before rendering children.
/// Safe to call when no shader is registered — `setAccentColor` no-ops if
/// the post-process state was never initialized.
pub fn drive(cx: *Cx, thinking: bool, accent: Color) void {
    std.debug.assert(accent.r >= 0.0);
    std.debug.assert(accent.r <= 1.0);
    std.debug.assert(accent.g >= 0.0);
    std.debug.assert(accent.g <= 1.0);
    std.debug.assert(accent.b >= 0.0);
    std.debug.assert(accent.b <= 1.0);

    // Hard on/off. The shader's own breath is what keeps the transition from
    // looking abrupt; a spring ramp on top of it was a second, redundant
    // animation. If the snap ever reads badly, this is the place to ease it.
    const gate: f32 = if (thinking) 1.0 else 0.0;

    cx.window().setAccentColor(accent.r, accent.g, accent.b, gate);
}

/// Metal Shading Language source. macOS-only — `main.zig` asserts we are
/// never running as WASM, so there is no WGSL twin to keep in sync.
///
/// Gooey wraps this with `msl_prefix` / `msl_suffix`, which supply the
/// `ShaderUniforms` struct, the fullscreen vertex stage, and the fragment
/// entry point. We provide `mainImage` only.
pub const msl = std.fmt.comptimePrint(
    \\// Tunables are bound to typed constants rather than inlined at the call
    \\// sites: Zig renders a whole number like 260 without a decimal point,
    \\// and an int literal reaching an overloaded builtin such as smoothstep
    \\// is a needless ambiguity risk. Assigning through `float` settles the
    \\// type once, here.
    \\constant float RIM_WIDTH_PIXELS = {[rim_width]d};
    \\constant float BREATH_PERIOD_SECONDS = {[period]d};
    \\constant float RIM_STRENGTH = {[strength]d};
    \\constant float BREATH_MIN = {[breath_min]d};
    \\constant float GLITCH_SLICE_HEIGHT_PIXELS = {[slice_height]d};
    \\constant float GLITCH_SHIFT_PIXELS = {[shift_pixels]d};
    \\
    \\void mainImage(thread float4& fragColor, float2 fragCoord,
    \\               constant ShaderUniforms& uniforms,
    \\               texture2d<float> iChannel0,
    \\               sampler iChannel0Sampler) {{
    \\    float2 uv = fragCoord / uniforms.iResolution.xy;
    \\    float4 scene = iChannel0.sample(iChannel0Sampler, uv);
    \\
    \\    // Alpha of the accent uniform is the gate. Fully closed means the
    \\    // pass must be indistinguishable from not having a shader at all.
    \\    float gate = uniforms.iAccentColor.a;
    \\    if (gate <= 0.0) {{
    \\        fragColor = scene;
    \\        return;
    \\    }}
    \\
    \\    float2 resolution = uniforms.iResolution.xy;
    \\    float2 edge_pixels = min(fragCoord, resolution - fragCoord);
    \\    float edge_nearest = min(edge_pixels.x, edge_pixels.y);
    \\    float rim = 1.0 - smoothstep(0.0, RIM_WIDTH_PIXELS, edge_nearest);
    \\
    \\    // Quantize time so each sparse horizontal slice holds briefly before
    \\    // jumping. Roughly one quarter activate, enough to read as motion
    \\    // without turning the whole window into visual noise.
    \\    float tick = floor(uniforms.iTime * 12.0);
    \\    float slice_index = floor(fragCoord.y / GLITCH_SLICE_HEIGHT_PIXELS);
    \\    float slice_hash = fract(sin(slice_index * 91.345 + tick * 17.123) * 47453.5453);
    \\    float slice_active = step(0.76, slice_hash);
    \\    float shift_direction = step(0.5, fract(slice_hash * 7.31)) * 2.0 - 1.0;
    \\    float shift_pixels = shift_direction * GLITCH_SHIFT_PIXELS * slice_active;
    \\
    \\    // Distort only inside the rim. Separate red and blue by less than a
    \\    // pixel at typical scale, then mix lightly with the untouched scene.
    \\    float2 shift_uv = float2(shift_pixels / resolution.x, 0.0);
    \\    float4 shifted = iChannel0.sample(iChannel0Sampler, clamp(uv + shift_uv, 0.0, 1.0));
    \\    float red = iChannel0.sample(iChannel0Sampler,
    \\        clamp(uv + shift_uv * 0.35, 0.0, 1.0)).r;
    \\    float blue = iChannel0.sample(iChannel0Sampler,
    \\        clamp(uv - shift_uv * 0.35, 0.0, 1.0)).b;
    \\    float3 glitch_rgb = float3(red, shifted.g, blue);
    \\    float signal_level = 0.94 + 0.10 * step(0.5, fract(slice_hash * 13.7));
    \\    glitch_rgb *= signal_level;
    \\    float glitch_amount = rim * slice_active * gate * 0.48;
    \\    float3 color = mix(scene.rgb, glitch_rgb, glitch_amount);
    \\
    \\    // A thin rolling sync tear supplies continuous motion between the
    \\    // sparse jumps without washing the frame in the accent color.
    \\    float sync_y = fract(uniforms.iTime * 0.16) * resolution.y;
    \\    float sync_distance = abs(fragCoord.y - sync_y);
    \\    float sync_line = 1.0 - smoothstep(0.0, 7.0, sync_distance);
    \\    float scanline = 0.72 + 0.28 * step(0.5, fract(fragCoord.y * 0.25));
    \\
    \\    float phase = fract(uniforms.iTime / BREATH_PERIOD_SECONDS);
    \\    float triangle = 1.0 - abs(2.0 * phase - 1.0);
    \\    float breath = BREATH_MIN + (1.0 - BREATH_MIN) * triangle;
    \\    float sheen = rim * scanline * (0.08 * breath + 0.24 * sync_line);
    \\    float accent_amount = sheen * gate * RIM_STRENGTH;
    \\    color = mix(color, uniforms.iAccentColor.rgb, accent_amount);
    \\    fragColor = float4(color, mix(scene.a, 1.0, accent_amount));
    \\}}
, .{
    .rim_width = RIM_WIDTH_PIXELS,
    .period = BREATH_PERIOD_SECONDS,
    .strength = RIM_STRENGTH,
    .breath_min = BREATH_MIN,
    .slice_height = GLITCH_SLICE_HEIGHT_PIXELS,
    .shift_pixels = GLITCH_SHIFT_PIXELS,
});
