import json,glob,math,sys
def load(pats):
    d={}
    for p in pats.split(','):
        for f in glob.glob(p):
            for l in open(f):
                if l.strip():
                    x=json.loads(l); d[(x['deck'],x['seed'],x['stake'])]=x
    return d
b=load(sys.argv[1]); n=load(sys.argv[2])
rw=lambda x:x['won']==1 and x['need']==0
for st in sorted({k[2] for k in n})+[None]:
    k=[k for k in n if k in b and (st is None or k[2]==st)]
    on=sum(1 for x in k if rw(n[x]) and not rw(b[x])); ob=sum(1 for x in k if rw(b[x]) and not rw(n[x]))
    z=(on-ob)/math.sqrt(on+ob) if on+ob else 0
    dd=[n[x]['ante']-b[x]['ante'] for x in k]
    print(st or 'all',len(k),'wins',sum(rw(n[x]) for x in k),'vs',sum(rw(b[x]) for x in k),'one side',on,'vs',ob,'z %+.1f'%z,'ante %+.3f'%(sum(dd)/len(dd)))
