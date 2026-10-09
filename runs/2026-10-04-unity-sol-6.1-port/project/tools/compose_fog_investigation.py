#!/usr/bin/env python3
"""Native-pixel fog/tone-map ablation comparisons and verification."""
from pathlib import Path
import hashlib,json
from PIL import Image,ImageDraw,ImageFont,ImageChops,ImageStat
ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'docs/fog-investigation'
MODES=['baseline','no-fog','linear','no-fog-linear']
LABELS=['Original: fog + Filmic','Fog off; Filmic retained','Fog retained; Linear tone mapping','Fog off + Linear tone mapping']
BG='#112529';INK='#f3f1e5';MUTED='#b6c8c6'
def font(size):return ImageFont.truetype('/System/Library/Fonts/Avenir Next.ttc',size)
def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def stats(im):
    hsv=ImageStat.Stat(im.convert('HSV'))
    gray=ImageStat.Stat(im.convert('L'))
    r,g,b=im.split();largest=ImageChops.lighter(ImageChops.lighter(r,g),b)
    clipped=largest.histogram()[255]/(im.width*im.height)
    return {'meanSaturation':round(hsv.mean[1]/255,4),'meanLuma':round(gray.mean[0]/255,4),'lumaStdDev':round(gray.stddev[0]/255,4),'pixelsWithClippedChannel':round(clipped,5)}
def metrics(a,b):
    diff=ImageChops.difference(a,b)
    return {'meanAbsoluteRGBDifference':round(sum(ImageStat.Stat(diff).mean)/3,4),'maxChannelDifference':max(x[1] for x in diff.getextrema())}
def main():
    route=json.loads((ROOT/'tools/comparison-route.json').read_text());report={'views':[],'screenshots':[]}
    for view in route['views']:
        id=view['id'];images=[Image.open(OUT/'raw'/mode/(id+'.png')).convert('RGB') for mode in MODES]
        assert all(im.size==(1280,720) for im in images)
        control=Image.open(OUT/'raw/baseline-control'/(id+'.png')).convert('RGB')
        controlDiff=metrics(images[0],control)
        assert controlDiff['maxChannelDifference']==0,(id,controlDiff)
        data={'id':id,'baselineControlDifference':controlDiff,'states':{}}
        for mode,im in zip(MODES,images):
            data['states'][mode]=stats(im)
            data['states'][mode]['differenceFromOriginal']=metrics(images[0],im)
            path=OUT/'raw'/mode/(id+'.png')
            report['screenshots'].append({'path':str(path.relative_to(OUT)),'sha256':sha(path),'size':list(im.size)})
        data['fogEffectRegions']={name:metrics(images[0].crop(rect),images[1].crop(rect)) for name,rect in {'upper_scene':[0,90,1280,390],'foreground':[0,570,1280,720]}.items()}
        report['views'].append(data)
        quad=Image.new('RGB',(2592,1646),BG);draw=ImageDraw.Draw(quad)
        draw.text((16,10),view['title']+' — Godot fog and tone-mapping experiment',font=font(30),fill=INK)
        for i,(im,label) in enumerate(zip(images,LABELS)):
            x=16+(i%2)*1296;y=88+(i//2)*770
            draw.text((x,y-32),label,font=font(24),fill=MUTED);quad.paste(im,(x,y))
        draw.text((16,1618),'Same seed, camera, lighting and draw frame · 1280 × 720 native pixels per view · Forward+ / Vulkan · No image grading',font=font(19),fill=MUTED)
        quad.save(OUT/(id+'-four-states.png'))
        pair=Image.new('RGB',(2592,846),BG);draw=ImageDraw.Draw(pair)
        draw.text((16,10),view['title']+' — removing only Godot’s fog',font=font(30),fill=INK)
        for x,im,label in [(16,images[0],LABELS[0]),(1312,images[1],LABELS[1])]:
            draw.text((x,56),label,font=font(20),fill=MUTED);pair.paste(im,(x,88))
        draw.text((16,817),'Same draw frame and camera · Only fog_enabled changes · Filmic tone mapping, sky, sun, materials and shadows retained',font=font(18),fill=MUTED)
        pair.save(OUT/(id+'-fog-comparison.png'))
        for i,im in enumerate(images):
            x=16+(i%2)*1296;y=88+(i//2)*770
            assert ImageChops.difference(quad.crop((x,y,x+1280,y+720)),im).getbbox() is None
        for x,im in [(16,images[0]),(1312,images[1])]:
            assert ImageChops.difference(pair.crop((x,88,x+1280,808)),im).getbbox() is None
    report['pixelPreservationPassed']=True;report['baselineControlsExact']=True
    (OUT/'verification.json').write_text(json.dumps(report,indent=2)+'\n')
    print('FOG_COMPARISONS_VERIFIED: 5 identical baseline controls; 5 native-pixel pairs and four-state panels')
    for view in report['views']:
        print(view['id'],{m:view['states'][m]['meanSaturation'] for m in MODES},'fog difference',view['states']['no-fog']['differenceFromOriginal'])
if __name__=='__main__':main()
