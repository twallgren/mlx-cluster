import socket, sys
port = int(sys.argv[1])
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('192.168.0.2', port))
s.listen(1)
conn, _ = s.accept()
for _ in range(500):
    data = conn.recv(64)
    conn.sendall(data)
