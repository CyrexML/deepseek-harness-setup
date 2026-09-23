#!/usr/bin/env python3
"""Context budget of one DSH session: where the tokens went, how many compactions, TTFT.

Usage:
  dsh-session-report.py <session-id-prefix | path to session.v2.jsonl(.zstd)> [-v]

An id prefix is looked up in ~/.dsh/sessions/*/; .zstd is unpacked through
dsh-unzstd.js (node, built-in zlib.zstdDecompressSync, multi-frame container).
Exact numbers come from llama-server usage per step (input+cacheRead = context,
outputTokens) and streaming chunks (reasoning/text by token). Values marked "~"
are estimates: characters/3.6 for tool results and system insertions.
"""
import json,sys,os,glob,subprocess,collections,statistics
CPT=3.6
def locate(arg):
    if os.path.exists(arg): return arg
    hits=[p for p in glob.glob(os.path.expanduser('~/.dsh/sessions/*/*/session.v2.jsonl.zstd')) if arg in p.split('/')[-2]]
    if len(hits)!=1: sys.exit(f'{len(hits)} sessions match {arg!r}: '+' '.join(h.split("/")[-2] for h in hits))
    return hits[0]
def load(path):
    if path.endswith('.zstd'):
        out='/tmp/dsh-session-report.jsonl'
        subprocess.run(['node',os.path.join(os.path.dirname(os.path.abspath(__file__)),'dsh-unzstd.js'),path,out],check=True,capture_output=True)
        path=out
    return [json.loads(l) for l in open(path) if l.strip()]
def txt(blocks):
    return ''.join(x.get('text','') for x in blocks if isinstance(x,dict))
def main():
    verbose='-v' in sys.argv; arg=[a for a in sys.argv[1:] if a!='-v'][0]
    ev=load(locate(arg))
    out=collections.Counter(); usage_out=0; res=collections.Counter(); resn=collections.Counter()
    um=collections.Counter(); umn=collections.Counter(); calls={}; ctx=[]; ttft=[]; steps=[]
    comp_ok=comp_err=0; comp_sum=0; shadow=0; st=None; cur=None; errs=collections.Counter(); turn_end=collections.Counter()
    for e in ev:
        t=e['type']; d=e.get('data',{})
        if t=='step/start': st=e['time']; cur={'turn':d['turn'],'step':d['step'],'ctx':0,'out':0,'R':0,'res':0,'calls':[]}
        elif t=='assistant/message':
            u=d.get('usage') or {}; usage_out+=u.get('outputTokens',0)
            c=u.get('inputTokens',0)+u.get('cacheReadTokens',0)
            if c: ctx.append(c)
            s=d.get('stream',[])
            t0=next((ch.get('time') or ch.get('time0') for ch in s if ch['type'] in('chunk','reasoning-chunks','text-chunks')),None)
            if t0 and st: ttft.append((t0-st)/1000)
            for ch in s:
                if ch['type'].endswith('-chunks') and 'texts' in ch: out[ch['type'][:-7]]+=len(ch['texts'])
            if cur: cur['ctx']=c; cur['out']+=u.get('outputTokens',0); cur['R']+=sum(len(ch['texts']) for ch in s if ch['type']=='reasoning-chunks')
        elif t=='tool/call':
            calls[d['callId']]=d['name']
            if cur: cur['calls'].append(f"{d['name']}({d['arguments'][:50]!s})".replace('\n',' '))
        elif t=='tool/result':
            name=calls.get(d['message']['source']['callId'],'?'); n=0
            for c in d['message']['content']:
                if c['type']=='tool-result':
                    cc=c.get('content'); n+=len(txt(cc)) if isinstance(cc,list) else len(str(cc))
            res[name]+=n; resn[name]+=1
            if cur: cur['res']+=n
        elif t=='step/end' and cur: steps.append(cur); cur=None
        elif t=='user/message':
            src=d.get('source',{}); k=src.get('kind','?')+(':'+src['plugin'] if src.get('plugin') else '')
            um[k]+=len(txt(d.get('content',[]))); umn[k]+=1
        elif t=='compaction/summary': comp_ok+=1; comp_sum+=(d.get('usage') or {}).get('outputTokens',0); shadow+=d.get('shadowedTokenCount',0)
        elif t=='compaction/end' and 'error' in d: comp_err+=1; errs[d['error'][:60]]+=1
        elif t=='turn/end': turn_end[d.get('reason',{}).get('kind','?')]+=1
    tot_stream=sum(out.values()); args_est=max(usage_out-tot_stream,0)
    rows=[('assistant reasoning',out['reasoning']),('assistant text',out['text']),('assistant tool-call args (usage-stream)',args_est)]
    rows+=[(f'tool result: {k} ({resn[k]}x)',int(v/CPT)) for k,v in res.most_common()]
    rows+=[(f'user-role: {k} ({umn[k]}x)',int(v/CPT)) for k,v in um.most_common()]
    tot=sum(v for _,v in rows)
    print(f"steps={len(steps)}  turns={len(turn_end)} ({dict(turn_end)})")
    print(f"compactions ok={comp_ok} failed={comp_err} {dict(errs) if errs else ''}  shadowed={shadow:,} summaries={comp_sum:,} tok")
    print(f"output tokens={usage_out:,}  reasoning={out['reasoning']:,} ({out['reasoning']/max(usage_out,1):.0%} of output)")
    if ctx: print(f"context at step: max={max(ctx):,} mean={int(statistics.mean(ctx)):,}")
    if ttft: s=sorted(ttft); print(f"TTFT s: p50={s[len(s)//2]:.1f} p90={s[int(len(s)*.9)]:.1f} max={s[-1]:.0f} sum={sum(s):.0f}")
    print(f"\n{'what entered the context':52} {'tokens':>9} {'share':>6}")
    for n,v in rows:
        if v: print(f"{n:52} {v:9,} {v/tot:6.1%}")
    print(f"{'TOTAL':52} {tot:9,}")
    if verbose:
        print('\nper step:')
        for s in steps: print(f"  t{s['turn']} s{s['step']:3} ctx={s['ctx']:6,} out={s['out']:5} R={s['R']:5} res={s['res']:6}c  {'; '.join(s['calls'])[:110]}")
main()
