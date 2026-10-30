import sys,re
def norm(t): return re.sub(r"[^a-z0-9' ]"," ",t.lower()).split()
def wer(r,h):
    r,h=norm(r),norm(h);d=list(range(len(h)+1))
    for i in range(1,len(r)+1):
        p=d[:];d[0]=i
        for j in range(1,len(h)+1): d[j]=min(p[j]+1,d[j-1]+1,p[j-1]+(r[i-1]!=h[j-1]))
    return d[len(h)],len(r)
e,n=wer(open(sys.argv[1]).read(),open(sys.argv[2]).read());print(f"{sys.argv[2]}: {e}/{n} errors, WER {100*e/max(n,1):.2f}%")
