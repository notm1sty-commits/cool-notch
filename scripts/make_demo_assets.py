import math, random, sys, io, base64
from PIL import Image, ImageDraw, ImageFilter, ImageChops
out = sys.argv[1]
random.seed(7)

def grain(img, amount=10):
    w, h = img.size
    noise = Image.effect_noise((w, h), 64).convert("L")
    noise = noise.point(lambda v: 128 + (v - 128) * amount / 64)
    rgb = img.convert("RGB")
    n3 = Image.merge("RGB", (noise, noise, noise))
    return ImageChops.overlay(rgb, n3) if amount else rgb

def vgrad(w, h, stops):
    img = Image.new("RGB", (w, h))
    px = img.load()
    for y in range(h):
        t = y / (h - 1)
        for i in range(len(stops) - 1):
            p0, c0 = stops[i]; p1, c1 = stops[i + 1]
            if p0 <= t <= p1:
                f = (t - p0) / (p1 - p0 or 1)
                c = tuple(int(c0[k] + (c1[k] - c0[k]) * f) for k in range(3))
                break
        for x in range(w):
            px[x, y] = c
    return img

# ---------- wallpaper (macOS-like flowing waves) ----------
W, H = 1520, 544
wall = vgrad(W, H, [(0, (10, 18, 56)), (0.45, (38, 40, 140)), (1, (92, 50, 150))])
layer = Image.new("RGB", (W, H), (0, 0, 0))
def wave(color, base, amp, freq, phase, alpha):
    m = Image.new("L", (W, H), 0); d = ImageDraw.Draw(m)
    pts = [(x, base + amp * math.sin(x / W * freq * 2 * math.pi + phase) + amp * 0.45 * math.sin(x / W * freq * 3.7 + phase * 1.7)) for x in range(0, W + 8, 8)]
    d.polygon(pts + [(W, H), (0, H)], fill=alpha)
    m = m.filter(ImageFilter.GaussianBlur(18))
    col = Image.new("RGB", (W, H), color)
    return col, m
for color, base, amp, freq, ph, a in [
    ((70, 90, 230), 250, 60, 1.1, 0.4, 200),
    ((140, 80, 235), 320, 55, 0.9, 2.1, 210),
    ((235, 110, 170), 380, 50, 1.2, 4.0, 220),
    ((255, 160, 120), 445, 40, 1.0, 1.0, 230),
    ((255, 205, 160), 505, 28, 1.4, 3.0, 235),
]:
    col, m = wave(color, base, amp, freq, ph, a)
    wall = Image.composite(col, wall, m)
glow = Image.new("RGB", (W, H), (0, 0, 0)); gd = ImageDraw.Draw(glow)
gd.ellipse([W*0.55, -H*0.4, W*1.2, H*0.5], fill=(90, 120, 255))
glow = glow.filter(ImageFilter.GaussianBlur(120))
wall = ImageChops.screen(wall, glow.point(lambda v: v * 0.55))
wall = grain(wall, 6)
wall.save(f"{out}/wall.jpg", quality=84, optimize=True, progressive=True)

# ---------- album covers ----------
S = 420
def cover_sunset():
    img = vgrad(S, S, [(0, (255, 196, 120)), (0.45, (255, 120, 120)), (0.62, (170, 70, 140)), (1, (40, 20, 70))])
    d = ImageDraw.Draw(img, "RGBA")
    sun = Image.new("RGB", (S, S)); sd = ImageDraw.Draw(sun)
    sd.ellipse([S*0.3, S*0.28, S*0.7, S*0.68], fill=(255, 236, 190))
    halo = sun.filter(ImageFilter.GaussianBlur(40))
    img = ImageChops.screen(img, halo.point(lambda v: v * 0.6))
    img.paste(Image.new("RGB", (S, S), (255, 238, 200)), (0, 0), Image.new("L", (S, S), 0))
    m = Image.new("L", (S, S), 0); ImageDraw.Draw(m).ellipse([S*0.33, S*0.31, S*0.67, S*0.65], fill=255)
    img = Image.composite(Image.new("RGB", (S, S), (255, 240, 205)), img, m.filter(ImageFilter.GaussianBlur(1)))
    sea = vgrad(S, int(S*0.4), [(0, (110, 50, 120)), (1, (25, 15, 50))])
    img.paste(sea, (0, int(S*0.6)))
    d = ImageDraw.Draw(img, "RGBA")
    for i in range(14):
        y = S*0.62 + i * i * 0.85
        w = S*0.18 * (1 - i/16)
        d.rounded_rectangle([S/2 - w, y, S/2 + w, y + 2 + i*0.25], radius=2, fill=(255, 210, 170, int(200 - i*12)))
    return grain(img, 9)

