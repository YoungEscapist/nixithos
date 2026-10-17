# The mark of NixithOS as a durdraw movie (.dur) for ly's dur_file animation.
#
#   python3 mkdur.py <rows> out.dur
#
# ly runs on the bare VT, so the mark is drawn in characters every console
# font has (Lat2-Terminus16): ─ │ / \ ·, dim grey on black, the whole slowly
# breathing.  It is centred like the login box, which then sits over the
# hexagon in its middle.
#
# The mark as line segments, in pixels of ../branding/nixithos.png (1536x1024),
# measured off the picture; drawn cell by cell (a cell of the console is twice
# as tall as it is wide), so every line is one cell thick.
import gzip
import json
import sys

rows, out = int(sys.argv[1]), sys.argv[2]

# (the picture is symmetric about x = 768 and y = 494: the left half and the
# upper half, mirrored)
CX, CY = 768, 494
half = [
    # the vertical axis above: dashes and the dot at its end
    ((768, 197), (768, 224)),
    ((768, 240), (768, 327)),
    # the upper fork: arms and their tips
    ((628, 281), (685, 281)),
    ((685, 281), (768, 393)),
    ((768, 393), (768, 430)),
    # the hexagon, its upper left quarter
    ((768, 430), (728, 430)),
    ((728, 430), (686, 500)),
    # the left bracket
    ((562, 353), (640, 353)),
    ((640, 353), (678, 408)),
    ((678, 408), (623, 494)),
    # the horizontal axis on the left
    ((623, 494), (540, 494)),
    ((520, 494), (482, 494)),
]
dots = [(768, 178), (459, 494)]


def mirrored(seg):
    (x0, y0), (x1, y1) = seg
    fx = lambda x: 2 * CX - x
    fy = lambda y: 2 * CY - y
    return [
        seg,
        ((fx(x0), y0), (fx(x1), y1)),
        ((x0, fy(y0)), (x1, fy(y1))),
        ((fx(x0), fy(y0)), (fx(x1), fy(y1))),
    ]


segments = [s for seg in half for s in mirrored(seg)]
points = []
for x, y in dots:
    points += [(x, y), (2 * CX - x, y), (x, 2 * CY - y), (2 * CX - x, 2 * CY - y)]

# the mark is 632 pixels tall (178..810): `rows - 2` rows of it, a cell as
# tall as two wide
sy = 632 / (rows - 2)
sx = sy / 2
cols = int(round(620 / sx)) + 4
if cols % 2 == 0:
    cols += 1  # (an odd width has a middle column, for the vertical axis)
rows = rows if rows % 2 else rows + 1


def cell(x, y):
    return (int(round((x - CX) / sx)) + cols // 2, int(round((y - CY) / sy)) + rows // 2)


grid = [[None] * cols for _ in range(rows)]


def put(c, r, ch):
    if 0 <= c < cols and 0 <= r < rows:
        grid[r][c] = ch


for (x0, y0), (x1, y1) in segments:
    # the slope in cells decides the character
    dc = (x1 - x0) / sx
    dr = (y1 - y0) / sy
    if abs(dr) <= 0.4 * abs(dc):
        ch = "─"
    elif abs(dc) <= 0.4 * abs(dr):
        ch = "│"
    elif (dc > 0) == (dr > 0):
        ch = "\\"
    else:
        ch = "/"
    n = int(max(abs(dc), abs(dr)) * 2) + 1
    for i in range(n + 1):
        t = i / n
        put(*cell(x0 + (x1 - x0) * t, y0 + (y1 - y0) * t), ch)
for x, y in points:
    put(*cell(x, y), "·")

contents = ["".join(ch or " " for ch in line) for line in grid]

# breathing: grey levels of the 256-colour ramp (232 black .. 255 white)
levels = [239, 240, 241, 242, 243, 244, 244, 243, 242, 241, 240, 239, 238, 238]
frames = []
for i, g in enumerate(levels):
    cmap = [[[g if grid[r][c] else 0, 0] for r in range(rows)] for c in range(cols)]
    frames.append({"frameNumber": i + 1, "delay": 0, "contents": contents, "colorMap": cmap})

movie = {
    "DurMovie": {
        "formatVersion": 7,
        "colorFormat": "256",
        "preferredFont": "fixed",
        "encoding": "utf-8",
        "name": "nixithos",
        "artist": "NixithOS",
        "framerate": 4.0,
        "sizeX": cols,
        "sizeY": rows,
        "extra": None,
        "frames": frames,
    }
}
with gzip.open(out, "wt", encoding="utf-8") as f:
    json.dump(movie, f)
