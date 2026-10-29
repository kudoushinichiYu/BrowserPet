#!/usr/bin/env python3
"""Read the original atlas and emit per-cat geometry; never modify image pixels."""
import hashlib
import json
from collections import deque
from pathlib import Path
from PIL import Image

root = Path(__file__).resolve().parent.parent
source = root / 'Resources/pet-atlas.png'
image = Image.open(source).convert('RGBA')
width, height = image.size
active = bytearray(value >= 32 for value in image.getchannel('A').tobytes())
components = []
for index in range(width * height):
    if not active[index]:
        continue
    active[index] = 0
    queue = deque([index])
    count, left, top, right, bottom = 0, width, height, 0, 0
    while queue:
        pixel = queue.popleft()
        y, x = divmod(pixel, width)
        count += 1
        left, top, right, bottom = min(left, x), min(top, y), max(right, x + 1), max(bottom, y + 1)
        for neighbor in ([pixel - 1] if x else []) + ([pixel + 1] if x + 1 < width else []) + ([pixel - width] if y else []) + ([pixel + width] if y + 1 < height else []):
            if active[neighbor]:
                active[neighbor] = 0
                queue.append(neighbor)
    if count > 1000:
        components.append((left, top, right, bottom))

bands = [(0, 180, 8, 'idle'), (180, 310, 7, 'running-right'),
         (310, 430, 7, 'running-left'), (430, 586, 7, 'jumping'),
         (586, 740, 8, 'running'), (740, 896, 8, 'waiting'),
         (896, 1027, 8, 'failed'), (1027, 1165, 8, 'gaze-0-7'),
         (1165, 1330, 8, 'gaze-8-15')]
rows = []
for low, high, expected, name in bands:
    cats = sorted((box for box in components if low <= box[1] < high), key=lambda box: box[0])
    assert len(cats) == expected, (name, len(cats), expected)
    frames = [[x - 2, y - 2, right - x + 4, bottom - y + 4] for x, y, right, bottom in cats]
    assert all(0 <= x and 0 <= y and x + w <= width and y + h <= height and w <= 160 for x, y, w, h in frames)
    rows.append(dict(state=name, baselineY=max(box[3] for box in cats) + 8, frames=frames))
assert sum(len(row['frames']) for row in rows) == len(components) == 69
layout = dict(version=1, sourceWidth=width, sourceHeight=height,
              sourceSHA256=hashlib.sha256(source.read_bytes()).hexdigest(),
              canvasWidth=160, canvasHeight=174, rows=rows)
target = root / 'Resources/pet-atlas-frames.json'
target.write_text(json.dumps(layout, indent=2) + '\n')
print('Mapped 69 individual cats across 9 rows; original PNG unchanged.')
