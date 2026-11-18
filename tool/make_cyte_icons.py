#!/usr/bin/env python3
"""Generates Cyte's brand icon suite (macOS, Windows .ico, Web, SVG, Extension).

Visual identity (sister aesthetic to Byte & Ayte):
- Cool Glacier-Porcelain macOS squircle (#FCFDFE -> #EEF5FA) with soft ambient
  drop shadows and crisp top glass specular bevel.
- Sculpted 3D lowercase 'c' open arc with rounded caps, flowing from Electric
  Cyan (#22D3EE) through Cobalt Blue (#0284C7 -> #2563EB) into Luminous Emerald
  (#10B981), with 3D cylindrical cross-section lighting and frosted glass rim.
- Floating 3D glossy Emerald-Lime Spark Orb (#D9F99D -> #34D399 -> #059669) at
  the upper-right opening.
"""

from __future__ import annotations

import math
import pathlib
import numpy as np
from PIL import Image, ImageDraw, ImageFilter

ROOT = pathlib.Path(__file__).resolve().parent.parent


def _superellipse_mask(size: int, box: tuple[float, float, float, float], radius: float) -> Image.Image:
    im = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(im)
    d.rounded_rectangle(box, radius=radius, fill=255)
    return im


def _render_c_arc_and_orb(S: int, scale: float) -> tuple[Image.Image, Image.Image]:
    """Renders the 3D sculpted 'c' arc + floating spark orb + ambient glow at SxS."""
    yy, xx = np.mgrid[0:S, 0:S].astype(np.float32)

    # 'c' arc geometry in 1024-space (centered comfortably inside 824x824 squircle)
    cx = 478.0 * scale
    cy = 532.0 * scale
    mid_r = 166.0 * scale
    half_w = 46.0 * scale
    gap_rad = 0.72  # ~41.25 deg half-opening on right

    dx = xx - cx
    dy = yy - cy
    theta = np.arctan2(dy, dx)  # [-pi, pi], 0 = right, +pi/2 = bottom, -pi/2 = top
    r = np.hypot(dx, dy)

    cap_x = mid_r * math.cos(gap_rad)
    cap_y = mid_r * math.sin(gap_rad)
    in_gap = np.abs(theta) <= gap_rad
    target_y = np.where(dy >= 0.0, cap_y, -cap_y)

    # Closest point on the 'c' centerline (continuous across body & caps!)
    safe_r = np.maximum(r, 1e-4)
    cl_x = np.where(in_gap, cap_x, mid_r * dx / safe_r)
    cl_y = np.where(in_gap, target_y, mid_r * dy / safe_r)
    vx = dx - cl_x
    vy = dy - cl_y
    dist_cl = np.hypot(vx, vy)
    sdf_c = dist_cl - half_w

    # Smooth antialiased alpha over 1.5px at 2048x2048
    aa_c = np.clip(0.5 - sdf_c / 1.4, 0.0, 1.0)

    # Progress t along the 'c' arc: 0.0 at top-right cap, 1.0 at bottom-right cap,
    # clamped smoothly in the gap so neither cap ever wraps modulo 2*pi!
    span_angle = 2.0 * math.pi - 2.0 * gap_rad
    raw_ccw = (-gap_rad - theta) % (2.0 * math.pi)
    t_arc = np.where(
        in_gap,
        np.where(dy < 0.0, 0.0, 1.0),
        np.clip(raw_ccw / span_angle, 0.0, 1.0),
    )

    # Gradient stops along 'c':
    # 0.00 (top-right): Electric Cyan (#38BDF8 / #22D3EE)
    # 0.36 (top-left):  Sky-Cobalt (#0EA5E9)
    # 0.70 (bottom-left): Deep Cobalt-Indigo (#2563EB)
    # 1.00 (bottom-right): Luminous Teal-Emerald (#10B981)
    stops_t = np.array([0.0, 0.34, 0.68, 1.0], dtype=np.float32)
    stops_rgb = np.array(
        [
            [56.0, 221.0, 248.0],   # #38DDF8 bright sky-cyan
            [14.0, 165.0, 233.0],   # #0EA5E9 azure-cyan
            [37.0, 99.0, 235.0],    # #2563EB cobalt blue
            [16.0, 185.0, 129.0],   # #10B981 luminous emerald
        ],
        dtype=np.float32,
    )
    flat_t = t_arc.ravel()
    cr = np.interp(flat_t, stops_t, stops_rgb[:, 0]).reshape(S, S)
    cg = np.interp(flat_t, stops_t, stops_rgb[:, 1]).reshape(S, S)
    cb = np.interp(flat_t, stops_t, stops_rgb[:, 2]).reshape(S, S)

    # Smooth 3D torus + hemisphere normal (C^1 continuous everywhere, zero crease!)
    nx_tube = np.clip(vx / half_w, -1.0, 1.0)
    ny_tube = np.clip(vy / half_w, -1.0, 1.0)
    r2_tube = np.clip(nx_tube ** 2 + ny_tube ** 2, 0.0, 1.0)
    nz_tube = np.sqrt(1.0 - r2_tube)

    # Soft studio lighting (matching Ayte's silky matte-satin 3D finish)
    lx, ly, lz = -0.34, -0.48, 0.81
    ndotl = np.clip(nx_tube * lx + ny_tube * ly + nz_tube * lz, 0.0, 1.0)
    spec = (ndotl ** 12.0) * 0.20
    shade = 0.88 + 0.18 * ndotl - 0.07 * (r2_tube ** 1.4)

    # Subtle frosty glass edge highlight along upper rim
    rim_band = (
        np.exp(-((sdf_c + 2.0 * scale) ** 2) / ((1.8 * scale) ** 2))
        * np.clip(-ny_tube * 0.5 + 0.5, 0.15, 1.0)
    )

    c_rgb = np.stack([cr * shade, cg * shade, cb * shade], axis=-1)
    c_rgb += (spec[:, :, None] + 0.22 * rim_band[:, :, None]) * 255.0
    c_rgba = np.zeros((S, S, 4), dtype=np.uint8)
    c_rgba[:, :, :3] = np.clip(c_rgb, 0, 255).astype(np.uint8)
    c_rgba[:, :, 3] = np.clip(aa_c * 255.0, 0, 255).astype(np.uint8)
    c_img = Image.fromarray(c_rgba, mode="RGBA")

    # Floating Spark Orb at upper-right opening (matching Ayte's golden orb poise,
    # rendered in luminous Emerald-Mint-Gold jewel tones)
    ox = 696.0 * scale
    oy = 286.0 * scale
    orad = 42.0 * scale
    odx = (xx - ox) / orad
    ody = (yy - oy) / orad
    odist = np.hypot(odx, ody)
    sdf_o = (odist - 1.0) * orad
    aa_o = np.clip(0.5 - sdf_o / 1.4, 0.0, 1.0)

    oz = np.sqrt(np.clip(1.0 - odx ** 2 - ody ** 2, 0.0, 1.0))
    # Radial jewel gradient from upper-left highlight (#ECFCCB -> #34D399 -> #059669 -> #047857)
    hl_dist = np.clip(np.hypot(odx + 0.34, ody + 0.36) / 1.45, 0.0, 1.0)
    o_stops = np.array([0.0, 0.28, 0.68, 1.0], dtype=np.float32)
    o_cols = np.array(
        [
            [236.0, 252.0, 203.0],  # #ECFCCB warm mint-lime pearl highlight
            [52.0, 211.0, 153.0],   # #34D399 luminous emerald
            [16.0, 185.0, 129.0],   # #10B981 rich emerald
            [4.0, 120.0, 87.0],     # #047857 deep jewel emerald
        ],
        dtype=np.float32,
    )
    flat_h = hl_dist.ravel()
    orb_r = np.interp(flat_h, o_stops, o_cols[:, 0]).reshape(S, S)
    orb_g = np.interp(flat_h, o_stops, o_cols[:, 1]).reshape(S, S)
    orb_b = np.interp(flat_h, o_stops, o_cols[:, 2]).reshape(S, S)

    orb_spec = (np.clip(odx * (-0.38) + ody * (-0.48) + oz * 0.79, 0.0, 1.0) ** 16.0) * 0.45
    orb_rgb = np.stack([orb_r, orb_g, orb_b], axis=-1) + orb_spec[:, :, None] * 255.0

    orb_rgba = np.zeros((S, S, 4), dtype=np.uint8)
    orb_rgba[:, :, :3] = np.clip(orb_rgb, 0, 255).astype(np.uint8)
    orb_rgba[:, :, 3] = np.clip(aa_o * 255.0, 0, 255).astype(np.uint8)
    orb_img = Image.fromarray(orb_rgba, mode="RGBA")

    fg = Image.alpha_composite(c_img, orb_img)

    # Soft colored ambient elevation shadow beneath the 'c' arc and orb
    glow_src = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    # Shift slightly down (+14px in 1024-space) for tactile floating depth on porcelain
    shift_y = int(round(14.0 * scale))
    glow_arr = np.array(fg)
    glow_arr[:, :, 3] = np.clip(glow_arr[:, :, 3].astype(np.float32) * 0.34, 0, 255).astype(np.uint8)
    shifted = Image.fromarray(glow_arr, mode="RGBA")
    glow_src.alpha_composite(shifted, (0, shift_y))
    glow = glow_src.filter(ImageFilter.GaussianBlur(radius=22.0 * scale))

    return glow, fg


