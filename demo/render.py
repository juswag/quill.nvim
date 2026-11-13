# Renders demo/demo.cast + demo/events.txt into the README demo GIFs and MP4s, once per theme.
# The terminal is rasterized with pyte (agg drops strikethrough); captions, key chips,
# the cursor and the hunk marker are drawn here so they can ease between states.
# The recording uses the light palette; the dark render maps each highlight color to its
# DEMO_THEME=dark counterpart from demo/init.lua, so both share one recording and timing.
# Usage: render.py [light|dark]          full render, both themes by default
#        render.py sheet THEME T...      contact sheet of frames at cast times T (demo/sheet.png)
import json, os, shutil, subprocess, sys, tempfile
import pyte
from fontTools.ttLib import TTFont
from PIL import Image, ImageDraw, ImageFilter, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
FPS, OUT_W = 25, 960
RED, ON_RED = "#E5482D", "#ffffff"
# canvas matches GitHub's page background so the GIF edges disappear; window matches nvim's Normal bg.
THEMES = {
    "light": dict(canvas="#ffffff", window="#ffffff", border="#d0d7de", ink="#0d1117", shadow=True,
                  gif="assets/demo.gif", mp4="demo/demo.mp4"),
    "dark": dict(canvas="#0d1117", window="#161b22", border="#30363d", ink="#e6edf3", shadow=False,
                 gif="assets/demo-dark.gif", mp4="demo/demo-dark.mp4"),
}
T = None
PLEX = "/usr/share/fonts/truetype/sand-box/google/IBM Plex Mono/IBMPlexMono-"
DEJAVU = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf"

def plex(style, size):
    return ImageFont.truetype(PLEX + style + ".ttf", size)

SIZE = 30
FONTS = {(b, i): plex(["Regular", "Italic", "SemiBold", "SemiBoldItalic"][2 * b + i], SIZE) for b in (0, 1) for i in (0, 1)}
SYM = ImageFont.truetype(DEJAVU, SIZE - 4)
PLEX_CMAP = TTFont(PLEX + "Regular.ttf").getBestCmap()
CW, CH = round(FONTS[(0, 0)].getlength("M")), round(SIZE * 1.45)

# Canvas at 2x the output size, downscaled at the end so text stays crisp.
PAD, MARGIN_TOP, FOOTER = 26, 40, 132
cast_lines = open(os.path.join(HERE, "demo.cast")).read().splitlines()
HEAD = json.loads(cast_lines[0])
COLS, ROWS = HEAD["width"], HEAD["height"]
TERM_W, TERM_H = COLS * CW, ROWS * CH
WIN_W, WIN_H = TERM_W + 2 * PAD, TERM_H + 2 * PAD
W = 2 * OUT_W
H = MARGIN_TOP + WIN_H + FOOTER
H += H % 2
WIN_X, WIN_Y = (W - WIN_W) // 2, MARGIN_TOP
TERM_X, TERM_Y = WIN_X + PAD, WIN_Y + PAD
CAP_FONT, NUM_FONT, CHIP_FONT = plex("SemiBold", 38), plex("SemiBold", 30), plex("Medium", 28)
FOOT_Y = WIN_Y + WIN_H + FOOTER // 2

def ease(x):
    x = min(max(x, 0.0), 1.0)
    return 4 * x ** 3 if x < 0.5 else 1 - (-2 * x + 2) ** 3 / 2

def ease_out(x):
    x = min(max(x, 0.0), 1.0)
    return 1 - (1 - x) ** 3

def mix(a, b, t):
    a, b = [int(a[i:i + 2], 16) for i in (1, 3, 5)], [int(b[i:i + 2], 16) for i in (1, 3, 5)]
    return "#%02x%02x%02x" % tuple(round(x + (y - x) * t) for x, y in zip(a, b))

# --- events: steps drive captions, keys drive chips -------------------------------------
STEPS, KEYS = [], []
for line in open(os.path.join(HERE, "events.txt")):
    kind, t, label = line.rstrip("\n").split(" ", 2)
    (STEPS if kind == "step" else KEYS).append((float(t), label))
