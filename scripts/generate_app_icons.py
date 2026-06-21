#!/usr/bin/env python3
"""
Generate CrossLink app launcher icons from the brand SVG.

Requires: Pillow
Install:  pip install Pillow

Outputs:
  - app/android/app/src/main/res/mipmap-*/ic_launcher.png
  - app/ios/Runner/Assets.xcassets/AppIcon.appiconset/*.png
"""

import os
import xml.etree.ElementTree as ET
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent.parent
OUT_ANDROID = ROOT / "app/android/app/src/main/res"
OUT_IOS = ROOT / "app/ios/Runner/Assets.xcassets/AppIcon.appiconset"

# Brand colors
DEEP_SPACE = (10, 11, 15)
DEEP_SPACE_ELEVATED = (18, 20, 28)
PANEL = (26, 29, 40)
PANEL_HOVER = (34, 38, 54)
LINK_CYAN = (0, 229, 255)
LINK_BLUE = (41, 121, 255)
LINK_PURPLE = (124, 77, 255)
ERROR_RED = (255, 82, 82)
ALERT_AMBER = (255, 179, 0)
SUCCESS_GREEN = (0, 230, 118)

ANDROID_SIZES = {
    "mipmap-mdpi": 48,
    "mipmap-hdpi": 72,
    "mipmap-xhdpi": 96,
    "mipmap-xxhdpi": 144,
    "mipmap-xxxhdpi": 192,
}

IOS_SIZES = [
    (20, 1), (20, 2), (20, 3),
    (29, 1), (29, 2), (29, 3),
    (40, 1), (40, 2), (40, 3),
    (60, 2), (60, 3),
    (76, 1), (76, 2),
    (83.5, 2),
    (1024, 1),
]


def hex_to_rgb(hex_color: str) -> tuple:
    h = hex_color.lstrip("#")
    return tuple(int(h[i : i + 2], 16) for i in (0, 2, 4))


def blend(c1, c2, t):
    return tuple(int(a + (b - a) * t) for a, b in zip(c1, c2))


def draw_gradient(draw, size, c1, c2, direction="diagonal"):
    """Draw a simple diagonal gradient by drawing many lines."""
    if direction == "diagonal":
        for i in range(size[0] + size[1]):
            t = min(i / (size[0] + size[1]), 1.0)
            color = blend(c1, c2, t)
            draw.line([(i, 0), (0, i)], fill=color, width=1)
    else:
        for y in range(size[1]):
            t = y / size[1]
            color = blend(c1, c2, t)
            draw.line([(0, y), (size[0], y)], fill=color, width=1)


def draw_rounded_rect(draw, xy, radius, fill, outline=None, width=1):
    x0, y0, x1, y1 = xy
    r = radius
    draw.pieslice([x0, y0, x0 + 2 * r, y0 + 2 * r], 180, 270, fill=fill)
    draw.pieslice([x1 - 2 * r, y0, x1, y0 + 2 * r], 270, 360, fill=fill)
    draw.pieslice([x0, y1 - 2 * r, x0 + 2 * r, y1], 90, 180, fill=fill)
    draw.pieslice([x1 - 2 * r, y1 - 2 * r, x1, y1], 0, 90, fill=fill)
    draw.rectangle([x0 + r, y0, x1 - r, y1], fill=fill)
    draw.rectangle([x0, y0 + r, x1, y1 - r], fill=fill)
    if outline:
        draw.arc([x0, y0, x0 + 2 * r, y0 + 2 * r], 180, 270, fill=outline, width=width)
        draw.arc([x1 - 2 * r, y0, x1, y0 + 2 * r], 270, 360, fill=outline, width=width)
        draw.arc([x0, y1 - 2 * r, x0 + 2 * r, y1], 90, 180, fill=outline, width=width)
        draw.arc([x1 - 2 * r, y1 - 2 * r, x1, y1], 0, 90, fill=outline, width=width)
        draw.line([(x0 + r, y0), (x1 - r, y0)], fill=outline, width=width)
        draw.line([(x0 + r, y1), (x1 - r, y1)], fill=outline, width=width)
        draw.line([(x0, y0 + r), (x0, y1 - r)], fill=outline, width=width)
        draw.line([(x1, y0 + r), (x1, y1 - r)], fill=outline, width=width)


