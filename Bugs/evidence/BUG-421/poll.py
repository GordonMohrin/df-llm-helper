import subprocess,time,sys
EXE="E:/Program Files (x86)/Steam/steamapps/common/Dwarf Fortress/hack/dfhack-run.exe"
HACK="E:/Program Files (x86)/Steam/steamapps/common/Dwarf Fortress/hack"
n=int(sys.argv[1]); out=open("poll.log","w")
t0=time.time()
for i in range(n):
    t=time.time()
    p=subprocess.run([EXE,"claude/alert"],cwd=HACK,capture_output=True)
    dt=time.time()-t
    out.write(f"{time.time()-t0:7.1f} {dt:.2f}\n"); out.flush()
    time.sleep(1.0)
