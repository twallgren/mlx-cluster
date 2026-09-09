# MLX cluster bring-up

Scripts for building and operating a small distributed MLX inference
cluster out of Apple silicon Macs — provisioning the nodes from a client
machine, then downloading, distributing and switching the model that runs
across them.

Written for and tested on three 64GB M1 Max MacBook Pros wired into a
Thunderbolt ring (192GB pooled), running models up to Qwen3-235B-A22B at
4-bit. Nothing here is specific to three nodes or to that hardware; every
script takes `--hosts`.

Every script supports `-h`/`--help`, and the ones that change something
support `--dry-run`. Hostnames default to `ai-1,ai-2,ai-3` and the SSH user
to `$USER` — override both with `--hosts` and `--user`.

The provisioning scripts default to `.local` mDNS names instead, because
they run before Tailscale is installed and mDNS is all that resolves at
that point. Once Tailscale is up, use the bare names everywhere: `.local`
stops resolving the moment your client joins a different Wi-Fi network,
and the failure looks exactly like the cluster being down.

## Start here

**Building one from scratch? Follow [`SETUP.md`](SETUP.md)** — a linear
procedure from unboxed Macs to a model answering requests. This README is
the reference for what each piece does once you know the shape of it.

Either way, the per-machine manual steps in
[`00_manual_checklist.md`](00_manual_checklist.md) come first. One of them —
granting Local Network permission to the venv's Python — is the difference
between a working cluster and a multi-evening debugging session, because
macOS blocks same-subnet connections from non-Apple-signed binaries while
leaving `ping` and `nc` exempt. Every diagnostic passes; only the thing you
care about fails.

## Order of operations

```
00_manual_checklist.md     per-node GUI setup (in person)
      ↓
distribute_keys.zsh        passwordless SSH: client → nodes,
                           controller → workers AND to itself
      ↓
main.zsh                   → configure_node.zsh on each node:
                             sleep off, Homebrew, Python, venv, mlx + mlx-lm
      ↓
[Local Network permission] checklist step 8 — needs the venv to exist first
      ↓
mlx.distributed_config     Thunderbolt ring + cluster.json (see below)
      ↓
predownload_model.zsh      fetch one model on one node, then
tb_link_addrs.zsh --rsync  copy it to the others over Thunderbolt
      ↓
switch_model.zsh <model>   launch it in the right mode

after every reboot:
reconfigure_thunderbolt_ring.zsh   (or reboot_cluster.zsh, which does both)
```

## The scripts

| Script | Runs on | What it does |
|---|---|---|
| `distribute_keys.zsh` | client | Installs SSH keys client → nodes and controller → all nodes including itself. |
| `main.zsh` | client | Orchestrates provisioning; pushes `configure_node.zsh` to each node. |
| `configure_node.zsh` | node | Disables sleep, installs Homebrew/Python/venv/mlx/mlx-lm. Idempotent. |
| `set_hf_token.zsh` | client | Writes a Hugging Face token to each node. Reads from `$HF_TOKEN` or a hidden prompt; never echoes or logs it. |
| `predownload_model.zsh` | client | Downloads one model's snapshot on a single node (default ai-1) via `node-scripts/predownload_model.py`, launched detached; skips it if already fully downloaded. Prints the follow-up `tb_link_addrs.zsh --rsync` command to distribute it. |
| `switch_model.zsh` | client | Stops whatever is running and launches a different model in the right parallelism mode. `--list`, `--status`, `--stop`. |
| `tb_link_addrs.zsh` | client | Derives the real direct Thunderbolt address between two nodes by matching subnets on both ends. Can drive an `rsync` over it. |
| `reconfigure_thunderbolt_ring.zsh` | client | Re-discovers the post-reboot Thunderbolt interface mapping, applies it through the command-specific passwordless-sudo rules, and verifies MLX point-to-point ring traffic. |
| `monitor_nodes.zsh` | client | Battery, CPU and thermal status across the cluster. |
| `run_on_all.zsh` | client | Runs one command on every node in sequence and reports a per-node exit status. The workhorse behind most ad hoc chores. |
| `reboot_cluster.zsh` | client | Reboots every node, waits for SSH, and re-establishes the Thunderbolt ring. The correct way to reboot the cluster, since a reboot invalidates the interface mapping. |
| `cluster_aliases.zsh` | client | Sourceable shell wrappers (`ai_switch_model`, `ai_ssh`, `ai_portforward`, `ai_run_on_all`, …). Thin wrappers only — no logic of its own. `ai_help` lists them. |
| `battery_guardian.zsh` | node | Kills local MLX processes below a battery threshold. Installed as a LaunchAgent by `install_battery_guardian.zsh`. |
| `install_battery_guardian.zsh` | client | Deploys `battery_guardian.zsh` to every node as a launchd agent (RunAtLoad, KeepAlive). Idempotent — re-run to update threshold/interval on all nodes. |
| `deploy_mlx_patch.zsh` | client | Pushes a hand-patched `mlx` source file into each node's installed venv, locating the destination by asking that node's own Python. For `mlx` core, which is a plain wheel rather than an editable install. |
| `test_all_models.zsh` | client | Walks the whole model registry, checks each one comes up and answers, and reports throughput and memory per model. `--both-modes` runs every model in pipeline *and* tensor for a direct comparison. Detects a hung run, distinguishes it from an unsupported-mode error, and reboots + re-rings + retries once before giving up. Composes `switch_model.zsh`. |