def render_macos_icon(target_size: int = 1024) -> Image.Image:
    """Renders the 1024x1024 macOS squircle icon with 2x supersampling."""
    S = 2048
    scale = S / 1024.0

    pad = 100.0 * scale
    sq_w = 824.0 * scale
    box = (pad, pad, pad + sq_w - 1, pad + sq_w - 1)
    radius = 185.0 * scale

    canvas = Image.new("RGBA", (S, S), (0, 0, 0, 0))

    # 1. Soft macOS drop shadow (matching Ayte's porcelain elevation)
    shadow1 = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    sd1 = ImageDraw.Draw(shadow1)
    sd1.rounded_rectangle(
        (pad, pad + 24 * scale, pad + sq_w - 1, pad + sq_w - 1 + 24 * scale),
        radius=radius,
        fill=(15, 23, 42, 46),
    )
    shadow1 = shadow1.filter(ImageFilter.GaussianBlur(radius=26 * scale))

    shadow2 = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    sd2 = ImageDraw.Draw(shadow2)
    sd2.rounded_rectangle(
        (pad, pad + 8 * scale, pad + sq_w - 1, pad + sq_w - 1 + 8 * scale),
        radius=radius,
        fill=(15, 23, 42, 28),
    )
    shadow2 = shadow2.filter(ImageFilter.GaussianBlur(radius=9 * scale))

    canvas = Image.alpha_composite(canvas, shadow1)
    canvas = Image.alpha_composite(canvas, shadow2)

    # 2. Cool Glacier-Porcelain Squircle Surface (#FCFDFE -> #EFF6FA)
    yy, xx = np.mgrid[0:S, 0:S].astype(np.float32)
    ny = np.clip((yy - pad) / sq_w, 0.0, 1.0)
    nx = np.clip((xx - pad) / sq_w, 0.0, 1.0)

    bg_r = 252.0 * (1.0 - ny) + 239.0 * ny
    bg_g = 254.0 * (1.0 - ny) + 245.0 * ny
    bg_b = 255.0 * (1.0 - ny) + 250.0 * ny

    # Subtle radial cyan-mint pearl warmth behind glyph
    pearl = np.exp(-(((nx - 0.52) ** 2) / 0.18 + ((ny - 0.46) ** 2) / 0.18))
    bg_r -= 2.0 * pearl
    bg_g += 1.5 * pearl
    bg_b += 2.5 * pearl

    bg_rgb = np.clip(np.stack([bg_r, bg_g, bg_b], axis=-1), 0, 255).astype(np.uint8)
    sq_mask = _superellipse_mask(S, box, radius)
    bg_im = Image.fromarray(bg_rgb, mode="RGB").convert("RGBA")
    bg_im.putalpha(sq_mask)

    # 3. Sculpted 'c' arc + floating emerald spark orb
    glow, fg = _render_c_arc_and_orb(S, scale)
    glow_arr = np.array(glow)
    sq_alpha = np.array(sq_mask, dtype=np.float32) / 255.0
    glow_arr[:, :, 3] = np.clip(glow_arr[:, :, 3].astype(np.float32) * sq_alpha, 0, 255).astype(np.uint8)
    bg_im = Image.alpha_composite(bg_im, Image.fromarray(glow_arr, mode="RGBA"))
    bg_im = Image.alpha_composite(bg_im, fg)

    # 4. Crisp porcelain squircle border & top specular rim
    bevel = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    bd = ImageDraw.Draw(bevel)
    bw_px = max(2, round(2.2 * scale))
    bd.rounded_rectangle(
        (pad + bw_px * 0.5, pad + bw_px * 0.5, pad + sq_w - 1 - bw_px * 0.5, pad + sq_w - 1 - bw_px * 0.5),
        radius=radius - bw_px * 0.5,
        outline=(203, 213, 225, 135),
        width=bw_px,
    )
    bevel_arr = np.array(bevel)
    bevel_arr[:, :, 3] = np.minimum(bevel_arr[:, :, 3], np.array(sq_mask))
    bg_im = Image.alpha_composite(bg_im, Image.fromarray(bevel_arr, mode="RGBA"))

    canvas = Image.alpha_composite(canvas, bg_im)
    if target_size != S:
        return canvas.resize((target_size, target_size), Image.LANCZOS)
    return canvas