def draw_glow_circle(draw, center, radius, color, bands=8):
    cx, cy = center
    for i in range(bands, 0, -1):
        alpha = int(30 * (i / bands))
        r = radius + i * 2
        draw.ellipse([cx - r, cy - r, cx + r, cy + r], fill=(*color, alpha))


def render_icon(size: int) -> Image.Image:
    """Render the CrossLink icon at the given square size."""
    img = Image.new("RGBA", (size, size), DEEP_SPACE)
    draw = ImageDraw.Draw(img)

    # Background gradient
    draw_gradient(draw, (size, size), DEEP_SPACE_ELEVATED, DEEP_SPACE, "diagonal")

    # Outer glow border
    pad = size // 16
    glow = size // 48
    for i in range(glow, 0, -1):
        alpha = int(40 * (i / glow))
        draw.rounded_rectangle(
            [pad + i, pad + i, size - pad - i, size - pad - i],
            radius=size // 8,
            outline=(*LINK_CYAN, alpha),
            width=1,
        )

    # Terminal window
    tw = int(size * 0.66)
    th = int(size * 0.47)
    tx = (size - tw) // 2
    ty = int(size * 0.18)
    tr = size // 22

    draw_rounded_rect(draw, [tx, ty, tx + tw, ty + th], tr, PANEL, outline=(42, 46, 61), width=max(1, size // 256))
    # Title bar
    title_h = int(th * 0.18)
    draw_rounded_rect(draw, [tx, ty, tx + tw, ty + title_h + tr], tr, PANEL_HOVER)
    draw.rectangle([tx, ty + tr, tx + tw, ty + title_h], fill=PANEL_HOVER)

    # Window control dots
    dot_r = max(2, size // 60)
    dots_x = tx + int(size * 0.05)
    dots_y = ty + title_h // 2
    for dx, color in [(0, ERROR_RED), (dot_r * 3, ALERT_AMBER), (dot_r * 6, SUCCESS_GREEN)]:
        draw.ellipse([dots_x + dx - dot_r, dots_y - dot_r, dots_x + dx + dot_r, dots_y + dot_r], fill=color)

    # Prompt text >_
    prompt_x = tx + int(size * 0.06)
    prompt_y = ty + title_h + int(size * 0.07)
    font_size = max(8, size // 14)
    try:
        font = ImageFont.truetype("DejaVuSansMono-Bold.ttf", font_size)
    except Exception:
        try:
            font = ImageFont.truetype("consolab.ttf", font_size)
        except Exception:
            font = ImageFont.load_default()
    draw.text((prompt_x, prompt_y), ">_", fill=LINK_CYAN, font=font)

    # Code lines
    line_h = max(1, size // 60)
    line_y = prompt_y + font_size + int(size * 0.03)
    line_colors = [(255, 255, 255, 50), (255, 255, 255, 30), (255, 255, 255, 15)]
    line_widths = [int(tw * 0.55), int(tw * 0.4), int(tw * 0.5)]
    for lw, lc in zip(line_widths, line_colors):
        draw.rounded_rectangle([prompt_x, line_y, prompt_x + lw, line_y + line_h], radius=line_h // 2, fill=lc)
        line_y += line_h + int(size * 0.02)

    # Connection line from terminal to node
    start_x = tx + tw
    start_y = ty + th - int(size * 0.05)
    mid_x = int(size * 0.55)
    end_x = int(size * 0.74)
    end_y = int(size * 0.74)

    # Quadratic bezier-ish line by sampling
    points = []
    for t in range(0, 101):
        t /= 100
        # control point below start/end
        cx = (start_x + end_x) / 2
        cy = end_y + int(size * 0.08)
        x = int((1 - t) * (1 - t) * start_x + 2 * (1 - t) * t * cx + t * t * end_x)
        y = int((1 - t) * (1 - t) * start_y + 2 * (1 - t) * t * cy + t * t * end_y)
        points.append((x, y))

    line_w = max(2, size // 64)
    for i in range(len(points) - 1):
        # Gradient along line
        t = i / len(points)
        color = blend(LINK_CYAN, LINK_PURPLE, t)
        draw.line([points[i], points[i + 1]], fill=color, width=line_w)

    # Mid node
    mid_node_r = max(4, size // 28)
    draw_glow_circle(draw, (mid_x, end_y), mid_node_r, LINK_CYAN)
    draw.ellipse(
        [mid_x - mid_node_r, end_y - mid_node_r, mid_x + mid_node_r, end_y + mid_node_r],
        outline=LINK_CYAN,
        fill=(*DEEP_SPACE, 255),
        width=max(1, size // 128),
    )
    core_r = max(2, size // 70)
    draw.ellipse([mid_x - core_r, end_y - core_r, mid_x + core_r, end_y + core_r], fill=LINK_CYAN)

    # Far node
    far_r = max(6, size // 20)
    draw_glow_circle(draw, (end_x, end_y), far_r, LINK_BLUE)
    draw.ellipse(
        [end_x - far_r, end_y - far_r, end_x + far_r, end_y + far_r],
        outline=LINK_BLUE,
        fill=(*DEEP_SPACE, 255),
        width=max(1, size // 100),
    )
    far_core_r = max(3, size // 50)
    draw.ellipse([end_x - far_core_r, end_y - far_core_r, end_x + far_core_r, end_y + far_core_r], fill=LINK_BLUE)

    # Link between nodes
    link_w = max(2, size // 64)
    for i in range(mid_x + mid_node_r, end_x - far_r):
        t = (i - mid_x) / (end_x - mid_x)
        color = blend(LINK_CYAN, LINK_BLUE, t)
        draw.line([(i, end_y), (i + 1, end_y)], fill=color, width=link_w)

    return img


def generate_android():
    for folder, size in ANDROID_SIZES.items():
        out_dir = OUT_ANDROID / folder
        out_dir.mkdir(parents=True, exist_ok=True)
        img = render_icon(size)
        img.save(out_dir / "ic_launcher.png", "PNG")
        print(f"[android] {folder}/ic_launcher.png ({size}x{size})")


def generate_ios():
    OUT_IOS.mkdir(parents=True, exist_ok=True)
    for base, scale in IOS_SIZES:
        size = int(base * scale)
        img = render_icon(size)
        if base == 1024:
            name = "Icon-App-1024x1024@1x.png"
        else:
            name = f"Icon-App-{base}x{base}@{scale}x.png"
        img.save(OUT_IOS / name, "PNG")
        print(f"[ios] {name} ({size}x{size})")


def update_ios_contents():
    """Ensure Contents.json lists all icon sizes."""
    contents = {
        "images": [
            {"size": "20x20", "idiom": "iphone", "filename": "Icon-App-20x20@2x.png", "scale": "2x"},
            {"size": "20x20", "idiom": "iphone", "filename": "Icon-App-20x20@3x.png", "scale": "3x"},
            {"size": "29x29", "idiom": "iphone", "filename": "Icon-App-29x29@1x.png", "scale": "1x"},
            {"size": "29x29", "idiom": "iphone", "filename": "Icon-App-29x29@2x.png", "scale": "2x"},
            {"size": "29x29", "idiom": "iphone", "filename": "Icon-App-29x29@3x.png", "scale": "3x"},
            {"size": "40x40", "idiom": "iphone", "filename": "Icon-App-40x40@2x.png", "scale": "2x"},
            {"size": "40x40", "idiom": "iphone", "filename": "Icon-App-40x40@3x.png", "scale": "3x"},
            {"size": "60x60", "idiom": "iphone", "filename": "Icon-App-60x60@2x.png", "scale": "2x"},
            {"size": "60x60", "idiom": "iphone", "filename": "Icon-App-60x60@3x.png", "scale": "3x"},
            {"size": "20x20", "idiom": "ipad", "filename": "Icon-App-20x20@1x.png", "scale": "1x"},
            {"size": "20x20", "idiom": "ipad", "filename": "Icon-App-20x20@2x.png", "scale": "2x"},
            {"size": "29x29", "idiom": "ipad", "filename": "Icon-App-29x29@1x.png", "scale": "1x"},
            {"size": "29x29", "idiom": "ipad", "filename": "Icon-App-29x29@2x.png", "scale": "2x"},
            {"size": "40x40", "idiom": "ipad", "filename": "Icon-App-40x40@1x.png", "scale": "1x"},
            {"size": "40x40", "idiom": "ipad", "filename": "Icon-App-40x40@2x.png", "scale": "2x"},
            {"size": "76x76", "idiom": "ipad", "filename": "Icon-App-76x76@1x.png", "scale": "1x"},
            {"size": "76x76", "idiom": "ipad", "filename": "Icon-App-76x76@2x.png", "scale": "2x"},
            {"size": "83.5x83.5", "idiom": "ipad", "filename": "Icon-App-83.5x83.5@2x.png", "scale": "2x"},
            {"size": "1024x1024", "idiom": "ios-marketing", "filename": "Icon-App-1024x1024@1x.png", "scale": "1x"},
        ],
        "info": {"author": "xcode", "version": 1},
    }
    import json
    (OUT_IOS / "Contents.json").write_text(json.dumps(contents, indent=2))
    print("[ios] Contents.json updated")


def create_android_adaptive():
    """Create adaptive icon XML pointing to vector foreground and a color background."""
    anydpi = OUT_ANDROID / "mipmap-anydpi-v26"
    anydpi.mkdir(parents=True, exist_ok=True)
    drawable = ROOT / "app/android/app/src/main/res/drawable"
    drawable.mkdir(parents=True, exist_ok=True)

    # ic_launcher.xml
    launcher_xml = """<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@drawable/ic_launcher_background"/>
    <foreground android:drawable="@drawable/ic_launcher_foreground"/>
</adaptive-icon>
"""
    (anydpi / "ic_launcher.xml").write_text(launcher_xml)

    # background color
    bg_xml = """<?xml version="1.0" encoding="utf-8"?>
<shape xmlns:android="http://schemas.android.com/apk/res/android"
    android:shape="rectangle">
    <solid android:color="#0A0B0F"/>
</shape>
"""
    (drawable / "ic_launcher_background.xml").write_text(bg_xml)

    # foreground: reuse the SVG by placing it in drawable
    # Flutter apps can use vector drawable XML directly.
    fg_src = ROOT / "app/assets/brand/crosslink_logo.svg"
    fg_dst = drawable / "ic_launcher_foreground.xml"
    # Convert SVG to Android Vector Drawable is non-trivial; we'll copy the SVG
    # and let the user convert if needed, or rely on the PNG fallback.
    # Instead, we write a simplified vector drawable.
    fg_xml = """<?xml version="1.0" encoding="utf-8"?>
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="108dp"
    android:height="108dp"
    android:viewportWidth="512"
    android:viewportHeight="512">
    <path
        android:pathData="M0,0h512v512h-512z"
        android:fillColor="#0A0B0F"/>
    <path
        android:pathData="M88,140h336v216h-336z"
        android:fillColor="#1A1D28"
        android:strokeColor="#2A2E3D"
        android:strokeWidth="2"/>
    <path
        android:pathData="M88,140h336v44h-336z"
        android:fillColor="#222636"/>
    <path
        android:pathData="M116,198 l16,0 l0,26 l-16,0z"
        android:fillColor="#00E5FF"/>
    <path
        android:pathData="M360,320 C360,380 300,390 260,390"
        android:strokeColor="#00E5FF"
        android:strokeWidth="8"
        android:strokeLineCap="round"
        android:fillColor="#00000000"/>
    <path
        android:pathData="M278,390 L354,390"
        android:strokeColor="#2979FF"
        android:strokeWidth="5"
        android:strokeLineCap="round"
        android:fillColor="#00000000"/>
    <path
        android:pathData="M260,390m-18,0a18,18 0,1 1,36 0a18,18 0,1 1,-36 0"
        android:strokeColor="#00E5FF"
        android:strokeWidth="4"
        android:fillColor="#0A0B0F"/>
    <path
        android:pathData="M380,390m-26,0a26,26 0,1 1,52 0a26,26 0,1 1,-52 0"
        android:strokeColor="#2979FF"
        android:strokeWidth="5"
        android:fillColor="#0A0B0F"/>
    <path
        android:pathData="M260,390m-7,0a7,7 0,1 1,14 0a7,7 0,1 1,-14 0"
        android:fillColor="#00E5FF"/>
    <path
        android:pathData="M380,390m-10,0a10,10 0,1 1,20 0a10,10 0,1 1,-20 0"
        android:fillColor="#00E5FF"/>
</vector>
"""
    fg_dst.write_text(fg_xml)
    print("[android] adaptive icon XML created")


def main():
    generate_android()
    generate_ios()
    update_ios_contents()
    create_android_adaptive()
    print("\nDone. Launcher icons generated.")


if __name__ == "__main__":
    main()
