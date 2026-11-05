#!/usr/bin/env python3
"""Renders the Moonrise disk image background at 1x and 2x with ordered dither on each image's own pixel grid.

Usage: Tools/render_disk_image_background.py [<output folder>]
Writes DiskImageBackground.png and DiskImageBackground@2x.png, by default into Packaging/. The shipped art is the
steps-stars variant: three stepped chevrons and sparse stars.
Geometry is in points: a 640 x 400 window, 128 pt icons centered at (176, 190) and (464, 190), and the black
Finder labels at y 262-294, whose text areas stay one smooth light color.
"""
import math
import pathlib
import struct
import sys
import zlib

root = pathlib.Path(__file__).resolve().parent.parent
WIDTH, HEIGHT = 640, 400

# The app's moon texture: equirectangular albedo in the red channel, row 0 at the south pole.
TEXTURE_WIDTH, TEXTURE_HEIGHT = 1024, 512
texture = (root / "Sources" / "MoonRendering" / "Resources" / "MoonSurface.rgba").read_bytes()[: TEXTURE_WIDTH * TEXTURE_HEIGHT * 4]


def albedo(longitude, latitude):
    """Bilinear albedo, 0 to 1, for a longitude and latitude in radians."""
    u = (longitude / (2 * math.pi) + 0.5) % 1.0 * TEXTURE_WIDTH - 0.5
    v = min(max((latitude / math.pi + 0.5) * TEXTURE_HEIGHT - 0.5, 0), TEXTURE_HEIGHT - 1.001)
    x0, y0 = int(math.floor(u)), int(v)
    fx, fy = u - x0, v - y0
    x0 %= TEXTURE_WIDTH
    x1 = (x0 + 1) % TEXTURE_WIDTH
    y1 = y0 + 1

    def sample(x, y):
        return texture[(y * TEXTURE_WIDTH + x) * 4] / 255.0

    top = sample(x0, y0) * (1 - fx) + sample(x1, y0) * fx
    bottom = sample(x0, y1) * (1 - fx) + sample(x1, y1) * fx
    return top * (1 - fy) + bottom * fy


BAYER = [[0, 32, 8, 40, 2, 34, 10, 42], [48, 16, 56, 24, 50, 18, 58, 26], [12, 44, 4, 36, 14, 46, 6, 38],
         [60, 28, 52, 20, 62, 30, 54, 22], [3, 35, 11, 43, 1, 33, 9, 41], [51, 19, 59, 27, 49, 17, 57, 25],
         [15, 47, 7, 39, 13, 45, 5, 37], [63, 31, 55, 23, 61, 29, 53, 21]]


def threshold(x, y):
    return (BAYER[y % 8][x % 8] + 0.5) / 64.0


def mix(low, high, amount):
    return tuple(round(a + (b - a) * amount) for a, b in zip(low, high))


def smoothstep(edge0, edge1, value):
    t = min(max((value - edge0) / (edge1 - edge0), 0.0), 1.0)
    return t * t * (3 - 2 * t)


SKY = (12, 12, 14)
MOON_INK = (214, 214, 209)
GROUND_DARK = (150, 149, 144)
GROUND_LIGHT = (234, 233, 227)
CHEVRON = (196, 196, 192)

# The near lunar body: a large disc whose top edge is the horizon behind the icons.
GROUND_CENTER = (330.0, 1560.0)
GROUND_RADIUS = 1346.0
# The far moon, cropped off the top right.
MOON_CENTER = (578.0, -36.0)
MOON_RADIUS = 240.0
# Sunlight from the upper left, slightly in front. Normal space: x right, y up, z toward the viewer.
SUN = (-0.55, 0.38, 0.74)
length = math.sqrt(sum(c * c for c in SUN))
SUN = tuple(c / length for c in SUN)

LABEL_BOXES = [(96, 262, 256, 294), (384, 262, 544, 294)]
# Craters read as smudges at this size, so the ground carries only tone and faint albedo.
CRATERS = []
STARS = [(38, 22, 0.9), (71, 61, 0.5), (112, 18, 0.7), (152, 48, 0.4), (19, 97, 0.6), (201, 30, 0.8),
         (236, 74, 0.45), (128, 102, 0.35), (276, 16, 0.55), (54, 139, 0.4), (309, 58, 0.6), (183, 128, 0.3),
         (94, 166, 0.35), (338, 101, 0.4), (24, 178, 0.5)]


def label_mask(u, v):
    """1 inside a label text area, falling to 0 over about 30 pt around it."""
    best = 0.0
    for left, top, right, bottom in LABEL_BOXES:
        dx = max(left - u, 0.0, u - right)
        dy = max(top - v, 0.0, v - bottom)
        best = max(best, 1.0 - smoothstep(0.0, 34.0, math.hypot(dx * 0.8, dy * 1.4)))
    return best


def moon_value(u, v):
    """Brightness 0 to 1 of the far moon at a point, or None outside its disc."""
    dx, dy = (u - MOON_CENTER[0]) / MOON_RADIUS, (MOON_CENTER[1] - v) / MOON_RADIUS
    r2 = dx * dx + dy * dy
    if r2 >= 1.0:
        return None
    nz = math.sqrt(1.0 - r2)
    # Turn the disc in its own plane so the near side's seas, normally upper left, fall in the visible lower left.
    roll = math.radians(-105)
    rx = dx * math.cos(roll) - dy * math.sin(roll)
    ry = dx * math.sin(roll) + dy * math.cos(roll)
    longitude = math.atan2(rx, nz)
    latitude = math.asin(max(-1.0, min(1.0, ry)))
    surface = smoothstep(0.34, 0.74, albedo(longitude, latitude))
    light = max(dx * SUN[0] + dy * SUN[1] + nz * SUN[2], 0.0)
    value = 0.62 * (0.13 + 0.87 * surface) * (0.35 + 0.65 * light)
    # A crisp lit rim on the sunward edge.
    sunward = (dx * SUN[0] + dy * SUN[1]) / math.hypot(SUN[0], SUN[1])
    if r2 > 0.985 and sunward > 0:
        value = max(value, 0.9 * smoothstep(0.0, 0.8, sunward))
    return value