def render_full_bleed_icon(size: int) -> Image.Image:
    base = render_macos_icon(1024)
    cropped = base.crop((96, 96, 928, 928))
    return cropped.resize((size, size), Image.LANCZOS)


# Crisp vector mark for Cyte ('c' open arc with rounded caps + spark orb).
# Uses an explicit filled ring-sector path so flutter_svg renders it cleanly
# both in color and with single-color ColorFilter.srcIn!
def _build_svg_logo() -> str:
    cx, cy = 478.0, 532.0
    r_mid, half_w = 166.0, 46.0
    r_out = r_mid + half_w
    r_in = r_mid - half_w
    gap = 0.72
    # Top-right cap center (-gap) and bottom-right cap center (+gap)
    tx, ty = cx + r_mid * math.cos(-gap), cy + r_mid * math.sin(-gap)
    bx, by = cx + r_mid * math.cos(gap), cy + r_mid * math.sin(gap)
    to_x, to_y = cx + r_out * math.cos(-gap), cy + r_out * math.sin(-gap)
    ti_x, ti_y = cx + r_in * math.cos(-gap), cy + r_in * math.sin(-gap)
    bo_x, bo_y = cx + r_out * math.cos(gap), cy + r_out * math.sin(gap)
    bi_x, bi_y = cx + r_in * math.cos(gap), cy + r_in * math.sin(gap)

    # Outer arc from top-right (to_x, to_y) counter-clockwise (sweep=0, large-arc=1)
    # to bottom-right (bo_x, bo_y), rounded endcap to (bi_x, bi_y), inner arc
    # clockwise (sweep=1, large-arc=1) back to (ti_x, ti_y), rounded endcap to (to_x, to_y).
    d = (
        f"M {to_x:.2f} {to_y:.2f} "
        f"A {r_out:.2f} {r_out:.2f} 0 1 0 {bo_x:.2f} {bo_y:.2f} "
        f"A {half_w:.2f} {half_w:.2f} 0 0 1 {bi_x:.2f} {bi_y:.2f} "
        f"A {r_in:.2f} {r_in:.2f} 0 1 1 {ti_x:.2f} {ti_y:.2f} "
        f"A {half_w:.2f} {half_w:.2f} 0 0 1 {to_x:.2f} {to_y:.2f} Z"
    )
    return f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="256 232 498 524" fill="none">
  <defs>
    <linearGradient id="cyteArc" x1="290" y1="330" x2="630" y2="730" gradientUnits="userSpaceOnUse">
      <stop offset="0%" stop-color="#22D3EE" />
      <stop offset="45%" stop-color="#0EA5E9" />
      <stop offset="78%" stop-color="#2563EB" />
      <stop offset="100%" stop-color="#10B981" />
    </linearGradient>
    <radialGradient id="cyteOrb" cx="684" cy="274" r="54" gradientUnits="userSpaceOnUse">
      <stop offset="0%" stop-color="#ECFCCB" />
      <stop offset="45%" stop-color="#34D399" />
      <stop offset="100%" stop-color="#059669" />
    </radialGradient>
  </defs>
  <path d="{d}" fill="url(#cyteArc)" />
  <circle cx="696" cy="286" r="42" fill="url(#cyteOrb)" />
