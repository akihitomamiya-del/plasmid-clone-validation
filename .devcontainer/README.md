# .devcontainer — runtime image + Claude-Code sandbox

Two-artifact layout (the L3R-seq pattern, **adapted** for this repo's offline-Apptainer design):

| path | what it is | published? |
|---|---|---|
| `build/` | the **runtime image** → `ghcr.io/akihitomamiya-del/plasmid-clone-validation:latest` — base + Java + Nextflow + Apptainer + seqkit + the **6 baked SIFs** (5 clone-val + wf-amplicon) + workflow code + our scripts + the amplicon annotation. Lean (~6 GB), fully offline. | **yes** — GHCR `:latest`/`:0.2.0`, via `../.github/workflows/docker-publish.yml` |
| `claude-code/` | **builds** the **Claude-Code sandbox** — `FROM` the runtime image; adds node + Claude CLI + egress firewall + sudo-lockdown. The agent-containment layer; the only part that changes when Claude updates. | **yes** — GHCR `:claude-code`/`:claude-code-0.2.0` |
| `claude-code-image/` | **pulls** that prebuilt sandbox (`image: …:claude-code`) — same firewalled yolo sandbox, **no local build**. | — (pulls `:claude-code`) |
| `devcontainer.json` (here) | **default** config — run the pipeline straight from the published runtime image (no Claude, no firewall). | — |

Pick a config in **"Dev Containers: Reopen in Container"**: default (pipeline), **`claude-code-image`** (yolo sandbox, **pull** — no build), **`claude-code`** (build the sandbox locally), or **`build`** (iterate the runtime image).

## Why Apptainer in the devcontainer (deliberate — *not* L3R-seq's conda model)
The workflow runs each step in an ONT container via **rootless Apptainer**, nested inside the devcontainer.
Apptainer shares the container's network namespace, so the egress firewall's `OUTPUT` allowlist governs the
workflow processes too — no DinD, no daemon, no `--privileged`, no `FORWARD`/NAT bypass. The 5 SIFs are baked
into the runtime image, so a run on local FASTQs needs **zero registry egress** (the firewall stays closed).
This needs `seccomp=unconfined` + `systempaths=unconfined` + `/dev/fuse` + the scoped **`pcv-apptainer`**
AppArmor profile (host prereq below).

## Claude yolo-mode containment (the security model)
The sandbox runs Claude with `--dangerously-skip-permissions`. The **egress firewall is the primary
guardrail** — it is *egress-only* (see Scope) and stays un-removable by the agent **only because the agent
runs non-root** (keep it that way — see the invariant below):
- **No blanket sudo.** The base image's `vscode ALL=(root) NOPASSWD:ALL` is removed; only two scoped,
  root-owned, argument-less scripts are sudo-able: the firewall (re-apply only) and the `/opt/nextflow`
  ownership helper. The agent can't `iptables -F`.
- **Claude installed as root** (global prefix root-owned) — the agent can't modify/replace its own CLI or
  `npm i -g` anything. (We deliberately do **not** use a vscode-writable npm prefix.)
- **Fail-open hardened** — `start-firewall.sh` unlinks a pre-planted `/tmp/firewall-status` before writing it;
  the warning banner is wired into `~/.bashrc`.
- **AppArmor `pcv-apptainer (enforce)`** denies sensitive `/proc`,`/sys` even though Apptainer opens userns.

**Scope — what this contains, and what it does NOT.** The firewall blocks outbound exfil/C2 to
non-allowlisted *internet* hosts. It does **not** cover:
- **The host filesystem.** The workspace is bind-mounted **read-write**, so a prompt-injected agent can
  edit host files — `.git/hooks`, the host-run `setup-host-apparmor.sh` (executed `sudo` on the host),
  `devcontainer.json` (next rebuild), the firewall *source* — and can write the API token to disk.
- **Your repo, via `git push`.** GitHub is allowlisted and `git` is present, so the agent can push commits
  to your repo; they then re-enter the host on the next `pull`. Protect with branch rules + (optionally) a
  `git push` `ask` rule, below.
- **Pipeline outputs.** `runs/` and `NXF_HOME` (`/opt/nextflow`) are agent-writable, so don't trust
  unreviewed results. (The baked **SIF cache is NOT** agent-writable — the offline workflow images can't be
  swapped.)
- **The local Docker subnet — but NOT your physical LAN, in the shipped config.** The `HOST_NETWORK` rule
  in `init-firewall.sh` allows the container's default-route **/24**, which under the **bridge** networking
  this devcontainer uses (no `--network=host` in `runArgs`) is the *Docker bridge* subnet — the host gateway
  plus any sibling containers, **not** your lab LAN / sequencer (a different subnet, which the final
  `OUTPUT … REJECT` drops). ⚠ This holds only in bridge mode: if you ever add `--network=host`, that same
  /24 rule becomes your **real LAN** and the agent could reach lab machines — don't. To also bar sibling
  containers, narrow the rule from `$HOST_NETWORK` to the gateway `$HOST_IP/32`.

**No command policy ships — by design.** Containment here is *structural*, not a command blocklist: the
contained agent has no internet off the allowlist, can't escape to the host, and **can't `sudo`** (the base
image's blanket sudo is stripped; only three scoped, argument-less scripts are sudo-able). Destructive
*local* actions (`rm`, `git push`, …) are deliberately left to you — you run the agent and review what it
does. If you want extra gating, add your own `settings.json` rules; prefer an **`ask`** rule (it still
prompts at action time under `--dangerously-skip-permissions`) over a hard `deny`, so it catches the rare
high-impact case — e.g. `git push`, the one real exfil path — without blocking the times you *do* want it.

**Invariant — keep the agent non-root.** The firewall is un-removable because `vscode` has no `NET_ADMIN`
and cannot `iptables -F` (only root, via the two scoped sudo scripts, applies it). Under **rootful** Docker
this composes with a writable bind-mounted workspace: the non-root `vscode` is uid-matched to the host via
`updateRemoteUserUID`, so it owns the workspace *and* lacks the cap to flush the firewall. To preserve
containment: keep `remoteUser: vscode`/`node` (never `root`), keep the scoped sudo (no blanket
`NOPASSWD:ALL`), do **not** grant the agent `NET_ADMIN`, and do **not** bind-mount `/var/run/docker.sock`
(under rootful that is host root).

Validated end-to-end on a **rootful** uid-1001 host: firewall up, `example.com` blocked, `api.github.com`
reachable, `sudo iptables` denied, agent can't tamper with Claude, byte-identical assembly.

## Host prerequisite (one-time, admin)
On a host that hardens user namespaces (`apparmor_restrict_unprivileged_userns=1`, Ubuntu 23.10+), load the
profile **before** building:
```bash
sudo bash .devcontainer/setup-host-apparmor.sh
```
Else Docker errors *"apparmor profile pcv-apptainer not found"*. Rationale/revert: `../docs/host_userns_prereq.md`.
`runArgs` are **ignored by GitHub Codespaces** — build locally (VS Code / devcontainer-CLI).

## Building the runtime image locally (to iterate, or as an alternative to pulling)
```bash
docker build -f .devcontainer/build/Dockerfile \
  -t ghcr.io/akihitomamiya-del/plasmid-clone-validation:latest .
```
Then the `claude-code` + default configs resolve their `FROM`/`image` from the local tag. Per-user
`${devcontainerId}` volumes isolate Claude creds/history, so multiple users on one host don't collide. A
Claude bump rebuilds only the thin `claude-code` layer (~230 MB) — the runtime base/SIFs are untouched.
```bash
# inside the sandbox, smoke test:
nextflow info && apptainer --version && seqkit version && claude --version
ls /opt/sif-cache                                            # 6 ontresearch-*.img (5 clone-val + wf-amplicon)
./clone_validate.sh examples/plasmid/raw runs/cv auto            # Completed successfully / 5652
```

## Pulling the Claude-Code sandbox (no local build)
The sandbox image is published too, so you can skip the local build: pick the **`claude-code-image`** config,
or `docker pull ghcr.io/akihitomamiya-del/plasmid-clone-validation:claude-code`. Same firewalled yolo sandbox,
with node + Claude CLI + the amplicon/clone-val pipelines baked in. Set `CLAUDE_CODE_OAUTH_TOKEN` (or
`ANTHROPIC_API_KEY`) in your **host** env first — `claude /login` can't reach claude.ai through the firewall.
After a Claude bump, rebuild + republish the thin layer:
```bash
docker build -f .devcontainer/claude-code/Dockerfile \
  -t ghcr.io/akihitomamiya-del/plasmid-clone-validation:claude-code . \
  && docker push ghcr.io/akihitomamiya-del/plasmid-clone-validation:claude-code
```
