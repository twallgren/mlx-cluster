import mlx.core as mx
import time
g = mx.distributed.init()
r = g.rank()
print(f'rank {r} init OK, random.state[0] dtype={mx.random.state[0].dtype} shape={mx.random.state[0].shape}', flush=True)

t = time.time()
s = mx.distributed.all_sum(mx.random.state[0])
mx.eval(s)
print(f'rank {r} all_sum(random.state[0]) OK in {time.time()-t:.3f}s dtype={s.dtype}', flush=True)

t = time.time()
seed = s.view(mx.uint64).item()
print(f'rank {r} .view(uint64).item() OK = {seed} in {time.time()-t:.3f}s', flush=True)
