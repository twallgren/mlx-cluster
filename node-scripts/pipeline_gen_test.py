import time
import mlx.core as mx
from mlx_lm.utils import pipeline_load
from mlx_lm import generate

g = mx.distributed.init()
r = g.rank()
print(f'rank {r}: init OK', flush=True)

t = time.time()
model, tokenizer = pipeline_load('mlx-community/DeepSeek-V2-Lite-Chat-4bit-mlx')
print(f'rank {r}: pipeline_load OK in {time.time()-t:.1f}s', flush=True)

t = time.time()
out = generate(model, tokenizer, prompt='Say hi.', max_tokens=10, verbose=False)
print(f'rank {r}: generate OK in {time.time()-t:.1f}s -> {out!r}', flush=True)
