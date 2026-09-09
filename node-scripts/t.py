import sys, socket
if len(sys.argv)>1 and sys.argv[1]=="mlx":
    import mlx.core as mx; print("mlx imported", mx.__version__)
ok=0; bad=[]
for i in range(5):
    s=socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try: s.connect(("192.168.0.5",32323)); ok+=1
    except Exception as e: bad.append(repr(e))
    s.close()
print("ok",ok,"fail",len(bad), bad[:2])
