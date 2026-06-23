# .devcontainer — runtime image + Claude-Code sandbox

Two-artifact layout (the L3R-seq pattern, **adapted** for this repo's offline-Apptainer design):

| path | what it is | published? |
|---|---|---|
| `build/` | the **runtime image** → `ghcr.io/akihitomamiya-del/plasmid-clone-validation` — base + Java + Nextflow + Apptainer + seqkit + the **5 baked SIFs** + workflow code + our scripts. Lean (~5.3 GB), fully offline. | **yes** — GHCR, via `../.github/workflows/docker-publish.yml` |
| `claude-code/` | the **Claude-Code sandbox** — `FROM` the runtime image; adds node + Claude CLI + egress firewall + sudo-lockdown. The agent-containment layer; the only part that changes when Claude updates. | no (built locally) |
| `devcontainer.json` (here) | **default** config — run the pipeline straight from the published runtime image (no Claude, no firewall). | — |

Pick a config in **"Dev Containers: Reopen in Container"**: default (pipeline), **`claude-code`** (yolo sandbox), or **`build`** (iterate the runtime image).

## Why Apptainer in the devcontainer (deliberate — *not* L3R-seq's conda model)
The workflow runs each step in an ONT container via **rootless Apptainer**, nested inside the devcontainer.
Apptainer shares the container's network namespace, so the egress firewall's `OUTPUT` allowlist governs the
workflow processes too — no DinD, no daemon, no `--privileged`, no `FORWARD`/NAT bypass. The 5 SIFs are baked
into the runtime image, so a run on local FASTQs needs **zero registry egress** (the firewall stays closed).
This needs `seccomp=unconfined` + `systempaths=unconfined` + `/dev/fuse` + the scoped **`pcv-apptainer`**
AppArmor profile (host prereq below).

## Claude yolo-mode containment (the security model)
The sandbox runs Claude with `--dangerously-skip-permissions`. The **egress firewall is the only guardrail**,
so it must be un-removable by the agent:
- **No blanket sudo.** The base image's `vscode ALL=(root) NOPASSWD:ALL` is removed; only two scoped,
  root-owned, argument-less scripts are sudo-able: the firewall (re-apply only) and the `/opt/nextflow`
  ownership helper. The agent can't `iptables -F`.
- **Claude installed as root** (global prefix root-owned) — the agent can't modify/replace its own CLI or
  `npm i -g` anything. (We deliberately do **not** use a vscode-writable npm prefix.)
- **Fail-open hardened** — `start-firewall.sh` unlinks a pre-planted `/tmp/firewall-status` before writing it;
  the warning banner is wired into `~/.bashrc`.
- **AppArmor `pcv-apptainer (enforce)`** denies sensitive `/proc`,`/sys` even though Apptainer opens userns.

Validated end-to-end on a uid-1001 host: firewall up, `example.com` blocked, `api.github.com` reachable,
`sudo iptables` denied, agent can't tamper with Claude, byte-identical assembly.

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
ls /opt/sif-cache                                            # 5 ontresearch-*.img
./clone_validate.sh example_rawdata runs/cv auto            # Completed successfully / 5652
```
