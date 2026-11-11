#!/usr/bin/env python3
"""Draws the SoundPath app icon and writes SoundPath/Assets.xcassets/AppIcon.appiconset."""
import json
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter

S = 2048  # master canvas

def master() -> Image.Image:
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    # Rounded-square background with a vertical blue → indigo gradient (macOS icon grid: ~824/1024 body).
    body = int(S * 0.8047); off = (S - body) // 2; radius = int(body * 0.2237)
    grad = Image.new("RGBA", (body, body))
    gd = ImageDraw.Draw(grad)
    top, bot = (64, 156, 255), (88, 64, 214)
    for y in range(body):
        t = y / (body - 1)
        gd.line([(0, y), (body, y)], fill=tuple(int(top[i] + (bot[i] - top[i]) * t) for i in range(3)) + (255,))
    mask = Image.new("L", (body, body), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, body - 1, body - 1], radius, fill=255)
    # soft drop shadow
    shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle([off, off + 20, off + body, off + body + 20], radius, fill=(0, 0, 0, 90))
    img.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(28)))
    img.paste(grad, (off, off), mask)

    # Foreground: a rounded "path" of equalizer bars (a sound level path), white with slight transparency.
    d = ImageDraw.Draw(img)
    bars = [0.30, 0.52, 0.82, 0.60, 0.40, 0.70, 0.46]
    n = len(bars); bw = int(body * 0.072); gap = int(body * 0.047)
    total = n * bw + (n - 1) * gap
    x0 = off + (body - total) // 2
    cy = off + body // 2
    for i, h in enumerate(bars):
        bh = int(body * 0.56 * h)
        x = x0 + i * (bw + gap)
        d.rounded_rectangle([x, cy - bh // 2, x + bw, cy + bh // 2], bw // 2, fill=(255, 255, 255, 245))
    return img

SIZES = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]

def main():
    out = Path(__file__).resolve().parent.parent / "SoundPath/Assets.xcassets"
    icon = out / "AppIcon.appiconset"
    icon.mkdir(parents=True, exist_ok=True)
    m = master()
    images = []
    for pt, scale in SIZES:
        px = pt * scale
        name = f"icon_{pt}x{pt}{'@2x' if scale == 2 else ''}.png"
        m.resize((px, px), Image.LANCZOS).save(icon / name)
        images.append({"filename": name, "idiom": "mac", "scale": f"{scale}x", "size": f"{pt}x{pt}"})
    (icon / "Contents.json").write_text(json.dumps({"images": images, "info": {"author": "xcode", "version": 1}}, indent=2))
    (out / "Contents.json").write_text(json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2))
    m.resize((512, 512), Image.LANCZOS).save(Path(__file__).resolve().parent / "icon_preview.png")

if __name__ == "__main__":
    main()
