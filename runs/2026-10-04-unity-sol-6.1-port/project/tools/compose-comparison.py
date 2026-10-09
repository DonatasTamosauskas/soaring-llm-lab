#!/usr/bin/env python3
"""Frame-native comparison packaging. No grading, retouching or exposure changes."""
import json
import subprocess
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

PORT = Path(__file__).resolve().parents[1]
OUT = PORT / 'docs/comparison'
ROUTE = json.loads((PORT / 'tools/comparison-route.json').read_text())
FONT_PATH = '/System/Library/Fonts/Avenir Next.ttc'
BG = '#112529'
INK = '#f3f1e5'
MUTED = '#b6c8c6'

def font(size):
    return ImageFont.truetype(FONT_PATH, size)

def compare(view, note):
    images = [Image.open(OUT / 'raw' / engine / (view['id'] + '.png')).convert('RGB') for engine in ('godot','unity')]
    assert all(image.size == (1280,720) for image in images), [image.size for image in images]
    image = Image.new('RGB',(2592,846),BG)
    draw = ImageDraw.Draw(image)
    draw.text((16,12),view['title'],font=font(30),fill=INK)
    draw.text((16,56),'GODOT 4.7.2  ·  Forward+ / Vulkan',font=font(18),fill=MUTED)
    draw.text((1312,56),'UNITY 6.6  ·  URP / Metal',font=font(18),fill=MUTED)
    image.paste(images[0],(16,88)); image.paste(images[1],(1312,88))
    draw.text((16,817),note,font=font(17),fill=MUTED)
    image.save(OUT / (view['id']+'-comparison.png'))

def run(args):
    subprocess.run(args,check=True)

def movie():
    for engine in ('godot','unity'):
        directory = PORT / 'Logs/comparison' / (engine+'-frames')
        paths = sorted(directory.glob('*.png'))
        assert len(paths) == 600, (engine,len(paths))
        assert [p.name for p in paths] == [f'{i:05d}.png' for i in range(600)]
        run(['ffmpeg','-hide_banner','-loglevel','warning','-y','-framerate','30','-i',str(directory/'%05d.png'),'-c:v','libx264','-preset','medium','-crf','18','-pix_fmt','yuv420p','-movflags','+faststart',str(OUT/(engine+'-tour.mp4'))])
    # Add labels outside the original pixel rectangles, retaining both frames.
    filters = ['[0:v][1:v]hstack=inputs=2,pad=2560:816:0:72:color=0x112529']
    filters += [f"drawtext=fontfile='{FONT_PATH}':text='GODOT 4.7.2 / Forward+':fontsize=26:fontcolor=0xf3f1e5:x=20:y=22"]
    filters += [f"drawtext=fontfile='{FONT_PATH}':text='UNITY 6.6 / URP':fontsize=26:fontcolor=0xf3f1e5:x=1300:y=22"]
    for i,view in enumerate(ROUTE['views']):
        filters += [f"drawtext=fontfile='{FONT_PATH}':text='{view['title']}  |  Matched camera - macOS capture':fontsize=18:fontcolor=0xb6c8c6:x=20:y=790:enable='gte(t,{i*4})*lt(t,{(i+1)*4})'"]
    run(['ffmpeg','-hide_banner','-loglevel','warning','-y','-i',str(OUT/'godot-tour.mp4'),'-i',str(OUT/'unity-tour.mp4'),'-filter_complex',','.join(filters),'-c:v','libx264','-preset','medium','-crf','18','-pix_fmt','yuv420p','-an','-movflags','+faststart',str(OUT/'side-by-side-tour.mp4')])

def main():
    for view in ROUTE['views']:
        compare(view,'Matched world camera · 1280 × 720 per engine · 70° vertical FOV · Native lighting, fog and materials · NPCs and HUD excluded')
    compare({'id':'menu','title':'Main menu'},'Native world-space UI · Same output resolution; 90° vertical FOV in both engines · Godot scripted pointer; Unity desktop view')
    compare({'id':'flight','title':'First flight and HUD'},'Native gameplay UI · Synthetic wing input · Different flight paths and timings · 90° vertical FOV in both engines · macOS capture')
    # A compact overview for quick inspection; full-size originals remain linked.
    contact = Image.new('RGB',(1296, int(846*5/2)),BG)
    for i,view in enumerate(ROUTE['views']):
        tile=Image.open(OUT/(view['id']+'-comparison.png')).resize((1296,423),Image.Resampling.LANCZOS)
        contact.paste(tile,(0,i*423))
    contact.save(OUT/'world-contact-sheet.jpg',quality=92)
    movie()
    import verify_comparison
    verify_comparison.main()

if __name__ == '__main__': main()
