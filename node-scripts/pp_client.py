import socket, sys, time
host, port, size = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.settimeout(10)
t = time.time()
s.connect((host, port))
print(f'connected in {time.time()-t:.3f}s', flush=True)
payload = b'x' * size
t = time.time()
try:
    for i in range(200):
        s.sendall(payload)
        got = 0
        while got < size:
            got += len(s.recv(65536))
    el = time.time()-t
    print(f'200 round-trips of {size}B in {el:.3f}s ({el/200*1000:.2f}ms each)', flush=True)
except Exception as e:
    print(f'FAILED after {time.time()-t:.2f}s: {type(e).__name__}: {e}', flush=True)
