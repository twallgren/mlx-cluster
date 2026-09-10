# Setting up a distributed MLX inference cluster

A start-to-finish procedure: from Macs still in their boxes to a single large
model answering requests across all of them.

Follow it in order. Steps 1–4 are per-machine and mostly manual; steps 5–11
run from your own computer and are scripted. Budget an evening for a
first-time run, most of it spent waiting on downloads.

**What you need**

- Two or more Apple silicon Macs. More unified memory per node is worth more
  than more nodes; the "Max"/"Ultra" chips have substantially higher memory
  bandwidth than the base and "Pro" ones, and single-stream inference is
  bandwidth-bound.
- A Thunderbolt cable for each link. For a ring of N nodes you need N cables.
- A separate machine to drive the setup from. It is not part of the cluster
  and needs no special hardware.
- All nodes on the same Wi-Fi or LAN, and an account with the same username
  on each. `sudo` access on each node.

Throughout, `ai-1`, `ai-2`, `ai-3` are the node hostnames and `ai-1` is the
**controller** — the node that runs the server process and that you tunnel to.
Substitute your own names, and pass them with `--hosts`/`--user` to every
script if they differ from the defaults.

---

## 1. Prepare each Mac in person

Work through [`00_manual_checklist.md`](00_manual_checklist.md) at each
machine. It covers what cannot be done over SSH: Setup Assistant, hardware
verification while the return window is open, the FileVault/Automatic Login
trade-off, naming the Mac, and enabling Remote Login.

Do **not** do its step 8 (Local Network permission) yet — that one needs a
Python that does not exist until step 5.

Confirm from your own machine that every node answers:

```zsh
for n in 1 2 3; do ssh you@ai-$n.local exit && echo "ai-$n OK"; done
```

Password authentication is fine here. Key trust is the next step.

## 2. Distribute SSH keys

```zsh
./distribute_keys.zsh --hosts ai-1.local,ai-2.local,ai-3.local --user you
```

This sets up passwordless SSH from your machine to every node, **and from
the controller to every node including itself**.

Do not try to make this match the cabling. You are about to wire a
Thunderbolt *ring*, but SSH trust is a *star* centred on the controller,
travelling over ordinary Wi-Fi rather than over the Thunderbolt links. The
two topologies are independent: the ring carries tensors during inference,
SSH only starts the processes. The controller needs to reach every node,
including the one it shares no cable with. That last part is easy to
miss and not optional: `mlx.distributed_config` and `mlx.launch` treat the
controller as just another host in the list and SSH into it like any other.

## 3. Install the environment on every node

```zsh
./main.zsh --hosts ai-1.local,ai-2.local,ai-3.local --user you
```

For each node this disables sleep (so a lid-closed laptop keeps serving),
installs Homebrew, Python, a venv at `~/mlx-env`, and `mlx` + `mlx-lm`. It is
idempotent — re-run it freely.

Every node must end up with the **same Python version at the same absolute
path**. Equivalent is not enough; MLX launches the identical interpreter path
on each host.

```zsh
./run_on_all.zsh --no-tty -- '~/mlx-env/bin/python -c "import mlx.core as mx; print(mx.__version__)"'
```

## 4. Grant Local Network permission — in person, at each node

Now do **step 8 of the manual checklist**. This is the step that costs people
evenings.

macOS blocks same-subnet connections from binaries that are not Apple-signed,
and Homebrew's Python is one of them. `ping`, `nc`, `curl` and
`/usr/bin/python3` are all exempt, so every diagnostic you would naturally
reach for reports a perfectly healthy network while MLX fails to form its
ring with a generic connection error that says nothing about permissions.

At each machine, in Terminal locally — **not over SSH**, because the
permission prompt cannot appear in a headless session:

```zsh
~/mlx-env/bin/python -c "import socket; socket.create_connection(('<another-node-ip>', 22), 3)"
```

Click **Allow**, then confirm the venv's Python is listed and enabled under
System Settings → Privacy & Security → Local Network.

## 5. Install Tailscale on each node (recommended)

Interactive login, so it cannot be scripted. Worth the few minutes: `.local`
mDNS names stop resolving when your client is on a different Wi-Fi network,
which looks exactly like the cluster being down. Tailscale hostnames work
from anywhere.

Once Tailscale is on every node you can drop the `.local` suffix from the
`--hosts` you pass to the operating scripts, which is why their defaults are
bare `ai-1,ai-2,ai-3`.

## 6. Cable and configure the Thunderbolt ring

Cable a **physical ring**: `ai-1 → ai-2 → ai-3 → ai-1`. Then, from the
controller:

```zsh
ssh you@ai-1
~/mlx-env/bin/mlx.distributed_config \
  --hosts ai-1,ai-2,ai-3 \
  --over thunderbolt --auto-setup --backend ring \
  --output-hostfile cluster.json
```

This disables macOS's merged Thunderbolt Bridge and gives each cable its own
isolated point-to-point link.

> **Do not instead assign static IPs to the Thunderbolt Bridge service.** On a
> closed ring that is a bridging loop, and the bridge has no spanning-tree to
> break it.

If `--auto-setup` cannot apply the changes itself — its generic sudo probe
does not recognise command-specific passwordless-sudo rules — use the wrapper
instead, which applies the printed commands on every node and then verifies
real point-to-point traffic:

```zsh
./reconfigure_thunderbolt_ring.zsh
```