def ground_value(u, v):
    """Ground blend toward GROUND_LIGHT, 0 to 1, or None above the horizon."""
    distance = math.hypot(u - GROUND_CENTER[0], v - GROUND_CENTER[1])
    depth = GROUND_RADIUS - distance
    if depth < 0:
        return None
    value = 1.04
    # A bright sunlit lip, then a soft shading band just below the horizon edge.
    if depth < 1.5:
        return 1.0
    value -= 0.30 * smoothstep(1.5, 5.0, depth) * (1.0 - smoothstep(8.0, 30.0, depth))
    # One oval pool of sunlight covers both labels; tone falls off outside it, toward the edges and corners.
    pool = ((u - 320.0) / 300.0) ** 2 + ((v - 280.0) / 62.0) ** 2
    value -= 0.30 * smoothstep(0.62, 2.2, pool)
    side = abs(u - 320.0) / 320.0
    value -= 0.12 * smoothstep(0.75, 1.0, side) * smoothstep(320.0, 400.0, v)
    # Faint surface albedo, mapped onto the ground with perspective, only outside the sunlit pool.
    longitude = (u - 320.0) / 260.0
    latitude = -0.9 + 34.0 / (depth + 40.0)
    detail = albedo(longitude, latitude) - 0.62
    value += 0.28 * detail * smoothstep(0.8, 2.0, pool)
    # Small craters in the bottom corners, lit from the upper left.
    for cx, cy, radius in CRATERS:
        d = math.hypot(u - cx, v - cy) / radius
        if d < 1.35:
            nx, ny = (u - cx) / radius, (v - cy) / radius
            facing = -(nx * SUN[0] - ny * SUN[1])
            if d < 1.0:
                value -= 0.42 * (1.0 - d * d) * (0.55 + 0.45 * facing)
            else:
                value += 0.25 * (1.35 - d) / 0.35 * max(-facing, 0.0)
    value = min(max(value, 0.0), 1.0)
    # The label text areas are exactly GROUND_LIGHT.
    mask = label_mask(u, v)
    return value * (1.0 - mask) + 1.0 * mask


def chevron_dots(variant):
    """Chevron strokes as (x0, y0, x1, y1, brightness) in points."""
    strokes = []
    if variant.startswith("steps"):
        for offset, brightness in ((-24.0, 0.42), (0.0, 0.66), (24.0, 0.95)):
            cx, cy, half = 320.0 + offset, 186.0, 11.0
            strokes += [(cx - half * 0.55, cy - half, cx + half * 0.55, cy, brightness),
                        (cx + half * 0.55, cy, cx - half * 0.55, cy + half, brightness)]
    else:
        cx, cy, half = 322.0, 186.0, 19.0
        strokes += [(cx - half * 0.52, cy - half, cx + half * 0.52, cy, 1.0),
                    (cx + half * 0.52, cy, cx - half * 0.52, cy + half, 1.0)]
    return strokes


def render(variant, scale):
    width, height = WIDTH * scale, HEIGHT * scale
    pixels = bytearray(SKY * (width * height))

    def put(x, y, color):
        if 0 <= x < width and 0 <= y < height:
            index = (y * width + x) * 3
            pixels[index:index + 3] = bytes(color)

    for y in range(height):
        v = (y + 0.5) / scale
        for x in range(width):
            u = (x + 0.5) / scale
            ground = ground_value(u, v)
            if ground is not None:
                # Dither between two light inks, so the brightest tone is one smooth color.
                put(x, y, GROUND_LIGHT if ground >= 0.999 or ground > threshold(x, y) else GROUND_DARK)
                continue
            moon = moon_value(u, v)
            if moon is not None and moon > threshold(x, y):
                put(x, y, MOON_INK)

    if variant.endswith("stars"):
        for sx, sy, brightness in STARS:
            # One point square: a 2 x 2 dot at 2x, one pixel at 1x.
            for ox in range(scale):
                for oy in range(scale):
                    put(int(sx * scale) + ox, int(sy * scale) + oy, mix(SKY, (230, 230, 226), brightness))

    # Dotted chevron strokes, two device dots wide at 2x and one at 1x, a dot every 1.5 pt.
    for x0, y0, x1, y1, brightness in chevron_dots(variant):
        steps = int(math.hypot(x1 - x0, y1 - y0) / 1.5) + 1
        for i in range(steps + 1):
            t = i / steps
            px, py = int((x0 + (x1 - x0) * t) * scale), int((y0 + (y1 - y0) * t) * scale)
            color = mix(SKY, CHEVRON, brightness)
            put(px, py, color)
            if scale == 2:
                put(px + 1, py, color)
                put(px, py + 1, color)
                put(px + 1, py + 1, color)

    raw = b"".join(b"\x00" + bytes(pixels[y * width * 3:(y + 1) * width * 3]) for y in range(height))
    chunk = lambda kind, data: (struct.pack(">I", len(data)) + kind + data
                                + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"pHYs", struct.pack(">IIB", 2835 * scale, 2835 * scale, 1))
            + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


output = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else root / "Packaging"
output.mkdir(parents=True, exist_ok=True)
for scale, suffix in ((2, "@2x"), (1, "")):
    path = output / f"DiskImageBackground{suffix}.png"
    path.write_bytes(render("steps-stars", scale))
    print(path)
