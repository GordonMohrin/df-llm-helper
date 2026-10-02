import re,sys,os,difflib
R="C:/Users/admin/claude gordons projects/dfpilot-public/lua"
L="C:/Users/admin/claude gordons projects/dwarf-fortress/lua/claude"
def norm(p):
    t=open(p,encoding='utf-8',errors='replace').read().lstrip('\ufeff')
    out=[]
    for ln in t.splitlines():
        # strip trailing comments crude: ' --' outside quotes
        s=ln; res='';q=None;i=0
        while i<len(s):
            c=s[i]
            if q:
                res+=c
                if c==chr(92): res+=s[i+1:i+2]; i+=1
                elif c==q: q=None
            else:
                if c in '"\'': q=c;res+=c
                elif s.startswith('--',i): break
                else: res+=c
            i+=1
        res=res.strip()
        if res: out.append(re.sub(r'\s+',' ',res))
    return out
files=[]
for f in sorted(os.listdir(R+"/claude")): files.append((R+"/claude/"+f,L+"/"+f))
for f in sorted(os.listdir(R)):
    if f.endswith('.lua'): files.append((R+"/"+f,L+"/"+f))
for a,b in files:
    if not os.path.exists(b): print("NOLIVE",a);continue
    A=norm(a);B=norm(b)
    d=[l for l in difflib.unified_diff(A,B,lineterm='',n=0) if not l.startswith(('---','+++','@@'))]
    print(("SAME " if not d else "DIFF %d "%len(d))+os.path.basename(a))
    if d and '-v' in sys.argv: print("\n".join(d[:int(sys.argv[2]) if len(sys.argv)>2 else 40]))
