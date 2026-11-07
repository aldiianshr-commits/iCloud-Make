"""Generates the original iCloud IPA app icon (1024x1024, no alpha)."""
import sys
from PIL import Image, ImageDraw, ImageFilter

S = 1024
img = Image.new("RGB", (S, S))
top, bottom = (64, 156, 255), (20, 88, 220)
px = img.load()
for y in range(S):
    t = y / (S - 1)
    c = tuple(int(top[i] * (1 - t) + bottom[i] * t) for i in range(3))
    for x in range(S):
        px[x, y] = c

layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
d = ImageDraw.Draw(layer)
white = (255, 255, 255, 255)
# cloud built from circles + rounded base
d.ellipse((250, 380, 530, 660), fill=white)
d.ellipse((420, 270, 760, 610), fill=white)
d.ellipse((620, 420, 830, 630), fill=white)
d.rounded_rectangle((250, 500, 830, 690), radius=95, fill=white)
d.polygon([(540, 400), (650, 520), (585, 520), (585, 640), (495, 640), (495, 520), (430, 520)], fill=(0, 0, 0, 0))
# punch the arrow out of the cloud, then recolour it
arrow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(arrow).polygon([(540, 400), (650, 520), (585, 520), (585, 640), (495, 640), (495, 520), (430, 520)], fill=(30, 110, 235, 255))
shadow = layer.filter(ImageFilter.GaussianBlur(18))
sh = Image.new("RGBA", (S, S), (0, 0, 0, 0))
sh.paste((10, 40, 120, 90), (0, 14), shadow)
fg = Image.alpha_composite(Image.alpha_composite(sh, layer), arrow)
shifted = Image.new("RGBA", (S, S), (0, 0, 0, 0))
shifted.paste(fg, (-28, 30))
out = img.convert("RGBA")
out.alpha_composite(shifted)
out.convert("RGB").save(sys.argv[1])
