import mlx.core as mx
g = mx.distributed.init()
print(f'rank {g.rank()} of {g.size()} connected OK')
