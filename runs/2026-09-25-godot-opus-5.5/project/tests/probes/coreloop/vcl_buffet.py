import json,glob,sys
for b in sys.argv[1:]:
  n=0;tot=0
  for f in sorted(glob.glob(b+'/part_*.json')):
    d=json.load(open(f)); tot+=1
    c=d['catches']; best=[]
    for i in range(len(c)):
        j=i
        while j+1<len(c) and c[j+1]['t']-c[i]['t']<=5.0: j+=1
        if j-i+1>=3 and c[i]['prey']!='moth':
            best.append((c[i]['t'],j-i+1,c[i]['prey'],c[i]['g'],c[j]['g']+c[j]['prey_g']*0)); 
    if best:
        n+=1; b0=max(best,key=lambda x:x[1]); print(' ',f.split('/')[-1],'burst at %.0fs: %d x %s in 5 s, %dg -> %dg'%b0)
  print(b, 'runs with a >=3 non-moth catch burst in 5 s:',n,'of',tot)