END_T = STEPS[-1][0]
START_T = STEPS[0][0] - 0.8
LABELS = {"Space k": "space k", "Enter": "enter"}

# --- terminal ---------------------------------------------------------------------------
DUMP_HL = """
local out = {}
for name in pairs(vim.api.nvim_get_hl(0, {})) do
  local r = vim.api.nvim_get_hl(0, { name = name, link = false })
  out[name] = { fg = r.fg and ("%06x"):format(r.fg), bg = r.bg and ("%06x"):format(r.bg) }
end
vim.fn.writefile({ vim.json.encode(out) }, vim.env.OUT)
"""

def highlights(theme):
    with tempfile.TemporaryDirectory() as tmp:
        lua, out = os.path.join(tmp, "dump.lua"), os.path.join(tmp, "hl.json")
        open(lua, "w").write(DUMP_HL)
        subprocess.run(["nvim", "--headless", "-u", os.path.join(HERE, "init.lua"), "-i", "NONE", os.path.join(HERE, "sample.lua"),
                        "-c", "luafile " + lua, "-c", "qa!"], env={**os.environ, "DEMO_THEME": theme, "OUT": out}, check=True)
        return {k: v for k, v in json.load(open(out)).items() if isinstance(v, dict)}

def recolor_map(theme):
    """(role, recorded hex) -> hex for `theme`, matched by highlight group name."""
    if theme == "light":
        return {}
    src, dst = highlights("light"), highlights(theme)
    out = {}
    for name, spec in src.items():
        for role in ("fg", "bg"):
            a, b = spec.get(role), dst.get(name, {}).get(role)
            if a and b and out.setdefault((role, a), b) != b:
                sys.exit(f"{name}.{role}: {a} maps to both {out[(role, a)]} and {b}")
    return out

def color(c, role):
    default = T["ink"] if role == "fg" else T["window"]
    if len(c) != 6:
        return default
    if not T["map"]:
        return "#" + c
    return "#" + T["map"][(role, c)] if (role, c) in T["map"] else default

