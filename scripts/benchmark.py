"""Same payload, same connection-close policy, fixed worker CPU budget; JSON evidence."""
import argparse
import http.client
import json
import os
import platform
import re
import signal
import socket
import subprocess
import time
from pathlib import Path
p=argparse.ArgumentParser()
p.add_argument('--spinel',default='build/bin/demo')
p.add_argument('--go',required=True)
p.add_argument('--client',required=True)
p.add_argument('--requests',type=int,default=2000)
p.add_argument('--repeat',type=int,default=3)
p.add_argument('--output',default='benchmark-results.json')
args=p.parse_args()
root=Path(__file__).resolve().parent.parent
cpus=sorted(os.sched_getaffinity(0))
server_cpus=set(cpus[:2]);client_cpus=set(cpus[2:4] or cpus[:2])
results=[]
for label,binary in [('spinel',args.spinel),('go',args.go)]:
    with socket.socket() as probe:probe.bind(('127.0.0.1',0));port=probe.getsockname()[1]
    env=dict(os.environ,PORT=str(port),HOST='127.0.0.1',SPINEL_WORKERS='3',GOMAXPROCS='2')
    proc=subprocess.Popen([str(Path(binary).resolve())],cwd=root,env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,preexec_fn=lambda:os.sched_setaffinity(0,server_cpus))
    try:
        deadline=time.monotonic()+15
        while True:
            try:
                c=http.client.HTTPConnection('127.0.0.1',port,timeout=2);c.request('GET','/bench');r=c.getresponse();body=r.read();c.close()
                assert r.status==200 and body==b'spinel benchmark\n';break
            except OSError:
                if proc.poll() is not None or time.monotonic()>deadline:raise RuntimeError('server startup failed')
                time.sleep(.05)
        for concurrency in [1,10,50]:
            cmd=[str(Path(args.client).resolve()),'-url',f'http://127.0.0.1:{port}/bench','-n',str(args.requests),'-c',str(concurrency),'-body','spinel benchmark\n']
            subprocess.run(cmd[:-6]+['-n','100','-c',str(concurrency),'-body','spinel benchmark\n'],check=True,stdout=subprocess.DEVNULL,preexec_fn=lambda:os.sched_setaffinity(0,client_cpus))
            for trial in range(args.repeat):
                output=subprocess.check_output(cmd,text=True,preexec_fn=lambda:os.sched_setaffinity(0,client_cpus))
                results.append({'server':label,'concurrency':concurrency,'trial':trial+1,'rps':float(re.search(r'rps\s*:\s*([0-9.]+)',output)[1]),'raw':output})
        status=Path(f'/proc/{proc.pid}/status').read_text()
        rss=re.search(r'VmRSS:\s+(.*)',status)
        for row in results:
            if row['server']==label:row['rss_after_runs']=rss[1] if rss else None
    finally:
        proc.send_signal(signal.SIGTERM)
        try:proc.wait(timeout=8)
        except subprocess.TimeoutExpired:proc.kill();proc.wait()
evidence={'platform':platform.platform(),'server_cpus':sorted(server_cpus),'client_cpus':sorted(client_cpus),'spinel_workers':3,'go_maxprocs':2,'requests_per_run':args.requests,'connection_policy':'close','payload':'spinel benchmark\\n','results':results}
Path(args.output).write_text(json.dumps(evidence,indent=2)+'\n')
print('Wrote',args.output)
