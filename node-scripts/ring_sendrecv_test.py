import time
import mlx.core as mx

g = mx.distributed.init()
r, n = g.rank(), g.size()
print(f'rank {r}/{n} init OK', flush=True)

# Mirror the pipeline pattern: rank r receives from r+1, sends to r-1
x = mx.zeros((4,), dtype=mx.float32)
t = time.time()
try:
    if r < n - 1:
        x = mx.distributed.recv_like(x, r + 1)
        mx.eval(x)
        print(f'rank {r}: recv from {r+1} OK in {time.time()-t:.2f}s -> {x.tolist()}', flush=True)
    if r != 0:
        y = mx.full((4,), float(r), dtype=mx.float32)
        y = mx.distributed.send(y, r - 1)
        mx.eval(y)
        print(f'rank {r}: send to {r-1} OK in {time.time()-t:.2f}s', flush=True)
    print(f'rank {r}: DONE in {time.time()-t:.2f}s', flush=True)
except Exception as e:
    print(f'rank {r}: FAILED after {time.time()-t:.2f}s -> {type(e).__name__}: {e}', flush=True)
