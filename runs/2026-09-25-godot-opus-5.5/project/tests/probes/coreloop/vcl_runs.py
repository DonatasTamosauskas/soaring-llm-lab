import json,glob,sys
for f in sorted(glob.glob(sys.argv[1]+'/part_*.json')):
    d=json.load(open(f))
    ta={k:"%d:%02d"%(v//60,v%60) for k,v in d['tier_at'].items()}
    p=d['person']; ch={}
    for c in d['chases']: ch[c['end']]=ch.get(c['end'],0)+1
    cats=d['catches']; ass=sum(1 for c in cats if c.get('assist',0)>0)
    first=cats[0]['t'] if cats else None
    print(f.split('/')[-1], d['skill'], 'end',d['end_reason'],d['ended_at'], 'pigeon',ta.get('5'),'eagle',ta.get('9'), 'first_up',ta.get('3'),
      'deaths',[(x['as'],x['by'],round(x['t'])) for x in d['deaths']], 'catches',len(cats),'assisted',ass,'first_catch',first,
      'unsticks',p.get('unsticks'),'wedged',ch.get('wedged',0),'chases',len(d['chases']),'seen',len(d['npc_catches_seen']),'show_hunts',d.get('show_hunts'),
      'first_hunt',d.get('first_hunt_t'),'attacks',d['attacks'],'marks',{k:v for k,v in d['danger_marks'].items() if k in('not_hunting','on_murmuration','marked')}, d['log'][:80])
