"""Exercise a real Ruby or Spinel server; no third-party client dependencies."""
import concurrent.futures
import http.client
import json
import os
import secrets
import shlex
import signal
import socket
import struct
import subprocess
import tempfile
import time
from pathlib import Path

root = Path(__file__).resolve().parent.parent
command = shlex.split(os.environ.get('DEMO_COMMAND', './build/bin/demo'))
with socket.socket() as probe:
    probe.bind(('127.0.0.1', 0))
    port = probe.getsockname()[1]
env = dict(os.environ, PORT=str(port), HOST='127.0.0.1', SPNL_SESSION_SECRET=secrets.token_hex(32), SPNL_COOKIE_SECURE='0')
log = tempfile.TemporaryFile(mode='w+b')
server = subprocess.Popen(command, cwd=root, env=env, stdout=log, stderr=log)

def request(path, method='GET', headers=None, body=None):
    client = http.client.HTTPConnection('127.0.0.1', port, timeout=8)
    client.request(method, path, body=body, headers=headers or {})
    response = client.getresponse()
    headers = dict(response.getheaders())
    headers['Set-Cookie-All'] = [v for k,v in response.getheaders() if k.lower()=='set-cookie']
    result = response.status, response.read(), headers
    client.close()
    return result

def exact(sock, size):
    data = b''
    while len(data) < size:
        chunk = sock.recv(size-len(data))
        if not chunk:
            raise EOFError('short websocket frame')
        data += chunk
    return data

def masked(opcode, payload, fin=True):
    mask = b'abcd'
    n = len(payload)
    length = bytes([128+n]) if n < 126 else b'\xfe'+struct.pack('!H', n) if n <= 65535 else b'\xff'+struct.pack('!Q', n)
    return bytes([(128 if fin else 0)|opcode])+length+mask+bytes(x ^ mask[i%4] for i,x in enumerate(payload))

def frame(sock):
    a,b = exact(sock,2)
    assert not b & 128
    n=b&127
    if n==126: n=struct.unpack('!H', exact(sock,2))[0]
    elif n==127: n=struct.unpack('!Q', exact(sock,8))[0]
    return a&15,exact(sock,n)

try:
    deadline=time.monotonic()+15
    while True:
        if server.poll() is not None: raise RuntimeError('server exited during startup')
        try:
            if request('/health')[0]==200: break
        except (OSError, http.client.HTTPException): pass
        if time.monotonic()>deadline: raise TimeoutError('server startup')
        time.sleep(.03)
    for path in ['/health','/bench','/users','/site/','/site/users','/uuid','/now','/gz']:
        assert request(path)[0]==200,path
    status,body,_=request('/bench','HEAD');assert status==200 and body==b''
    assert request('/bench','POST')[0]==405
    status,body,headers=request('/session');assert status==200
    user=json.loads(body)['user'];cookie=headers['Set-Cookie'].split(';')[0]
    assert json.loads(request('/session',headers={'Cookie':cookie})[1])['user']==user
    _,body,headers=request('/csrf');token=json.loads(body)['token'];cookie='; '.join(v.split(';')[0] for v in headers['Set-Cookie-All'])
    assert json.loads(request('/csrf/verify?token='+token,headers={'Cookie':cookie})[1])['valid'] is True
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        results=list(pool.map(lambda _:request('/bench'),range(40)))
    assert all(status==200 and body==b'spinel benchmark\n' for status,body,_ in results)
    with socket.create_connection(('127.0.0.1',port),timeout=5) as client:
        for piece in [b'GET /health HTTP/1.1\r\n',b'Host: localhost\r\n',b'\r\n']:
            client.sendall(piece);time.sleep(.01)
        assert b'200 OK' in client.recv(4096)
    with socket.create_connection(('127.0.0.1',port),timeout=5) as client:
        client.sendall(b'POST /upload HTTP/1.1\r\nHost: x\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\nx')
        assert b'400 Bad Request' in client.recv(4096)
    with socket.create_connection(('127.0.0.1',port),timeout=8) as client:
        client.sendall(b'GET /ws HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n')
        header=b''
        while not header.endswith(b'\r\n\r\n'):header+=exact(client,1)
        assert b'101 Switching' in header
        assert request('/health')[0]==200 # an idle WS must not monopolize the server
        client.sendall(masked(9,b'ping'));assert frame(client)==(10,b'ping')
        client.sendall(masked(1,b'hel',False)+masked(0,b'lo'));assert frame(client)==(1,b'echo: hello')
        binary=b'a\x00b'*22000
        client.sendall(masked(2,binary));assert frame(client)==(2,binary)
        client.sendall(masked(8,struct.pack('!H',1000)));assert frame(client)[0]==8
    status,body,_=request('/events');assert status==200 and body.count(b'event: tick')==3
    print('network: endpoints, session/CSRF, HEAD/405, 40 concurrent requests, framing, WebSocket control/fragment/binary and SSE passed')
finally:
    server.send_signal(signal.SIGTERM) if server.poll() is None else None
    try:server.wait(timeout=8)
    except subprocess.TimeoutExpired:
        server.kill();server.wait();raise AssertionError('graceful shutdown timed out')
    log.seek(0)
    output=log.read().decode(errors='replace')
    log.close()
    if server.returncode != 0:
        print(output)
        raise AssertionError('server exit '+str(server.returncode))
