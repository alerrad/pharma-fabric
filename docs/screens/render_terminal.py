"""Рендер фрагментов реальных журналов (reports/*.log) в изображения окна терминала для отчёта.
usage: render_terminal.py <out.png> <title> < text"""
import sys
from PIL import Image, ImageDraw, ImageFont

out, title = sys.argv[1], sys.argv[2]
lines = sys.stdin.read().rstrip("\n").split("\n")
MAXC = 132
wrapped = []
for ln in lines:
    while len(ln) > MAXC:
        wrapped.append(ln[:MAXC]); ln = "    " + ln[MAXC:]
    wrapped.append(ln)

S = 2  # масштаб для чёткости
font = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf", 13 * S)
bold = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf", 13 * S)
tfont = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", 12 * S)
cw = font.getbbox("M")[2]; lh = 18 * S
W = 24 * S + cw * MAXC; H = 34 * S + lh * len(wrapped) + 16 * S
img = Image.new("RGB", (W, H), "#1e2430")
d = ImageDraw.Draw(img)
d.rectangle([0, 0, W, 26 * S], fill="#2d3442")
for i, c in enumerate(["#ff5f56", "#ffbd2e", "#27c93f"]):
    d.ellipse([12 * S + i * 18 * S, 8 * S, 22 * S + i * 18 * S, 18 * S], fill=c)
d.text((W // 2, 13 * S), title, font=tfont, fill="#c8cfdb", anchor="mm")
y = 34 * S
for ln in wrapped:
    col, f = "#d8dee9", font
    s = ln.lstrip()
    if s.startswith("$"):
        col, f = "#8fd18f", bold
    elif s.startswith("==>"):
        col, f = "#7fb4ff", bold
    elif "VALID" in ln and "MVCC" not in ln and "INVALID" not in ln or "PASS" in ln or s.startswith("✔"):
        col = "#a3e3a3"
    if "MVCC_READ_CONFLICT" in ln or "access denied" in ln or "FAIL=" in ln and "FAIL=0" not in ln or "тайм-аут" in ln or "недоступен" in ln:
        col = "#ffb38a"
    d.text((12 * S, y), ln, font=f, fill=col)
    y += lh
img.save(out)
