#!/usr/bin/env python3
"""predownload_model.py — download one HF model's snapshot on THIS node.

Run directly on a cluster node (not through mlx.launch — sharding happens
at load time, not download time, so this is plain single-process work).
Meant to be launched detached (nohup ... & disown) since large models take
a while; see predownload_model.zsh one level up for the client-side
wrapper that does that plus pushes this script over and tails the log.

Usage:
  python predownload_model.py <repo_id>
  python predownload_model.py mlx-community/GLM-4.5-Air-4bit
"""
import sys

from huggingface_hub import snapshot_download

if len(sys.argv) != 2:
    print(f"Usage: {sys.argv[0]} <repo_id>", file=sys.stderr)
    sys.exit(1)

repo_id = sys.argv[1]
path = snapshot_download(repo_id=repo_id)
print(f"DONE: {path}")
