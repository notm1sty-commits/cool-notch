#!/usr/bin/env python3
"""Рисует иконку Halo и фон окна установщика.

Создаёт:
  Resources/AppIcon.png               — классическая иконка 1024×1024 (сетка macOS: «сквиркл» 824 pt с тенью);
  Resources/AppIcon.icon/             — документ Icon Composer для macOS 26: из него система сама делает
                                        светлую, тёмную, прозрачную и тонированную иконку;
  Resources/DMG/background.png, @2x   — фон окна DMG со стрелкой «перетащи в Программы».

Иконка: белый «сквиркл», чёрный островок (как чёлка) в светящемся контуре-ореоле,
внутри — обложка и эквалайзер. Градиент — два цвета, голубой → синий, смешиваются в OKLCH,
чтобы переход был чистым, без серой «грязи».

Запуск: python3 scripts/make_icon.py   (нужен Pillow)
"""
import json
import math
import os

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = os.path.join(os.path.dirname(__file__), "..")
RES = os.path.join(ROOT, "Resources")

HALO_FROM = "#4FD8FF"
HALO_TO = "#4A63FF"
TILE_TOP = (255, 255, 255)
TILE_BOTTOM = (230, 232, 239)
ISLAND_FILL = (6, 6, 8)

# Геометрия в координатах 1024×1024.
ISLAND = (252, 424, 772, 600)
HALO_PAD = 40     # от островка до внешнего края контура
HALO_WIDTH = 26
ART = (298, 466, 390, 558)
ART_RADIUS = 24
EQ_HEIGHTS = [0.45, 0.85, 0.62, 1.0, 0.5]
EQ_BAR, EQ_GAP, EQ_MAX, EQ_RIGHT = 14, 11, 74, 726

SS = 2            # рисуем в 2× и уменьшаем — ровные края
N = 1024 * SS


# MARK: - Цвет

def hexc(text):
    return tuple(int(text[i:i + 2], 16) for i in (1, 3, 5))


def _lin(c):
    c /= 255
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def _gam(c):
    c = max(0.0, min(1.0, c))
    return round(255 * (12.92 * c if c <= 0.0031308 else 1.055 * c ** (1 / 2.4) - 0.055))


def to_oklch(rgb):
    r, g, b = (_lin(v) for v in rgb)
    l = (0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b) ** (1 / 3)
    m = (0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b) ** (1 / 3)
    s = (0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b) ** (1 / 3)
    L = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
    A = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
    B = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
    return L, math.hypot(A, B), math.atan2(B, A)


