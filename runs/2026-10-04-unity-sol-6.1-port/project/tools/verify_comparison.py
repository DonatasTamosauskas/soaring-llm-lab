#!/usr/bin/env python3
"""Verify raw/pair pixel preservation, continuous frame sequences, and MP4 decoding."""
import hashlib
import json
import subprocess
from pathlib import Path
from PIL import Image, ImageChops
PORT=Path(__file__).resolve().parents[1]
OUT=PORT/'docs/comparison'
def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()
def main():
    views=[v['id'] for v in json.loads((PORT/'tools/comparison-route.json').read_text())['views']]+['menu','flight']
    report={'screenshots':[], 'pixelPreservation':[], 'recordings':[]}
    for view in views:
        pair=Image.open(OUT/(view+'-comparison.png')).convert('RGB')
        assert pair.size==(2592,846), (view,pair.size)
        for engine,x in [('godot',16),('unity',1312)]:
            path=OUT/'raw'/engine/(view+'.png');raw=Image.open(path).convert('RGB')
            assert raw.size==(1280,720), (engine,view,raw.size)
            assert ImageChops.difference(pair.crop((x,88,x+1280,808)),raw).getbbox() is None,(engine,view,'pixels modified')
            report['screenshots'].append({'view':view,'engine':engine,'sha256':sha(path),'width':1280,'height':720})
        report['pixelPreservation'].append({'view':view,'passed':True,'sha256':sha(OUT/(view+'-comparison.png'))})
    for engine in ('godot','unity'):
        frames=sorted((PORT/'Logs/comparison'/(engine+'-frames')).glob('*.png'))
        assert [p.name for p in frames]==[f'{i:05d}.png' for i in range(600)], engine
    for name,width,height in [('godot-tour.mp4',1280,720),('unity-tour.mp4',1280,720),('side-by-side-tour.mp4',2560,816)]:
        path=OUT/name
        info=json.loads(subprocess.check_output(['ffprobe','-v','error','-select_streams','v:0','-show_entries','stream=codec_name,width,height,r_frame_rate,nb_frames:format=duration','-of','json',str(path)]))
        stream=info['streams'][0]
        assert (stream['codec_name'],stream['width'],stream['height'],stream['r_frame_rate'],int(stream['nb_frames']))==('h264',width,height,'30/1',600),info
        assert abs(float(info['format']['duration'])-20)<.01,info
        subprocess.run(['ffmpeg','-v','error','-i',str(path),'-f','null','-'],check=True,stderr=subprocess.PIPE)
        report['recordings'].append({'file':name,'sha256':sha(path),'width':width,'height':height,'frames':600,'fps':30,'seconds':20,'decoded':True})
    report['presentation']=json.loads((OUT/'presentation/presentation.json').read_text())
    report['presentationXR']=json.loads((OUT/'presentation/xr/presentation.json').read_text())
    report['capturedOn']='2026-10-04'
    (OUT/'verification.json').write_text(json.dumps(report,indent=2)+'\n')
    print('COMPARISON_VERIFIED 7 pixel-preserved pairs; 3 decoded 600-frame recordings')
if __name__=='__main__': main()
