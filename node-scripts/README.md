# Node-side scripts

Everything in this folder runs **on a cluster node** (ai-1/ai-2/ai-3),
not on the client. Most got created ad hoc, directly on the nodes, during
live debugging sessions rather than written and pushed from the client
like the scripts one level up — this folder is a client-side backup/mirror
of what's actually sitting in each node's home directory, pulled back so
it isn't only preserved on the nodes themselves.

Cleaned up 2026-09-04: the five near-duplicate single-model download
scripts were consolidated into `predownload_model.py` (used by
`../predownload_model.zsh`); a stale-IP network probe (`lan.py`) and
three redundant undocumented raw-socket listeners (`lis.py`, `lis2.py`,
`lisR.py`) were retired, from both this mirror and the actual nodes.

Files identical across all three nodes are here once. Files that only
existed on one or two specific nodes are noted below.

## Download

- **`predownload_model.py`** — takes a repo id as its one argument,
  downloads it via `huggingface_hub.snapshot_download`. Not meant to be
  run directly by hand — `../predownload_model.zsh` (client-side) pushes
  this over, launches it detached on the target node, checks whether the
  model's already fully downloaded first, and prints the follow-up
  `tb_link_addrs.zsh --rsync` command to distribute it to the other nodes.

## MLX ring diagnostics

Referenced by `../reconfigure_thunderbolt_ring.zsh` (`--verify-script`). Run through
`mlx.launch --backend ring --hostfile cluster.json -- ~/mlx-env/bin/python <script>`
from the controller.

- `ring_test.py` — minimal `mx.distributed.init()` connectivity check.
- `ring_sendrecv_test.py` — exercises point-to-point `send`/`recv` in the
  pipeline-parallel direction (rank *r* receives from *r+1*, sends to
  *r-1*) — collectives-only tests miss this path entirely, which is
  exactly what the stale-Thunderbolt-mapping bug slipped through (see
  "Thunderbolt networking" in `../README.md`).
- `ring_allsum_test.py` — minimal `all_sum` collective check.
- `ring_seed_test.py` — checks `all_sum` + `.view(uint64)` on the RNG
  state specifically (seed-sync diagnostics).
- `allgather_uneven_test.py` — `all_gather` with a genuinely different
  local shape per rank (5/6/6 rows) — checks MLX handles uneven
  gather, relevant background for the uneven-tensor-parallel-sharding work.
- `pipeline_gen_test.py` — end-to-end pipeline `pipeline_load` + `generate`
  smoke test against DeepSeek-V2-Lite (the reference "known-good, fast"
  model).

## Raw network probes

- `tb.py` — raw TCP connect probe to the three Thunderbolt point-to-point
  IPs (`192.168.0.5/.2/.10`) on the MLX ring port. Current IP scheme,
  still accurate as of this writing — but these IPs get renumbered across
  reboots; don't trust them
  without re-checking `ifconfig` first.
- `probe.sh` — same idea as `tb.py`, one-IP version, writes to
  `/tmp/probe_out.txt` (used when testing from inside a context where
  capturing stdout directly was awkward).
- `t.py` — combined "does this Python have `mlx` importable" + "can it
  reach `192.168.0.5:32323`" check — the exact test that caught the
  Local Network Privacy issue (Homebrew Python silently blocked, Apple-
  signed tools like `ping`/`nc` exempt and misleadingly healthy).
- `nodelay_test_client.py` / `nodelay_test_server.py` (client on ai-1,
  server on ai-2 in the original run) — measures round-trip latency with
  and without `TCP_NODELAY`, for isolating Nagle's-algorithm-style
  latency issues from genuine connectivity failures.
- `pp_client.py` / `pp_server.py` (client on ai-2, server on ai-1) —
  simple ping-pong throughput/latency probe, precursor to the more
  targeted `nodelay_test_*` pair above.
