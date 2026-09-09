import mlx.core as mx
g = mx.distributed.init()
r, n = g.rank(), g.size()
# Give each rank a DIFFERENT sized local array on axis 0 - 5/6/6 rows, e.g.
sizes = [5, 6, 6]
local_size = sizes[r % len(sizes)]
x = mx.full((local_size, 4), float(r))
try:
    y = mx.distributed.all_gather(x)
    mx.eval(y)
    print(f'rank {r}: all_gather of UNEVEN shapes OK -> result shape {y.shape}', flush=True)
except Exception as e:
    print(f'rank {r}: all_gather of UNEVEN shapes FAILED -> {type(e).__name__}: {e}', flush=True)
