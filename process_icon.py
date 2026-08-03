#!/usr/bin/env python3
"""前景合成法：从 AI 图抠出白色小人+橙色脉搏波，合成到自造深色渐变底板，彻底无白角。"""
from PIL import Image, ImageDraw, ImageFilter

SRC = "/Users/shilei/WorkBuddy/Sport/generated-images/iOS_app_icon_design__flat_mode_2026-07-31T06-26-37.png"
DST = "/Users/shilei/WorkBuddy/Sport/SportHealth/SportHealth/Assets.xcassets/AppIcon.appiconset/AppIcon.png"

S = 1024
src = Image.open(SRC).convert("RGB").resize((S, S), Image.LANCZOS)
sp = src.load()

# 1) 造深色对角渐变底板
board = Image.new("RGB", (S, S))
bp = board.load()
top = (28, 33, 58)
bot = (12, 13, 18)
for y in range(S):
    for x in range(S):
        t = (x + y) / (2 * (S - 1))
        bp[x, y] = (int(top[0]+(bot[0]-top[0])*t),
                    int(top[1]+(bot[1]-top[1])*t),
                    int(top[2]+(bot[2]-top[2])*t))
# 底部暖橙辉光
glow = Image.new("RGBA", (S, S), (0,0,0,0))
gd = ImageDraw.Draw(glow)
for rr in range(int(S*0.5), 0, -4):
    a = int(80 * (1 - rr/(S*0.5)))
    gd.ellipse([S//2-rr, int(S*0.93)-rr, S//2+rr, int(S*0.93)+rr], fill=(255,138,0,max(0,a)))
board = Image.alpha_composite(board.convert("RGBA"), glow).convert("RGB")
bp = board.load()

# 2) 逐像素提取前景：
#    - 白色小人：R,G,B 都高
#    - 橙色脉搏波：R 高、G 中、B 低
out = board.copy()
op = out.load()
# 只在中心安全区取前景，外圈 88px（圆角带）一律忽略，避免白角
margin = 92
for y in range(S):
    for x in range(S):
        if x < margin or x > S-margin or y < margin or y > S-margin:
            continue
        r, g, b = sp[x, y]
        # 白色前景
        if r > 205 and g > 205 and b > 205:
            op[x, y] = (255, 255, 255)
        # 橙色脉搏波（含发光过渡）
        elif r > 150 and g > 60 and b < 130 and r > b + 60 and r >= g:
            op[x, y] = (min(255, r+10), min(200, g), max(0, b))

out.save(DST)
print("saved", out.size)
