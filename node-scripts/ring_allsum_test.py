import mlx.core as mx
import time
g = mx.distributed.init()
print(f'rank {g.rank()}/{g.size()} init OK', flush=True)
t = time.time()
x = mx.distributed.all_sum(mx.array([1.0]))
mx.eval(x)
print(f'rank {g.rank()} all_sum OK = {x.item()} in {time.time()-t:.3f}s', flush=True)
