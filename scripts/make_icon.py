#!/usr/bin/env python3
"""Рисует иконку приложения (Resources/AppIcon.png, 1024×1024). Нужен Pillow."""
import math
import sys
from PIL import Image, ImageDraw, ImageFilter

S = 4  # суперсэмплинг для гладких краёв
W = 1024 * S


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(len(a)))


def gradient(size, top, bottom):
    img = Image.new("RGBA", (size, size))
    px = img.load()
    for y in range(size):
        c = lerp(top, bottom, y / (size - 1))
        for x in range(size):
            px[x, y] = c
    return img


def main(out):
    small = 256
    # Фон: глубокий фиолетово-синий градиент с мягким бликом.
    bg = gradient(small, (58, 28, 120, 255), (12, 10, 34, 255)).resize((W, W), Image.BICUBIC)
    glow = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    gd.ellipse([W * 0.12, W * 0.30, W * 0.88, W * 0.95], fill=(255, 70, 160, 120))
    glow = glow.filter(ImageFilter.GaussianBlur(W * 0.09))
    bg = Image.alpha_composite(bg, glow)

    # Маска «squircle» в стиле macOS (поле 100px с каждой стороны).
    mask = Image.new("L", (W, W), 0)
    md = ImageDraw.Draw(mask)
    m = 100 * S
    md.rounded_rectangle([m, m, W - m, W - m], radius=185 * S, fill=255)

    icon = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    icon.paste(bg, (0, 0), mask)
    d = ImageDraw.Draw(icon)

    # Чёлка: чёрная «капля», свисающая с верхнего края (обрезается по форме иконки).
    nx0, nx1 = 262 * S, 762 * S
    ny0, ny1 = m, 430 * S
    layer = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    ld = ImageDraw.Draw(layer)
    ld.rounded_rectangle([nx0, ny0 - 200 * S, nx1, ny1 + 24 * S], radius=110 * S, fill=(0, 0, 0, 170))
    layer = layer.filter(ImageFilter.GaussianBlur(30 * S))
    ld = ImageDraw.Draw(layer)
    ld.rounded_rectangle([nx0, ny0 - 200 * S, nx1, ny1], radius=100 * S, fill=(0, 0, 0, 255))
    # Вогнутые «плечи», которыми чёлка переходит в верхний край.
    r = 46 * S
    for x0, cx in ((nx0 - r, nx0 - r), (nx1, nx1 + r)):
        ld.rectangle([x0, ny0, x0 + r, ny0 + r], fill=(0, 0, 0, 255))
        ld.ellipse([cx - r, ny0, cx + r, ny0 + 2 * r], fill=(0, 0, 0, 0))
    clipped = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    clipped.paste(layer, (0, 0), Image.composite(layer.getchannel("A"), Image.new("L", (W, W), 0), mask))
    icon = Image.alpha_composite(icon, clipped)
    d = ImageDraw.Draw(icon)

    # Обложка альбома слева.
    ax0, ay0, a = 312 * S, 236 * S, 140 * S
    art = gradient(64, (255, 160, 60, 255), (240, 50, 140, 255)).resize((a, a), Image.BICUBIC)
    amask = Image.new("L", (a, a), 0)
    ImageDraw.Draw(amask).rounded_rectangle([0, 0, a, a], radius=34 * S, fill=255)
    icon.paste(art, (ax0, ay0), amask)
    d = ImageDraw.Draw(icon)
    # Нота на обложке.
    cx, cy = ax0 + a // 2, ay0 + a // 2
    d.ellipse([cx - 30 * S, cy + 4 * S, cx + 6 * S, cy + 34 * S], fill=(255, 255, 255, 235))
    d.rectangle([cx - 2 * S, cy - 44 * S, cx + 8 * S, cy + 22 * S], fill=(255, 255, 255, 235))
    d.polygon([(cx + 8 * S, cy - 44 * S), (cx + 40 * S, cy - 26 * S), (cx + 40 * S, cy - 8 * S), (cx + 8 * S, cy - 24 * S)], fill=(255, 255, 255, 235))

    # Эквалайзер справа.
    heights = [70, 120, 92, 140, 60]
    bw, gap = 22 * S, 16 * S
    bx = 512 * S
    base = ay0 + a // 2
    for i, h in enumerate(heights):
        h *= S
        t = i / (len(heights) - 1)
        col = lerp((90, 220, 255, 255), (255, 90, 200, 255), t)
        x = bx + i * (bw + gap)
        d.rounded_rectangle([x, base - h // 2, x + bw, base + h // 2], radius=bw // 2, fill=col)

    # Блик на нижней части иконки.
    icon = icon.resize((1024, 1024), Image.LANCZOS)
    icon.save(out)
    print("saved", out)


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "Resources/AppIcon.png")