Everything above runs **on the client** (or is pushed from it to a node
for one invocation, like `configure_node.zsh`). `node-scripts/` is a
different thing: it's a mirror of ad hoc scripts that live directly on
the cluster nodes' own home directories, pulled back here so they're not
only preserved on the nodes themselves. See `node-scripts/README.md` for
what each one does and its status (still useful vs. superseded/stale).

## Thunderbolt networking

Cable a **physical ring** and let MLX configure it:

```zsh
mlx.distributed_config --hosts ai-1.local,ai-2.local,ai-3.local \
  --over thunderbolt --auto-setup --backend ring \
  --output-hostfile cluster.json
```

This disables macOS's merged Thunderbolt Bridge and gives each cable its
own isolated point-to-point link. **Do not instead assign static IPs to the
Thunderbolt Bridge service** — on a closed ring that is a bridging loop,
because the bridge has no spanning-tree. Earlier versions of this folder
had scripts that did exactly that; they were removed for this reason.

On this cluster, `--auto-setup`'s generic sudo probe does not recognize the
command-specific passwordless-sudo rules for `/sbin/ifconfig` and
`/sbin/route`. Use the helper below rather than copying an old mapping or
running the printed blocks by hand:

```zsh
reconfigure_thunderbolt_ring.zsh
```

It runs the discovery command on `ai-1`, applies the newly printed commands
on all three nodes using `sudo -n` and absolute `/sbin` paths, then runs the
MLX send/receive test. It stops safely if a command is no longer permitted.

**Re-run this after every reboot.** macOS renumbers the Thunderbolt
interfaces, so a mapping you recorded earlier will silently point a rank at
the wrong physical interface. The resulting failure is deceptive: the
cluster initialises, collective operations pass, and only point-to-point
send/receive hangs — which is what pipeline parallelism uses. Because MLX
enqueues distributed ops on the GPU stream, it surfaces as a GPU timeout
rather than anything network-shaped.

## Choosing a model

Two ways to split a model, with different rules:

