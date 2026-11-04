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
decks=sorted({k[0] for k in n})
for deck in decks+[None]:
    k=[k for k in n if k in b and (deck is None or k[0]==deck)]
    if len(k)<2: continue
    dd=[n[x]['ante']-b[x]['ante'] for x in k]
    m=sum(dd)/len(dd); sd=math.sqrt(sum((v-m)**2 for v in dd)/(len(dd)-1)) or 1e-9
    rw=lambda g:sum(1 for x in k if g[x]['won']==1 and g[x]['need']==0)
    on=sum(1 for x in k if n[x]['won']==1 and n[x]['need']==0 and not (b[x]['won']==1 and b[x]['need']==0))
    ob=sum(1 for x in k if b[x]['won']==1 and b[x]['need']==0 and not (n[x]['won']==1 and n[x]['need']==0))
    tn=sum(n[x]['time'] for x in k)/len(k); tb=sum(b[x]['time'] for x in k)/len(k)
    same=sum(1 for x in k if n[x]['ante']==b[x]['ante'] and n[x]['moves']==b[x]['moves'] and n[x]['chips']==b[x]['chips'])
    print(deck or 'all', len(k), 'new %.2f base %.2f'%(sum(n[x]['ante'] for x in k)/len(k), sum(b[x]['ante'] for x in k)/len(k)), 'paired %+.3f z %+.2f'%(m, m/(sd/math.sqrt(len(dd)))), 'real wins', rw(n),'vs',rw(b), 'one side', on,'vs',ob, 'a1-2 dead', sum(1 for x in k if n[x]['ante']<=2), 'vs', sum(1 for x in k if b[x]['ante']<=2), 's/g %.0f vs %.0f'%(tn,tb), 'same', same)