</svg>
"""


def main() -> None:
    master = render_macos_icon(1024)

    # 1. Branding assets
    branding = ROOT / "assets/branding"
    master.save(branding / "app_icon.png", optimize=True)
    (branding / "logo.svg").write_text(_build_svg_logo(), encoding="utf-8")

    # 2. macOS AppIcon.appiconset & AppIcon-Dev.appiconset
    for appicon_dir in [
        ROOT / "macos/Runner/Assets.xcassets/AppIcon.appiconset",
        ROOT / "macos/Runner/Assets.xcassets/AppIcon-Dev.appiconset",
    ]:
        if not appicon_dir.exists():
            continue
        for s in (16, 32, 64, 128, 256, 512, 1024):
            resized = master if s == 1024 else master.resize((s, s), Image.LANCZOS)
            target = appicon_dir / f"app_icon_{s}.png"
            if target.exists() or appicon_dir.name == "AppIcon.appiconset":
                resized.save(target, optimize=True)

    # 3. Web icons & favicon
    full_512 = render_full_bleed_icon(512)
    full_192 = render_full_bleed_icon(192)
    full_32 = render_full_bleed_icon(32)
    if (ROOT / "web").exists():
        full_32.save(ROOT / "web/favicon.png", optimize=True)
        full_192.save(ROOT / "web/icons/Icon-192.png", optimize=True)
        full_512.save(ROOT / "web/icons/Icon-512.png", optimize=True)
        full_192.save(ROOT / "web/icons/Icon-maskable-192.png", optimize=True)
        full_512.save(ROOT / "web/icons/Icon-maskable-512.png", optimize=True)

    # 4. Browser extension icons
    ext_icons = ROOT / "browser_extension/icons"
    if ext_icons.exists():
        for s in (16, 32, 48):
            render_full_bleed_icon(s).save(ext_icons / f"icon-{s}.png", optimize=True)
        framed = Image.new("RGBA", (128, 128), (0, 0, 0, 0))
        framed.alpha_composite(render_full_bleed_icon(96), (16, 16))
        framed.save(ext_icons / "icon-128.png", optimize=True)

    # 5. Windows .ico
    win_res = ROOT / "windows/runner/resources"
    if win_res.exists():
        ico_base = render_full_bleed_icon(256)
        for ico_name in ("app_icon.ico", "app_icon_dev.ico"):
            if (win_res / ico_name).exists():
                ico_base.save(
                    win_res / ico_name,
                    format="ICO",
                    sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)],
                )

    print("✓ Generated all Cyte brand icon assets.")


if __name__ == "__main__":
    main()