**Re-run that after every reboot.** macOS renumbers the Thunderbolt interfaces
across boots, so a mapping recorded earlier will silently point a rank at the
wrong physical interface. The resulting failure is deceptive: the cluster
initialises, collective operations pass, and only point-to-point send/receive
hangs — which is exactly what pipeline parallelism uses. Because MLX enqueues
distributed operations on the GPU stream, it surfaces as a GPU timeout rather
than as anything network-shaped.

`reboot_cluster.zsh` reboots and re-rings in one step, and is the right way to
reboot the cluster for that reason.

## 7. Add a Hugging Face token (only for gated models)

```zsh
./set_hf_token.zsh --hosts ai-1,ai-2,ai-3
```

Reads from `$HF_TOKEN` or prompts without echoing. Skip this if every model
you want is ungated.

## 8. Choose a model

Two ways to split a model across nodes, with different rules:

| | Pipeline (`--pipeline`) | Tensor parallel (default) |
|---|---|---|
| Splits | Whole layers | Weight matrices |
| Requires | Architecture implements `.pipeline()` | `num_attention_heads % N == 0` **and** `num_key_value_heads % N == 0`; on quantized models every sharded dimension ÷ N must also stay divisible by the quantization `group_size` (usually 64) |
| Speed here | Faster almost always | Slower — an all-reduce after every attention and MLP block |

Grouped-query attention has pushed key-value head counts down to 8 and 4, so
at `N=3` tensor parallelism fails outright for nearly everything off the
shelf. Treat tensor mode as the compatibility fallback, not the fast path.

Check a candidate's `config.json` against those rules **before** committing to
a large download. `switch_model.zsh --list` records the verified mode for
every model already tested here.

Start with a small one. `deepseek-v2-lite` is the fastest model in the
registry and the best first target.

## 9. Download the model once, then copy it over Thunderbolt

Every node needs the **complete** model on disk — sharding happens at load
time, not at download time.

```zsh
./predownload_model.zsh mlx-community/DeepSeek-V2-Lite-Chat-4bit-mlx
```

That downloads it on one node and prints the follow-up command to distribute
it to the others:

```zsh
./tb_link_addrs.zsh --from ai-1 --to ai-2 --rsync <path>
```

Copy over the **Thunderbolt addresses**, which is what `tb_link_addrs.zsh`
resolves for you, and not over hostnames. A bare hostname may resolve over a
VPN instead and transfer at a small fraction of the speed, with no error and
no warning — on this cluster that was 170KB/s against 340MB/s.

## 10. Launch it

```zsh
./switch_model.zsh deepseek-v2-lite
```

This stops whatever is running, launches the model in the mode its registry
entry records, waits for the server, and sends a verification request. Add
`--dry-run` first to see the exact command without touching the cluster.

Then confirm the split is real:

```zsh
./run_on_all.zsh --no-tty -- 'top -l 1 -n 0 | grep PhysMem'
```

Memory should rise on **every** node, each by roughly the model size divided
by the node count. If it rises on only one, you are not distributing — you are
running one copy and idling the rest.

> **Use `top`, not `ps`.** RSS badly undercounts MLX's Metal-backed
> allocations — it will report a couple of GB for a model using forty. Since
> per-node memory is how you tell a real split from silent replication, the
> wrong tool here means you cannot tell success from failure.

## 11. Use it

The server binds `127.0.0.1` on the controller only. Reach it over an SSH
tunnel:

```zsh
ssh -N -L 8088:127.0.0.1:18080 you@ai-1
```

It speaks the OpenAI chat-completions API, so any client that accepts a base
URL works:

```zsh
curl -s http://localhost:8088/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"Say hello."}],"max_tokens":64}'
```

Do not expose the server, SSH or Screen Sharing directly to the internet.

---

## Recommended follow-ups

```zsh
./install_battery_guardian.zsh     # laptops: stop a node before it dies at 0%
source ./cluster_aliases.zsh       # ai_switch_model, ai_ssh, ai_portforward, ...
./test_all_models.zsh              # verify and benchmark every registry model
```

`install_battery_guardian.zsh` matters more than it sounds for laptop nodes: a
MacBook that fully drains needs a **physical power-button press** to come back,
which defeats the point of an unattended cluster. Under sustained inference
load a 96W charger may not keep up with the draw.

## When something goes wrong

| Symptom | Most likely cause |
|---|---|
| Ring never forms; `ping` and `nc` look fine | Local Network permission not granted to the venv's Python (step 4) |
| Cluster starts, collectives pass, generation hangs | Stale Thunderbolt mapping after a reboot — re-run `reconfigure_thunderbolt_ring.zsh` |
| A GPU timeout (`kIOGPUCommandBufferCallbackErrorTimeout`) | Usually networking, not the GPU — MLX enqueues distributed ops on the GPU stream |
| Server accepts the request and never answers, nodes at a few GB | The architecture has no `.pipeline()`; the exception is raised on a worker thread that never signals the HTTP layer |
| Server hangs, nodes at 40–50GB wired with nothing running | Leaked GPU-wired memory — reboot the node; killing the process does not release it |
| Transfers crawling at a few hundred KB/s | Copying over a hostname that resolved via VPN instead of the Thunderbolt address |
| Completions truncated mid-sentence | `mlx_lm.server` defaults `--max-tokens` to 512; `switch_model.zsh` raises it to 8192 |
| A patch to `mlx`/`mlx-lm` silently vanished | `pip install --upgrade` overwrote an edited file under `site-packages`. Carry patches as commits on a fork and install editable |

Longer versions of each, with how they were diagnosed, are in
["Running a 235B model across three MacBooks"](https://taylorwallgren.com/distributed-ai-cluster.html).
