#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Генерирует AppIcon.icns для PDFPrintPrepare.app (требует Pillow)."""
import subprocess
import sys
import tempfile
from pathlib import Path

try:
    from PIL import Image, ImageDraw
except ImportError:
    sys.exit("Нужен Pillow: pip3 install pillow")

OUT = Path(__file__).resolve().parent.parent / "app" / "AppIcon.icns"


def rounded(draw, box, r, fill):
    draw.rounded_rectangle(box, radius=r, fill=fill)


def render(size=1024):
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    s = size / 1024

    # фон-плитка с градиентом
    bg = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    grad = Image.new("RGBA", (size, size))
    gd = ImageDraw.Draw(grad)
    top, bot = (0x2F, 0x6B, 0xF0), (0x1B, 0x3E, 0x9E)
    for y in range(size):
        k = y / size
        gd.line([(0, y), (size, y)],
                fill=(int(top[0] * (1 - k) + bot[0] * k),
                      int(top[1] * (1 - k) + bot[1] * k),
                      int(top[2] * (1 - k) + bot[2] * k), 255))
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, size - 1, size - 1],
                                           radius=int(228 * s), fill=255)
    bg.paste(grad, (0, 0), mask)
    img.alpha_composite(bg)
    d = ImageDraw.Draw(img)

    # лист бумаги
    lx0, ly0, lx1, ly1 = int(212 * s), int(150 * s), int(720 * s), int(880 * s)
    d.rounded_rectangle([lx0, ly0, lx1, ly1], radius=int(28 * s), fill=(255, 255, 255, 255))
    # загнутый угол
    d.polygon([(int(596 * s), ly0), (lx1, int(274 * s)), (lx1 - int(96 * s), ly0)],
              fill=(0xD8, 0xE2, 0xF5, 255))

    # строки текста
    for i, y in enumerate(range(330, 660, 62)):
        w = int((400 if i % 3 else 300) * s)
        d.rounded_rectangle([int(292 * s), int(y * s), int(292 * s) + w, int((y + 18) * s)],
                            radius=int(9 * s), fill=(0xC3, 0xCE, 0xE0, 255))

    # бейджи A4 / A3
    def badge(text, x, y, w, h, color):
        d.rounded_rectangle([x, y, x + w, y + h], radius=int(20 * s), fill=color)
        # текст рисуем крупно через отдельный слой
        tw = int(w * (0.62 if len(text) == 3 else 0.5))
        bh = int(h * 0.52)
        ty = y + (h - bh) // 2
        tx = x + (w - int(tw * 1.32)) // 2
        for ch_i, ch in enumerate(text):
            pass
        _ = (tw, bh, ty, tx)

    b1 = [int(150 * s), int(700 * s), int(400 * s), int(828 * s)]
    b2 = [int(420 * s), int(700 * s), int(670 * s), int(828 * s)]
    d.rounded_rectangle(b1, radius=int(20 * s), fill=(0x22, 0xC5, 0x5E, 255))
    d.rounded_rectangle(b2, radius=int(20 * s), fill=(0xFF, 0x9F, 0x0A, 255))

    # подписи A4 / A3 крупным шрифтом
    from PIL import ImageFont
    font = None
    for cand in ["/System/Library/Fonts/Supplemental/Arial Bold.ttf",
                 "/System/Library/Fonts/Helvetica.ttc",
                 "/Library/Fonts/Arial Bold.ttf"]:
        try:
            font = ImageFont.truetype(cand, int(104 * s))
            break
        except Exception:
            continue
    if font:
        for text, box in (("A4", b1), ("A3", b2)):
            tw = d.textlength(text, font=font)
            tx = box[0] + (box[2] - box[0] - tw) / 2
            ty = box[1] + (box[3] - box[1]) / 2 - int(58 * s)
            d.text((tx, ty), text, font=font, fill=(255, 255, 255, 255))

    return img


def main():
    tmp = Path(tempfile.mkdtemp())
    iconset = tmp / "AppIcon.iconset"
    iconset.mkdir()
    base = render(1024)
    for sz in (16, 32, 64, 128, 256, 512, 1024):
        base.resize((sz, sz), Image.LANCZOS).save(iconset / f"icon_{sz}x{sz}.png")
        if sz <= 512:
            base.resize((sz * 2, sz * 2), Image.LANCZOS).save(iconset / f"icon_{sz}x{sz}@2x.png")
    subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(OUT)], check=True)
    print(f"✓ {OUT}")


if __name__ == "__main__":
    main()
