#!/usr/bin/env python3
from __future__ import annotations

import math
import sys
from collections import Counter
from pathlib import Path


TOP_COLOR = (242, 101, 168)
LEFT_COLOR = (235, 215, 63)
BOTTOM_COLOR = (18, 192, 120)
RIGHT_COLOR = (88, 156, 255)
HIGHLIGHT_COLOR = (235, 242, 255)
ANCHORS = (
    ((0.50, 0.00), TOP_COLOR),
    ((0.00, 0.50), LEFT_COLOR),
    ((0.50, 1.00), BOTTOM_COLOR),
    ((1.00, 0.50), RIGHT_COLOR),
)
COMPACT_X_STEP = 3
COMPACT_Y_STEP = 3


def clamp(value: float) -> int:
    return max(0, min(255, int(round(value))))


def mix(base: tuple[int, int, int], overlay: tuple[int, int, int], amount: float) -> tuple[int, int, int]:
    amount = max(0.0, min(1.0, amount))
    keep = 1.0 - amount
    return tuple(clamp(base[i] * keep + overlay[i] * amount) for i in range(3))


def scale(rgb: tuple[int, int, int], factor: float) -> tuple[int, int, int]:
    return tuple(clamp(channel * factor) for channel in rgb)


def weighted_blend(samples: list[tuple[tuple[int, int, int], float]]) -> tuple[int, int, int]:
    total = sum(weight for _, weight in samples)
    if total <= 0.0:
        return (255, 255, 255)
    return tuple(
        clamp(sum(color[channel] * weight for color, weight in samples) / total)
        for channel in range(3)
    )


def block_pick(chars: list[str]) -> str:
    non_space = [char for char in chars if char != " "]
    if not non_space:
        return " "
    counts = Counter(non_space)
    rank = {"▓": 0, "▒": 1, "░": 2}
    return sorted(counts.items(), key=lambda item: (-item[1], rank.get(item[0], 99), item[0]))[0][0]


def compact_lines(lines: list[str], x_step: int = COMPACT_X_STEP, y_step: int = COMPACT_Y_STEP) -> list[str]:
    width = max(len(line) for line in lines)
    padded = [line.ljust(width) for line in lines]
    compacted: list[str] = []
    for y in range(0, len(padded), y_step):
        row_block = padded[y : y + y_step]
        compact_line: list[str] = []
        for x in range(0, width, x_step):
            block_chars: list[str] = []
            for row in row_block:
                block_chars.extend(list(row[x : x + x_step]))
            compact_line.append(block_pick(block_chars))
        compacted.append("".join(compact_line).rstrip())
    return compacted


def color_for(nx: float, ny: float, char: str) -> tuple[int, int, int]:
    samples: list[tuple[tuple[int, int, int], float]] = []
    for (anchor_x, anchor_y), color in ANCHORS:
        distance = math.hypot(nx - anchor_x, ny - anchor_y)
        weight = 1.0 / max(distance, 0.05) ** 2.15
        samples.append((color, weight))

    rgb = weighted_blend(samples)

    # Small highlight near the upper-right center to echo the reference artwork.
    highlight = math.exp(-(((nx - 0.63) / 0.08) ** 2 + ((ny - 0.24) / 0.06) ** 2))
    rgb = mix(rgb, HIGHLIGHT_COLOR, min(0.82, highlight * 0.88))

    if char == "▓":
        rgb = scale(rgb, 0.84)
    elif char == "░":
        rgb = mix(rgb, (255, 255, 255), 0.22)
    return rgb


def render_logo(lines: list[str]) -> str:
    compacted = compact_lines(lines)
    height = len(compacted)
    width = max((len(line) for line in compacted), default=0)
    if height == 0 or width == 0:
        return ""

    rendered_lines: list[str] = []
    for y, line in enumerate(compacted):
        parts: list[str] = []
        current_color: tuple[int, int, int] | None = None
        for x, char in enumerate(line):
            if char == " ":
                parts.append(char)
                continue

            nx = x / max(1, width - 1)
            ny = y / max(1, height - 1)
            rgb = color_for(nx, ny, char)
            if rgb != current_color:
                parts.append(f"\033[38;2;{rgb[0]};{rgb[1]};{rgb[2]}m")
                current_color = rgb
            parts.append(char)
        if current_color is not None:
            parts.append("\033[0m")
        rendered_lines.append("".join(parts))
    return "\n".join(rendered_lines) + "\n"


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: generate_fastfetch_logo.py <input-ascii.txt> <output.ans>", file=sys.stderr)
        return 1

    input_path = Path(sys.argv[1])
    output_path = Path(sys.argv[2])
    lines = input_path.read_text(encoding="utf-8").splitlines()
    rendered = render_logo(lines)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(rendered, encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
