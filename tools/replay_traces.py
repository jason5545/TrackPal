#!/usr/bin/env python3
"""把 ~/Library/Logs/TrackPal.traces.jsonl 的逐幀軌跡，丟進
HorizontalStripIntentGate 的 Python 複本重算，用來在改門檻之前先看結果。

用法：
    python3 tools/replay_traces.py                # 預設門檻，列出每筆下方／上方區接觸
    python3 tools/replay_traces.py --summary      # 只印「實際結果 → 重算結果」的統計
    python3 tools/replay_traces.py D=0.04 slope=0.3 --summary   # 改門檻試算

可調的參數：D、DC（一般／較嚴的水平淨位移）、T、TC（最短持續時間）、
slope（往內側的斜度上限）、descent（往邊緣靠的斜度上限）、wander（路徑上限）、
window（游標活動後多久內算接力）、
scrollWindow（水平捲動後多久內算接著捲）。

注意：這是 TrackPal/Sources/HorizontalStripIntentGate.swift 的手寫複本，
Swift 那邊改了判斷邏輯，這裡要跟著改，否則重算結果不代表實機行為。
"""
import json, os, math, sys
A=1.6
class Gate:
    def __init__(s, strip, after_pointer, after_scroll=False, **kw):
        s.strip=strip; s.after=after_pointer; s.after_scroll=after_scroll
        s.D=kw.get('D',0.05); s.DC=kw.get('DC',0.08); s.T=kw.get('T',0.12); s.TC=kw.get('TC',0.20)
        s.slope=kw.get('slope',0.25); s.descent=kw.get('descent',1.0); s.axis=0.8; s.pathc=0.75; s.mind=3
        s.rejv=0.03; s.rejs=0.5; s.exit=0.02; s.wander=kw.get('wander',0.25); s.pause=0.18; s.prad=0.004; s.wmax=1.2; s.rest=0.025
        s.td=None; s.org=None; s.last=None; s.still=None; s.need=False; s.px=0; s.pl=0; s.n=0; s.maxexc=0; s.dec='pending'
    def cautious(s): return s.after and not s.after_scroll
    def anchor(s,p): s.org=p; s.last=p; s.still=p; s.px=0; s.pl=0; s.n=0
    def interrupt(s):
        if s.dec!='pending': return s.dec
        if s.maxexc>=s.rest: s.dec='reject:interruptedAfterTravel'; return s.dec
        s.need=True; return s.dec
    def observe(s,x,y,t):
        if s.dec!='pending': return s.dec
        p=(x*A,y,t)
        if s.td is None: s.td=p; s.anchor(p); return s.dec
        s.maxexc=max(s.maxexc, math.hypot(p[0]-s.td[0],p[1]-s.td[1]))
        if p[1]>s.strip+s.exit: s.dec='reject:leftStrip'; return s.dec
        if s.need: s.need=False; s.anchor(p); return s.dec
        dx=p[0]-s.last[0]; dy=p[1]-s.last[1]
        s.px+=abs(dx); s.pl+=math.hypot(dx,dy); s.n+=1; s.last=p
        nx=abs(p[0]-s.org[0]); sy=p[1]-s.org[1]; inward=max(0,sy); toward_edge=max(0,-sy)
        if inward>=s.rejv and inward>s.rejs*nx: s.dec='reject:verticalMovement'; return s.dec
        c=s.cautious(); D=s.DC if c else s.D; T=s.TC if c else s.T
        straight = (s.n>=s.mind and p[1]<=s.strip and nx>=D and inward<=s.slope*nx and toward_edge<=s.descent*nx
                    and s.px>0 and nx/s.px>=s.axis and s.pl>0 and math.hypot(nx,sy)/s.pl>=s.pathc)
        if straight:
            if p[2]-s.org[2]>=T: s.dec='activate'; return s.dec
        elif s.pl>=s.wander: s.dec='reject:wandering'; return s.dec
        if math.hypot(p[0]-s.still[0],p[1]-s.still[1])>s.prad: s.still=p; paused=False
        else: paused = p[2]-s.still[2]>=s.pause
        expired = p[2]-s.org[2]>=s.wmax
        if paused or expired:
            if s.maxexc>=s.rest: s.dec='reject:'+('pausedAfterTravel' if paused else 'stalledAfterTravel'); return s.dec
            s.anchor(p)
        return s.dec

def replay(row, **kw):
    gap=row.get('pointerGap')
    after = gap is not None and 0<=gap<kw.get('window',0.7)
    sgap=row.get('scrollGap')
    after_scroll = sgap is not None and 0<=sgap<kw.get('scrollWindow',1.0)
    g=Gate(row['stripDepth'], after, after_scroll, **kw)
    t_dec=None
    for fr in row['frames']:
        t,x,y,state,dens,maj,mn,valid=fr
        if not valid:
            d=g.interrupt()
        else:
            d=g.observe(x/10000,y/10000,t/10000)
        if d!='pending' and t_dec is None: t_dec=t/10000
    return g.dec, t_dec, after

if __name__=='__main__':
    import collections
    args=[a for a in sys.argv[1:] if '=' in a]
    summary='--summary' in sys.argv
    kw={k:float(v) for k,v in (a.split('=',1) for a in args)}
    rows=[]
    for name in ('TrackPal.traces.previous.jsonl','TrackPal.traces.jsonl'):
        p=os.path.expanduser('~/Library/Logs/'+name)
        if os.path.exists(p):
            for line in open(p,encoding='utf-8'):
                line=line.strip()
                if line:
                    try: rows.append(json.loads(line))
                    except ValueError: pass
    table=collections.Counter()
    for r in rows:
        if r['zone'] not in ('bottomEdge','topEdge') or not r['frames']: continue
        dec,t,after=replay(r, **kw)
        table[(r['outcome'].split(':')[0], dec)]+=1
        if summary: continue
        f=r['frames']
        print(f"#{r['id']:<5} {r['date'][5:19]} actual={r['outcome'][:32]:32} replay={dec:30} at={'-' if t is None else round(t,3)} after={int(after)} dur={r['dur']} start=({f[0][1]/10000:.3f},{f[0][2]/10000:.3f}) end=({f[-1][1]/10000:.3f},{f[-1][2]/10000:.3f}) pix={r['pixels'][0]}")
    print('--- actual → replay')
    for (actual,dec),count in sorted(table.items(), key=lambda kv:-kv[1]):
        print(f"{count:6}  {actual:22} → {dec}")