- **Pipeline** (`--pipeline`) splits whole layers, and by design has no
  divisibility constraint: the code works out a remainder and gives the
  leftover layers to the low ranks. It requires only that the architecture
  implements `.pipeline()`.

  In practice the shipped implementation of that split was wrong for
  months. It derived each rank's starting offset from an adjusted per-rank
  size rather than from where the previous rank actually stopped, so
  whenever the layer count did not divide evenly the ranks disagreed about
  the boundaries and one or two layers were loaded but executed by nobody.
  The models still produced fluent text, which is why it went unnoticed.
  Fixed upstream in [mlx-lm#1816](https://github.com/ml-explore/mlx-lm/pull/1816);
  if you are pinned to anything older, check it.
- **Tensor parallel** (the default) splits weight matrices. Requires
  `num_attention_heads % N == 0` **and** `num_key_value_heads % N == 0`;
  for quantized models, every sharded dimension divided by `N` must also
  stay divisible by the quantization `group_size` (usually 64).

Grouped-query attention has pushed key-value head counts down to 8 and 4,
so at `N=3` tensor parallelism fails for nearly everything off the shelf.
`switch_model.zsh` records the correct mode per model so you don't have to
rediscover this; check a new model's `config.json` against the rules above
before committing to a large download.

## Upstream patches

Getting every model in the registry running took changes to MLX itself.
Most are now upstream, so a current `mlx`/`mlx-lm` needs fewer local
patches than this cluster originally carried — check before you go
debugging something that may already be fixed.

| Change | Status |
|---|---|
| [mlx-lm#1816](https://github.com/ml-explore/mlx-lm/pull/1816) — `PipelineMixin` dropping layers on uneven splits | Merged |
| [mlx#4465](https://github.com/ml-explore/mlx/pull/4465) — uneven tensor-parallel sharding in distributed linear layers | Open |
| [mlx-lm#1863](https://github.com/ml-explore/mlx-lm/pull/1863) — GQA/MLA-aware uneven sharding in `shard()` | Open |
| [mlx-lm#1862](https://github.com/ml-explore/mlx-lm/pull/1862) — `pipeline()` support for Qwen2 and Qwen3-Next | Open |
| [mlx-lm#1861](https://github.com/ml-explore/mlx-lm/pull/1861) — `qwen3_moe.py` `sanitize()` gating | Open |

If you do carry local patches, carry them as **commits on a fork** and
install editable — `configure_node.zsh --mlx-lm-git URL#branch`. See the
note in Operating notes below for why.

`deploy_mlx_patch.zsh` exists for the one case that cannot work that way:
`mlx` core ships as a plain wheel rather than an editable install, so a
patched file has to be copied into each node's `site-packages`.

## Operating notes

- **Verify memory with `top`, not `ps`.** RSS badly undercounts MLX's
  Metal-backed allocations — it will report a couple of GB for a model
  using forty. Per-node memory is how you tell a real split from silent
  replication, so the wrong tool here means you cannot tell success from
  failure.
- **Download once, then copy over the Thunderbolt addresses.** Every node
  needs the full model; sharding happens at load time. Use
  `tb_link_addrs.zsh` rather than hostnames — a bare hostname may resolve
  over a VPN and transfer at a fraction of the speed with no error.
- **Raise `--max-tokens`.** `mlx_lm.server` defaults to 512, which
  truncates any real coding or long-form task with no error;
  `switch_model.zsh` defaults it to 8192.
- **If you carry local patches to `mlx`/`mlx-lm`, make them commits.** Fork
  the repo, branch off `main`, and install editable
  (`configure_node.zsh --mlx-lm-git URL#branch`). A patch that exists only
  as an edited file under `site-packages` is one `pip install --upgrade`
  away from gone, and pip will not warn you. `configure_node.zsh` refuses
  to clobber an editable install or a hand-edited tree unless you pass
  `--force-pypi`.
- **A hung node needs a reboot, not just a kill.** Killing a wedged
  inference process does not reliably release the memory it had wired for
  the GPU; it stays wired below the process layer, where `ps` and `top`'s
  process list cannot see it. On this cluster all three nodes sat at
  43/54/39GB wired out of 64GB with no inference process running anywhere,
  and rebooting one — with the other two left untouched as a control —
  dropped it to 2GB while they did not move. Check wired memory with
  `vm_stat | grep wired` (or `top`'s `PhysMem` line) if a node seems
  stuck, and bound the KV cache with `--prompt-cache-bytes`, since an
  unbounded cache feeds the memory pressure this failure needs.
  `switch_model.zsh` sets a cap per model rather than one flat number: on
  identical machines what is left after the weights is not identical, so a
  value that is generous for an 8B model is most of the remaining headroom
  on a 200B one. Each model's cap is derived from its measured worst-node
  footprint; see the registry comment in `switch_model.zsh`.
- **Prefer pipeline to tensor parallelism.** Measured head to head on
  seven models with `test_all_models.zsh --both-modes`, pipeline wins
  almost everywhere and by up to 2.5x. Single-stream decoding is bound by
  memory bandwidth, so tensor mode's all-reduce after every attention and
  MLP block costs more latency than it recovers by splitting the compute,
  while pipeline pays two hops per token regardless of depth. Treat tensor
  mode as the compatibility fallback for architectures with no
  `.pipeline()` — Qwen2 being the one that matters here — not as the fast
  option.
- **Forcing an unsupported mode hangs rather than erroring.** A model whose
  architecture implements `shard()` but not `pipeline()` will accept
  `--mode pipeline` and then never respond: the model loads lazily on the
  first request, so the exception is raised on a worker thread that never
  signals the HTTP layer. It looks exactly like the wired-memory hang
  above. Wired memory tells them apart — flat at a few GB here, 40-50GB
  there — and the fixes differ, so check before rebooting anything.
- **Check upstream `main` before debugging.** `pip` gives you the latest
  *tagged* release, which on a fast-moving library can be months behind —
  some fixes are not in any tag yet.

## Security

The model server binds to `127.0.0.1` on the controller only, on port
18080 by default (`--port`). Reach it from
a client over an SSH tunnel:

```zsh
ssh -N -L 8088:127.0.0.1:18080 you@ai-1
```

Do not expose the server, SSH or Screen Sharing directly to the internet.
