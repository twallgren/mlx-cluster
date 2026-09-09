import socket, sys, time

def run(nodelay, port):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    if nodelay:
        s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    s.connect(('192.168.0.2', port))
    start = time.time()
    for _ in range(500):
        s.sendall(b'x' * 32)
        s.recv(64)
    elapsed = time.time() - start
    s.close()
    return elapsed

port = int(sys.argv[1])
mode = sys.argv[2]
elapsed = run(mode == 'nodelay', port)
print(f'{mode}: {elapsed:.3f}s for 500 round-trips ({elapsed/500*1000:.2f}ms/rt)')
