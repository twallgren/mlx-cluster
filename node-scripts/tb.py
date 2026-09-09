import socket,sys
me=sys.argv[1]
for ip in ["192.168.0.5","192.168.0.2","192.168.0.10"]:
    s=socket.socket(); s.settimeout(4)
    try: s.connect((ip,32399)); print(f"  {me} -> {ip}  OK")
    except Exception as e: print(f"  {me} -> {ip}  FAIL errno={getattr(e,'errno',None)} {type(e).__name__}")
    s.close()
