#!/bin/zsh
~/mlx-env/bin/python -c "
import socket
s=socket.socket(); s.settimeout(4)
try: s.connect((\"192.168.0.5\",32399)); print(\"OK\")
except Exception as e: print(\"FAIL\",getattr(e,\"errno\",None))
" > /tmp/probe_out.txt 2>&1