def cover_city():
    img = vgrad(S, S, [(0, (22, 10, 60)), (0.55, (90, 20, 120)), (0.75, (230, 60, 160)), (1, (30, 10, 50))])
    d = ImageDraw.Draw(img, "RGBA")
    glow = Image.new("RGB", (S, S)); ImageDraw.Draw(glow).ellipse([S*0.22, S*0.24, S*0.78, S*0.8], fill=(255, 70, 190))
    img = ImageChops.screen(img, glow.filter(ImageFilter.GaussianBlur(40)).point(lambda v: v*0.6))
    sun = vgrad(S, S, [(0, (255, 214, 110)), (0.5, (255, 120, 150)), (0.75, (240, 60, 170)), (1, (240, 60, 170))])
    mask = Image.new("L", (S, S), 0); md = ImageDraw.Draw(mask)
    md.ellipse([S*0.3, S*0.26, S*0.7, S*0.66], fill=255)
    for i in range(7):
        y = S*0.47 + i * 10
        md.rectangle([0, y, S, y + 2 + i*0.9], fill=0)
    img = Image.composite(sun, img, mask)
    d = ImageDraw.Draw(img, "RGBA")
    x = 0
    random.seed(3)
    while x < S:
        bw = random.randint(26, 60); bh = random.randint(70, 190)
        d.rectangle([x, S - bh, x + bw, S], fill=(14, 8, 34))
        for wy in range(S - bh + 10, S - 6, 12):
            for wx in range(x + 5, x + bw - 6, 9):
                if random.random() < 0.35:
                    c = random.choice([(255, 200, 120), (120, 220, 255), (255, 120, 220)])
                    d.rectangle([wx, wy, wx + 4, wy + 5], fill=c + (220,))
        x += bw + random.randint(2, 6)
    return grain(img, 10)

def cover_aurora():
    img = vgrad(S, S, [(0, (4, 10, 30)), (0.7, (8, 40, 70)), (1, (6, 16, 34))])
    random.seed(11)
    d = ImageDraw.Draw(img, "RGBA")
    for _ in range(120):
        x, y = random.randint(0, S), random.randint(0, int(S*0.6)); r = random.choice([1, 1, 1, 2])
        d.ellipse([x, y, x + r, y + r], fill=(255, 255, 255, random.randint(80, 220)))
    ribbons = Image.new("RGB", (S, S), (0, 0, 0)); rd = ImageDraw.Draw(ribbons)
    for k, col in enumerate([(60, 255, 170), (80, 200, 255), (170, 120, 255)]):
        pts = []
        for x in range(-20, S + 20, 6):
            y = S*0.32 + k*26 + 40*math.sin(x/S*4 + k) + 18*math.sin(x/S*9 + k*2)
            pts.append((x, y))
        for i in range(len(pts) - 1):
            rd.line([pts[i], pts[i+1]], fill=col, width=26 - k*5)
    ribbons = ribbons.filter(ImageFilter.GaussianBlur(14))
    img = ImageChops.screen(img, ribbons.point(lambda v: v*0.85))
    d = ImageDraw.Draw(img)
    d.polygon([(0, S), (0, S*0.78), (S*0.18, S*0.62), (S*0.35, S*0.76), (S*0.55, S*0.58), (S*0.78, S*0.74), (S, S*0.64), (S, S)], fill=(6, 12, 26))
    return grain(img, 8)

for name, fn in [("c1", cover_sunset), ("c2", cover_city), ("c3", cover_aurora)]:
    im = fn()
    im.save(f"{out}/{name}.jpg", quality=86, optimize=True, progressive=True)
print("ok")
