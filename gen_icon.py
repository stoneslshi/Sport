#!/usr/bin/env python3
"""生成 SportHealth App 图标（1024x1024）：深色渐变底 + 橙色心率脉搏波 + 跑步小人。"""
import math
from PIL import Image, ImageDraw

SS = 4                      # 超采样倍数
S = 1024
W = S * SS
img = Image.new("RGB", (W, W), (0, 0, 0))
px = img.load()

# 1) 对角渐变背景：深蓝黑 -> 深灰蓝
top = (18, 20, 28)
bot = (30, 34, 46)
for y in range(W):
    t = y / (W - 1)
    r = int(top[0] + (bot[0] - top[0]) * t)
    g = int(top[1] + (bot[1] - top[1]) * t)
    b = int(top[2] + (bot[2] - top[2]) * t)
    for x in range(W):
        # 轻微横向偏移营造对角光感
        tx = x / (W - 1) * 0.15
        px[x, y] = (min(255, int(r + tx * 14)),
                    min(255, int(g + tx * 12)),
                    min(255, int(b + tx * 18)))

draw = ImageDraw.Draw(img, "RGBA")

cx = W / 2
ORANGE = (255, 138, 0)
ORANGE_L = (255, 176, 60)

# 2) 底部径向橙色辉光
glow = Image.new("RGBA", (W, W), (0, 0, 0, 0))
gd = ImageDraw.Draw(glow)
gcx, gcy = W / 2, W * 0.60
for rr in range(int(W * 0.55), 0, -6):
    a = int(46 * (1 - rr / (W * 0.55)))
    gd.ellipse([gcx - rr, gcy - rr, gcx + rr, gcy + rr],
               fill=(255, 138, 0, max(0, a)))
img = Image.alpha_composite(img.convert("RGBA"), glow).convert("RGB")
draw = ImageDraw.Draw(img, "RGBA")

# 3) 心率脉搏波（橙色），横贯中部偏下
def pulse_y(x):
    base = W * 0.66
    # 归一化 0..1
    u = x / W
    # 一段平线 + 一个尖峰
    peak_c = 0.5
    d = (u - peak_c)
    spike = math.exp(-(d * 22) ** 2)          # 主尖峰
    dip = -0.35 * math.exp(-((u - peak_c + 0.06) * 30) ** 2)  # 峰前小回落
    dip2 = -0.5 * math.exp(-((u - peak_c - 0.05) * 26) ** 2)  # 峰后下探
    small = 0.12 * math.exp(-((u - 0.30) * 40) ** 2)
    val = spike + dip + dip2 + small
    return base - val * W * 0.20

pts = []
for i in range(0, W + 1, 2):
    x = i
    pts.append((x, pulse_y(x)))

lw = int(W * 0.016)
# 描边发光
for width, col in [(lw + 22, (255, 138, 0, 40)),
                   (lw + 10, (255, 138, 0, 80)),
                   (lw, (255, 176, 60, 255))]:
    draw.line(pts, fill=col, width=width, joint="curve")

# 4) 中央跑步小人剪影（白色），置于脉搏波上方
def runner(dr, ox, oy, sc, color):
    # 以 100x100 设计坐标，向量点
    def P(x, y):
        return (ox + x * sc, oy + y * sc)
    # 头
    hr = 10 * sc
    hx, hy = P(58, 12)
    dr.ellipse([hx - hr, hy - hr, hx + hr, hy + hr], fill=color)
    # 躯干（前倾）
    dr.line([P(55, 22), P(44, 52)], fill=color, width=int(11 * sc), joint="curve")
    # 手臂前后摆
    dr.line([P(52, 30), P(70, 24)], fill=color, width=int(9 * sc), joint="curve")   # 前臂上
    dr.line([P(70, 24), P(78, 36)], fill=color, width=int(9 * sc), joint="curve")   # 前臂下
    dr.line([P(50, 32), P(34, 40)], fill=color, width=int(9 * sc), joint="curve")   # 后臂上
    dr.line([P(34, 40), P(30, 54)], fill=color, width=int(9 * sc), joint="curve")   # 后臂下
    # 腿（跨步）
    dr.line([P(45, 50), P(58, 74)], fill=color, width=int(11 * sc), joint="curve")  # 前腿大
    dr.line([P(58, 74), P(52, 92)], fill=color, width=int(10 * sc), joint="curve")  # 前腿小
    dr.line([P(45, 50), P(30, 70)], fill=color, width=int(11 * sc), joint="curve")  # 后腿大
    dr.line([P(30, 70), P(38, 86)], fill=color, width=int(10 * sc), joint="curve")  # 后腿小
    # 圆头端点补齐
    for p in [P(70, 24), P(78, 36), P(34, 40), P(30, 54),
              P(58, 74), P(52, 92), P(30, 70), P(38, 86), P(45, 50)]:
        r = int(5.5 * sc)
        dr.ellipse([p[0]-r, p[1]-r, p[0]+r, p[1]+r], fill=color)

rsc = W / 100 * 0.42
rox = W * 0.30
roy = W * 0.24
runner(draw, rox, roy, rsc, (255, 255, 255, 255))

# 5) 下采样 + 圆角遮罩（iOS 会自动裁圆角，这里输出方形即可）
img = img.resize((S, S), Image.LANCZOS)
img.save("/Users/shilei/WorkBuddy/Sport/SportHealth/SportHealth/Assets.xcassets/AppIcon.appiconset/AppIcon.png")
print("saved 1024x1024")