def from_oklch(L, C, h):
    A, B = C * math.cos(h), C * math.sin(h)
    l = (L + 0.3963377774 * A + 0.2158037573 * B) ** 3
    m = (L - 0.1055613458 * A - 0.0638541728 * B) ** 3
    s = (L - 0.0894841775 * A - 1.2914855480 * B) ** 3
    return (
        _gam(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
        _gam(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
        _gam(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s),
    )


def mix(c0, c1, u):
    """Смешивание в OKLCH — без серой «грязи» между цветами."""
    L0, C0, h0 = to_oklch(c0)
    L1, C1, h1 = to_oklch(c1)
    dh = (h1 - h0 + math.pi) % (2 * math.pi) - math.pi
    return from_oklch(L0 + (L1 - L0) * u, C0 + (C1 - C0) * u, h0 + dh * u)


def lerp(a, b, t):
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(3))


# MARK: - Рисование

def sc(*values, k=SS):
    return tuple(int(v * k) for v in values)


def linear(box, size, c0=HALO_FROM, c1=HALO_TO):
    """Двухцветный градиент по рамке box (слева-сверху → справа-снизу), плавно продолжен за её края."""
    w, h = size
    x0, y0, x1, y1 = box
    a, z = hexc(c0), hexc(c1)
    R = 256
    small = Image.new("RGB", (R, R))
    px = small.load()
    for y in range(R):
        for x in range(R):
            X, Y = x / (R - 1) * w, y / (R - 1) * h
            t = (X - x0) / (x1 - x0) * 0.65 + (Y - y0) / (y1 - y0) * 0.35
            px[x, y] = mix(a, z, max(0.0, min(1.0, t)))
    return small.resize((w, h), Image.BICUBIC).convert("RGBA")


def vertical(size, top, bottom):
    w, h = size
    img = Image.new("RGB", (1, h))
    for y in range(h):
        img.putpixel((0, y), lerp(top, bottom, y / max(h - 1, 1)))
    return img.resize((w, h)).convert("RGBA")


def rounded_mask(size, box, radius, outline=None):
    m = Image.new("L", size, 0)
    if outline:
        ImageDraw.Draw(m).rounded_rectangle(box, radius, outline=255, width=outline)
    else:
        ImageDraw.Draw(m).rounded_rectangle(box, radius, fill=255)
    return m


def glow(dst, colors, mask, blur, strength):
    alpha = mask.filter(ImageFilter.GaussianBlur(blur)).point(lambda v: int(min(255, v * strength)))
    layer = colors.copy()
    layer.putalpha(alpha)
    dst.alpha_composite(layer)


def halo_box(k=SS):
    x0, y0, x1, y1 = ISLAND
    return sc(x0 - HALO_PAD, y0 - HALO_PAD, x1 + HALO_PAD, y1 + HALO_PAD, k=k)


def eq_bars():
    """Рамки столбиков эквалайзера в координатах 1024."""
    total = len(EQ_HEIGHTS) * EQ_BAR + (len(EQ_HEIGHTS) - 1) * EQ_GAP
    x0 = EQ_RIGHT - total
    cy = (ISLAND[1] + ISLAND[3]) / 2
    bars = []
    for i, h in enumerate(EQ_HEIGHTS):
        x = x0 + i * (EQ_BAR + EQ_GAP)
        half = EQ_MAX * h / 2
        bars.append((x, cy - half, x + EQ_BAR, cy + half))
    return bars, (x0, cy - EQ_MAX / 2, x0 + total, cy + EQ_MAX / 2)


def draw_foreground(art, k=SS):
    """Ореол, островок, обложка и эквалайзер — поверх уже залитого фона."""
    size = art.size
    hb = halo_box(k)
    ring = rounded_mask(size, hb, (hb[3] - hb[1]) // 2, outline=HALO_WIDTH * k)
    colors = linear(hb, size)
    glow(art, colors, ring, 60 * k, 0.4)
    art.paste(colors, (0, 0), ring)

    ib = sc(*ISLAND, k=k)
    art.paste(Image.new("RGBA", size, (*ISLAND_FILL, 255)), (0, 0), rounded_mask(size, ib, (ib[3] - ib[1]) // 2))

    ab = sc(*ART, k=k)
    art.paste(linear(ab, size), (0, 0), rounded_mask(size, ab, ART_RADIUS * k))

    bars, frame = eq_bars()
    mask = Image.new("L", size, 0)
    draw = ImageDraw.Draw(mask)
    for bar in bars:
        draw.rounded_rectangle(sc(*bar, k=k), EQ_BAR * k // 2, fill=255)
    art.paste(linear(sc(*frame, k=k), size), (0, 0), mask)


def render_png(path):
    size = (N, N)
    canvas = Image.new("RGBA", size, (0, 0, 0, 0))

    # Сквиркл по сетке macOS: 824×824 с отступом 100, радиус ~185, мягкая тень.
    box = sc(100, 100, 924, 924)
    radius = 185 * SS
    shadow = Image.new("RGBA", size, (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle((box[0], box[1] + 14 * SS, box[2], box[3] + 14 * SS), radius, fill=(0, 0, 0, 110))
    canvas.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(22 * SS)))

    art = vertical(size, TILE_TOP, TILE_BOTTOM)
    draw_foreground(art)

    clipped = Image.new("RGBA", size, (0, 0, 0, 0))
    clipped.paste(art, (0, 0), rounded_mask(size, box, radius))
    canvas.alpha_composite(clipped)
    canvas.resize((1024, 1024), Image.LANCZOS).save(path)


# MARK: - Icon Composer

def write_icon_composer(folder):
    """Документ Icon Composer: белый фон (тёмный — в тёмном оформлении) и слои.
    Ореол стеклянный, остальное плоское; тени и блики система добавит сама."""
    assets = os.path.join(folder, "Assets")
    os.makedirs(assets, exist_ok=True)
    for name in os.listdir(assets):
        os.remove(os.path.join(assets, name))

    def svg(body, defs=""):
        return (
            '<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">\n'
            f"  <defs>{defs}</defs>\n  {body}\n</svg>\n"
        )

    def gradient(box):
        x0, y0, x1, y1 = box
        stops = "".join(
            f'<stop offset="{i / 8:.3f}" stop-color="rgb{mix(hexc(HALO_FROM), hexc(HALO_TO), i / 8)}"/>'
            for i in range(9)
        )
        return f'<linearGradient id="g" gradientUnits="userSpaceOnUse" x1="{x0}" y1="{y0}" x2="{x1}" y2="{y1}">{stops}</linearGradient>'

    def pill(box, extra):
        x0, y0, x1, y1 = box
        return f'<rect x="{x0}" y="{y0}" width="{x1 - x0}" height="{y1 - y0}" {extra}/>'

    hb = halo_box(1)
    half = HALO_WIDTH / 2
    inner = (hb[0] + half, hb[1] + half, hb[2] - half, hb[3] - half)
    files = {
        "halo.svg": svg(pill(inner, f'rx="{(inner[3] - inner[1]) / 2}" fill="none" stroke="url(#g)" stroke-width="{HALO_WIDTH}"'), gradient(hb)),
        "island.svg": svg(pill(ISLAND, f'rx="{(ISLAND[3] - ISLAND[1]) / 2}" fill="#060608"')),
        "cover.svg": svg(pill(ART, f'rx="{ART_RADIUS}" fill="url(#g)"'), gradient(ART)),
    }
    bars, frame = eq_bars()
    files["equalizer.svg"] = svg("".join(pill(bar, f'rx="{EQ_BAR / 2}" fill="url(#g)"') for bar in bars), gradient(frame))
    for name, text in files.items():
        with open(os.path.join(assets, name), "w") as f:
            f.write(text)

    def srgb(c):
        return "srgb:" + ",".join(f"{v / 255:.5f}" for v in c) + ",1.00000"

    def layer(name, glass):
        return {
            "image-name": f"{name}.svg",
            "name": name,
            "glass": glass,
            "position": {"scale": 1, "translation-in-points": [0, 0]},
        }

    document = {
        "fill-specializations": [
            {"value": {"linear-gradient": [srgb(TILE_TOP), srgb(TILE_BOTTOM)]}},
            {"appearance": "dark", "value": {"linear-gradient": [srgb((44, 46, 56)), srgb((18, 19, 24))]}},
        ],
        "groups": [
            {
                # Верхняя группа — то, что «играет» в островке.
                "layers": [layer("equalizer", False), layer("cover", False)],
                "shadow": {"kind": "none", "opacity": 0},
                "translucency": {"enabled": False, "value": 0},
            },
            {
                "layers": [layer("island", False)],
                "shadow": {"kind": "neutral", "opacity": 0.35},
                "translucency": {"enabled": False, "value": 0},
            },
            {
                "layers": [layer("halo", True)],
                "shadow": {"kind": "layer-color", "opacity": 0.5},
                "translucency": {"enabled": True, "value": 0.15},
            },
        ],
        "supported-platforms": {"squares": "shared"},
    }
    with open(os.path.join(folder, "icon.json"), "w") as f:
        json.dump(document, f, indent=2, ensure_ascii=False)
        f.write("\n")


# MARK: - Фон установщика

def render_dmg_background(path, scale):
    """Фон окна установщика 660×400. Светлый: на картинке Finder всегда пишет подписи тёмным текстом."""
    w, h = 660 * scale, 400 * scale
    img = vertical((w, h), (252, 252, 254), (236, 238, 244))

    # Еле заметный ореол позади иконок — те же цвета, что у иконки.
    frame = sc(110, 100, 550, 280, k=scale)
    ring = rounded_mask((w, h), frame, 90 * scale, outline=22 * scale)
    glow(img, linear(frame, (w, h)), ring, 50 * scale, 0.3)

    draw = ImageDraw.Draw(img)
    # Стрелка: от иконки приложения (x=170) к «Программам» (x=490), на уровне иконок (y=190).
    y = 190 * scale
    x0, x1 = 252 * scale, 408 * scale
    arrow = (120, 128, 150, 255)
    dash, gap = 10 * scale, 8 * scale
    x = x0
    while x < x1 - 18 * scale:
        draw.line((x, y, min(x + dash, x1 - 18 * scale), y), fill=arrow, width=3 * scale)
        x += dash + gap
    head = 14 * scale
    draw.line((x1 - head, y - head, x1, y), fill=arrow, width=3 * scale)
    draw.line((x1 - head, y + head, x1, y), fill=arrow, width=3 * scale)

    font = None
    for candidate in [
        "/System/Library/Fonts/SFNS.ttf",
        "/System/Library/Fonts/Helvetica.ttc",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    ]:
        if os.path.exists(candidate):
            font = ImageFont.truetype(candidate, 14 * scale)
            break
    text = "Перетащи Halo в папку «Программы»"
    if font is not None:
        box = draw.textbbox((0, 0), text, font=font)
        draw.text(((w - (box[2] - box[0])) / 2, 322 * scale), text, font=font, fill=(110, 116, 134, 255))
    img.convert("RGB").save(path)


def main():
    render_png(os.path.join(RES, "AppIcon.png"))
    write_icon_composer(os.path.join(RES, "AppIcon.icon"))
    os.makedirs(os.path.join(RES, "DMG"), exist_ok=True)
    render_dmg_background(os.path.join(RES, "DMG", "background.png"), 1)
    render_dmg_background(os.path.join(RES, "DMG", "background@2x.png"), 2)
    print("готово")


if __name__ == "__main__":
    main()
