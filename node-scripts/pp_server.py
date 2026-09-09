import socket, sys
port = int(sys.argv[1]); host = sys.argv[2]
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind((host, port)); s.listen(1)
print('listening', flush=True)
conn, addr = s.accept()
print(f'accepted from {addr}', flush=True)
for _ in range(200):
    d = conn.recv(65536)
    if not d: break
    conn.sendall(d)
print('done', flush=True)