def term_image(screen):
    im = Image.new("RGB", (TERM_W, TERM_H), T["window"])
    d = ImageDraw.Draw(im)
    for y in range(ROWS):
        row = screen.buffer[y]
        for x in range(COLS):
            ch = row[x]
            fg, bg = color(ch.fg, "fg"), color(ch.bg, "bg")
            if ch.reverse:
                fg, bg = bg, fg
            x0, y0 = x * CW, y * CH
            if bg != T["window"]:
                d.rectangle([x0, y0, x0 + CW - 1, y0 + CH - 1], fill=bg)
            if ch.data.strip():
                font = FONTS[(int(ch.bold), int(ch.italics))] if ord(ch.data[0]) in PLEX_CMAP else SYM
                d.text((x0, y0 + CH // 2), ch.data, font=font, fill=fg, anchor="lm")
            if ch.strikethrough:
                d.line([x0, y0 + CH // 2 + 1, x0 + CW, y0 + CH // 2 + 1], fill=fg, width=2)
    return im

def screens():
    """Yields (t, terminal image, cursor cell or None, char under it, statusline) at FPS."""
    screen = pyte.Screen(COLS, ROWS)
    stream = pyte.ByteStream(screen)
    events = [json.loads(l) for l in cast_lines[1:]]
    i, n, last_key, img = 0, 0, None, None
    while True:
        t = START_T + n / FPS
        if t > END_T + 1.2:
            return
        while i < len(events) and events[i][0] <= min(t, END_T - 0.4):
            if events[i][1] == "o":
                stream.feed(events[i][2].encode())
            i += 1
        rows = tuple(tuple((c.data, c.fg, c.bg, c.bold, c.italics, c.strikethrough, c.reverse) for c in screen.buffer[y].values())
                     for y in range(ROWS))
        if rows != last_key:
            img, last_key = term_image(screen), rows
        status = "".join(screen.buffer[ROWS - 1][x].data for x in range(COLS))
        cur = None if screen.cursor.hidden else (screen.cursor.x, screen.cursor.y)
        under = screen.buffer[cur[1]][cur[0]].data if cur else " "
        yield t, img, cur, under, status
        n += 1

# --- static chrome ----------------------------------------------------------------------
def chrome():
    im = Image.new("RGB", (W, H), T["canvas"])
    if T["shadow"]:
        shadow = Image.new("L", (W, H), 0)
        ImageDraw.Draw(shadow).rounded_rectangle([WIN_X, WIN_Y + 10, WIN_X + WIN_W, WIN_Y + WIN_H + 10], 18, fill=26)
        shadow = shadow.filter(ImageFilter.GaussianBlur(18))
        im.paste(Image.new("RGB", (W, H), T["ink"]), (0, 0), shadow)
    d = ImageDraw.Draw(im)
    d.rounded_rectangle([WIN_X, WIN_Y, WIN_X + WIN_W, WIN_Y + WIN_H], 16, fill=T["window"], outline=T["border"], width=2)
    return im

# --- overlays ---------------------------------------------------------------------------
def draw_caption(base, t):
    """Step caption, bottom left: the outgoing one slides up and fades, the next slides in."""
    d = ImageDraw.Draw(base)
    shown = [(i, s) for i, s in enumerate(STEPS[:-1]) if s[0] <= t]
    if not shown:
        return
    idx, (st, text) = shown[-1]
    k = ease((t - st - 0.18) / 0.3) if idx else ease((t - st) / 0.3)
    gone = ease((t - st) / 0.18)
    out_k = ease((t - END_T) / 0.4)
    layers = [(idx, text, k * (1 - out_k), (1 - k) * 20 - out_k * 20)]
    if idx > 0 and gone < 1:
        layers.append((idx - 1, STEPS[idx - 1][1], 1 - gone, -gone * 20))
    for i, label, alpha, dy in layers:
        if alpha <= 0.01:
            continue
        y = FOOT_Y + dy
        d.rounded_rectangle([WIN_X, y - 24, WIN_X + 48, y + 24], 6, fill=mix(T["canvas"], RED, alpha))
        d.text((WIN_X + 24, y), str(i + 1), font=NUM_FONT, fill=mix(RED, ON_RED, alpha), anchor="mm")
        d.text((WIN_X + 72, y), label, font=CAP_FONT, fill=mix(T["canvas"], T["ink"], alpha), anchor="lm")

def chips_at(t):
    """Keys pressed in the current step, newest last, with typed text revealed per character."""
    step_t = max([s for s, _ in STEPS if s <= t] or [START_T])
    out = []
    for kt, label in KEYS:
        if step_t - 0.05 <= kt <= t:
            if label.startswith('"'):
                text = label.strip('"')
                label = text[:max(1, int((t - kt) / 0.055) + 1)]
            out.append((kt, LABELS.get(label, label)))
    return out[-4:]

def draw_chips(base, t):
    d = ImageDraw.Draw(base)
    chips = chips_at(min(t, END_T))
    out_k = ease((t - END_T) / 0.4)
    x = WIN_X + WIN_W
    for n, (kt, label) in enumerate(reversed(chips)):
        newest = n == 0
        k = ease_out((t - kt) / 0.22)
        w = d.textlength(label, font=CHIP_FONT) + 36
        alpha = k * (1 - out_k)
        y = FOOT_Y + (1 - k) * 18
        canvas = T["canvas"]
        fill = mix(canvas, RED, alpha) if newest else canvas
        text = mix(canvas, ON_RED, alpha) if newest else mix(canvas, T["ink"], alpha)
        outline = fill if newest else mix(canvas, T["border"], alpha)
        d.rounded_rectangle([x - w, y - 26, x, y + 26], 8, fill=fill, outline=outline, width=2)
        d.text((x - w / 2, y), label, font=CHIP_FONT, fill=text, anchor="mm")
        x -= w + 14

class Glide:
    """Eases a 2D point toward its latest target."""
    def __init__(self, dur):
        self.dur, self.pos, self.start, self.target, self.t0 = dur, None, None, None, 0
    def at(self, t, target):
        if target is None:
            return self.pos
        if self.pos is None:
            self.pos = self.start = self.target = target
        if target != self.target:
            self.start, self.target, self.t0 = self.pos, target, t
        k = ease((t - self.t0) / self.dur)
        self.pos = tuple(a + (b - a) * k for a, b in zip(self.start, self.target))
        return self.pos

def frames():
    caret, marker = Glide(0.08), Glide(0.24)
    first, base = None, chrome()
    for t, term, cur, under, status in screens():
        im = base.copy()
        im.paste(term, (TERM_X, TERM_Y))
        d = ImageDraw.Draw(im)
        pos = caret.at(t, cur)
        if pos and cur:
            x0, y0 = TERM_X + pos[0] * CW, TERM_Y + pos[1] * CH
            if "INSERT" in status:
                d.rectangle([x0, y0 + 4, x0 + 3, y0 + CH - 4], fill=T["ink"])
            else:
                d.rectangle([x0, y0 + 2, x0 + CW - 1, y0 + CH - 3], fill=T["ink"])
                if under.strip() and pos == cur:
                    d.text((x0, y0 + CH // 2), under, font=FONTS[(0, 0)], fill=T["window"], anchor="lm")
        reviewing = "reviewing" in status
        row = marker.at(t, (0, cur[1]) if reviewing and cur else None)
        if reviewing and row:
            y = TERM_Y + row[1] * CH
            d.rounded_rectangle([WIN_X + 6, y + 6, WIN_X + 12, y + CH - 6], 3, fill=RED)
        draw_caption(im, t)
        draw_chips(im, t)
        if first is None:
            first = im
        k = ease((t - END_T - 0.5) / 0.6)
        if k > 0:
            im = Image.blend(im, first, k)
        yield t, im.resize((OUT_W, H * OUT_W // W), Image.LANCZOS)

def use(theme):
    global T
    T = dict(THEMES[theme], map=recolor_map(theme))

def render(theme):
    use(theme)
    tmp = tempfile.mkdtemp()
    n = 0
    for _, im in frames():
        im.save(os.path.join(tmp, f"{n:05d}.png"))
        n += 1
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-framerate", str(FPS), "-i", os.path.join(tmp, "%05d.png"),
                    "-c:v", "libx264", "-preset", "slow", "-crf", "18", "-pix_fmt", "yuv420p", "-movflags", "+faststart",
                    os.path.join(ROOT, T["mp4"])], check=True)
    # One palette for the whole clip and no dithering, so the canvas stays exactly the page color.
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-framerate", str(FPS), "-i", os.path.join(tmp, "%05d.png"), "-vf",
                    "split[a][b];[a]palettegen=max_colors=256:stats_mode=full[p];[b][p]paletteuse=dither=none:diff_mode=rectangle",
                    os.path.join(ROOT, T["gif"])], check=True)
    shutil.rmtree(tmp)
    print(f"{T['gif']}: {n} frames, {n / FPS:.1f}s")

def main():
    if sys.argv[1:2] == ["sheet"]:
        use(sys.argv[2])
        want = sorted(float(x) for x in sys.argv[3:])
        got = []
        for t, im in frames():
            if want and t >= want[0]:
                got.append(im)
                want.pop(0)
        cols = 3
        w, h = got[0].size
        sheet = Image.new("RGB", (cols * w + (cols + 1) * 12, -(-len(got) // cols) * (h + 12) + 12), "#8c959f")
        for n, im in enumerate(got):
            sheet.paste(im, (12 + (n % cols) * (w + 12), 12 + (n // cols) * (h + 12)))
        sheet.save(os.path.join(HERE, "sheet.png"))
        return
    for theme in sys.argv[1:] or THEMES:
        render(theme)

main()
