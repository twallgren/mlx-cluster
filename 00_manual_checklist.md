# Cluster bring-up: manual checklist (do this at each Mac, in person)

These steps require physical/GUI access and can't be scripted from the client
machine — do them once per node before running any script in this folder.
Background on why each of these matters: https://taylorwallgren.com/distributed-ai-cluster.html

Repeat for all three Macs (`ai-1`, `ai-2`, `ai-3`):

## 1. Setup Assistant

- [ ] Connect to Wi-Fi.
- [ ] Confirm **Remote Management** does NOT appear during setup. If it does,
      stop — the Mac may be MDM-enrolled from a prior owner. Do not proceed;
      this is grounds for an eBay return.
- [ ] Create your local operator account with a strong password.

## 2. Hardware verification (return window is open — check now)

- [ ] Chip is M1 Max, 64GB unified memory (About This Mac).
- [ ] SSD capacity matches listing.
- [ ] GPU core count matches listing.
- [ ] Display, all ports, charger present and working.
- [ ] Battery cycle count and condition acceptable (About This Mac → System
      Report → Power, or `system_profiler SPPowerDataType`).
- [ ] No Activation Lock tied to another Apple Account.

## 3. System hardening — and one real trade-off

- [ ] Software Update → update macOS fully.
- [ ] Decide on FileVault. **This is a genuine either/or, not a checkbox.**

**FileVault and Automatic Login cannot both be on.** FileVault's pre-boot
password prompt happens before macOS can read the auto-login preference —
that preference lives on the encrypted volume, which is not readable until
FileVault unlocks it. So you get one of:

| Choice | After an unattended reboot |
|---|---|
| FileVault **on** | Node sits at the pre-boot password screen until someone physically types it. The cluster is down until you walk over. |
| FileVault **off** + Automatic Login | Node boots back to a logged-in session and rejoins the cluster on its own. Disk is not encrypted at rest. |

For a headless node that must recover from crashes, macOS updates and
battery deaths without a person present, this cluster chose **FileVault
off with Automatic Login on**. That is a deliberate security trade — an
unencrypted disk in exchange for unattended recovery. Make it consciously,
and if the machines live somewhere physically untrusted, choose the other
way and accept the manual step.

Sleep is handled by `configure_node.zsh` (`sudo pmset -a disablesleep 1`),
not here — it keeps a MacBook Pro node running lid-closed with no external
display needed, which the System Settings sleep toggle alone can't do.

## 4. Name the Mac

- [ ] System Settings → General → About → Name → set to `ai-1` / `ai-2` /
      `ai-3` respectively.

## 5. Enable SSH (Remote Login)

- [ ] System Settings → General → Sharing → **Remote Login** → ON.
- [ ] Set **Allow access for** → **Only these users** → add your operator
      account.

## 6. Enable Screen Sharing (optional but recommended)

- [ ] System Settings → General → Sharing → **Screen Sharing** → ON,
      restricted to your account.

## 7. Confirm from the client machine

Before moving to the scripted steps, confirm each node answers over SSH on
the LAN (password auth is fine at this point — key trust gets set up next).
Substitute your own username:

```zsh
ssh you@ai-1.local exit && echo ai-1 OK
ssh you@ai-2.local exit && echo ai-2 OK
ssh you@ai-3.local exit && echo ai-3 OK
```

## 8. Local Network permission for Python — do this LAST, and in person

**Do this after `main.zsh` has created the venv**, since you need the Python
binary to exist. It cannot be done over SSH, and skipping it produces the
single most misleading failure in the whole setup.

macOS blocks same-subnet connections from binaries that aren't Apple-signed,
and Homebrew Python is one of them. `ping`, `nc`, `curl` and `/usr/bin/python3`
are all exempt — which means every diagnostic you reach for will report a
perfectly healthy network while MLX fails to form its ring, with a generic
connection error that says nothing about permissions.

- [ ] At the machine, run this **locally in Terminal** (not over SSH — the
      permission prompt cannot appear in a headless session):

      ```zsh
      ~/mlx-env/bin/python -c "import socket; socket.create_connection(('<another-node-ip>', 22), 3)"
      ```

- [ ] Click **Allow** on the Local Network prompt.
- [ ] Confirm afterwards in System Settings → Privacy & Security → Local
      Network that your venv's Python is listed and enabled.
- [ ] Repeat on all three nodes.

If the prompt never appears, toggle the entry off and on in that settings
pane and re-run. To verify for real, test with the *actual* venv Python
rather than a system tool — that distinction is the entire point of this
step.

## What's next (scripted, from the client machine)

1. `distribute_keys.zsh` — passwordless SSH: client → all three nodes, and
   the controller → every worker **and to itself**. The self-trust is easy
   to overlook: `mlx.distributed_config` and `mlx.launch` treat the
   controller as just another host in the list and SSH into it too.
2. `main.zsh` — disables sleep (lid-closed operation), then installs
   Homebrew/Python/MLX + MLX-LM on all three nodes at a matching version
   and identical path. The Python executable path must be identical
   everywhere, not merely equivalent.
3. Step 8 above (Local Network permission) — now that the venv exists.
4. Install Tailscale on each node (interactive login, not scriptable).
   Worth doing: `.local` mDNS names stop resolving when the client is on a
   different Wi-Fi network, which looks exactly like the cluster being
   down. Tailscale hostnames work from anywhere.
5. Cable a physical Thunderbolt ring, then from the controller run
   `mlx.distributed_config --over thunderbolt --auto-setup --backend ring
   --output-hostfile cluster.json`. **Re-run this after every reboot** —
   macOS renumbers the Thunderbolt interfaces, and reapplying a saved
   mapping puts a rank on the wrong physical interface. That failure is
   nasty: the cluster starts, collectives pass, and only point-to-point
   send/recv hangs.
6. `switch_model.zsh <alias>` to download, distribute and launch a model.
   Start with a small one and confirm memory rises on all three nodes
   before committing to a large download.
