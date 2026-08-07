#!/usr/bin/env python3
"""Genera iconos PNG RGB opacos para el plugin Despiece PRO."""

import os

from PIL import Image, ImageDraw

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

BG = (0x1A, 0x2A, 0x4A)
WHITE = (0xFF, 0xFF, 0xFF)
CYAN = (0x66, 0xCC, 0xFF)
GOLD = (0xFF, 0xD7, 0x00)


def new_canvas(size):
    image = Image.new("RGB", (size, size), BG)
    return image, ImageDraw.Draw(image)


def draw_scan(size):
    image, draw = new_canvas(size)
    margin = max(2, size // 8)
    box_w = size - 2 * margin
    box_h = max(2, box_w // 2)
    px = margin
    py = margin + max(0, size // 10)

    draw.rectangle([px, py, px + box_w - 1, py + box_h - 1], outline=WHITE, width=max(1, size // 16))

    inner_gap = max(1, size // 10)
    piece_w = max(2, (box_w - inner_gap * 3) // 2)
    piece_h = max(2, (box_h - inner_gap * 2) // 2)
    for row in range(2):
        for col in range(2):
            x0 = px + inner_gap + col * (piece_w + inner_gap)
            y0 = py + inner_gap + row * (piece_h + inner_gap)
            draw.rectangle([x0, y0, x0 + piece_w - 1, y0 + piece_h - 1], fill=CYAN)

    lens_r = max(2, size // 6)
    cx = size - margin - lens_r
    cy = size - margin - lens_r
    draw.ellipse(
        [cx - lens_r, cy - lens_r, cx + lens_r, cy + lens_r],
        outline=GOLD,
        width=max(1, size // 12),
    )
    handle_len = max(2, size // 5)
    draw.line(
        [cx + lens_r - 1, cy + lens_r - 1, cx + lens_r + handle_len, cy + lens_r + handle_len],
        fill=GOLD,
        width=max(1, size // 10),
    )

    return image


def draw_list(size):
    image, draw = new_canvas(size)
    margin = max(2, size // 6)
    line_h = max(2, size // 7)
    gap = max(1, size // 10)
    x0 = margin
    x1 = size - margin
    y = margin

    for index in range(4):
        draw.rectangle([x0, y, x0 + max(2, size // 8), y + line_h - 1], fill=GOLD)
        draw.rectangle(
            [x0 + max(3, size // 6), y + max(0, line_h // 4), x1, y + line_h - max(1, line_h // 4)],
            fill=WHITE,
        )
        y += line_h + gap

    return image


def main():
    base = os.path.join(REPO_ROOT, 'despiece_pro', 'icons')
    os.makedirs(base, exist_ok=True)

    specs = [
        ("scan_small.png", 16, draw_scan),
        ("scan_large.png", 32, draw_scan),
        ("list_small.png", 16, draw_list),
        ("list_large.png", 32, draw_list),
    ]

    for name, size, drawer in specs:
        path = os.path.join(base, name)
        image = drawer(size)
        image.save(path, "PNG")
        print(f"Generado: {path} ({size}x{size}, RGB)")


if __name__ == '__main__':
    main()
