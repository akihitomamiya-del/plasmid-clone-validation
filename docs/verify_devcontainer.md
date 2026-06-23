# Verify the devcontainer (run these *inside* the VS Code container)

Quick checks confirming the `plasmid-clone-validation` devcontainer is correctly built, sandboxed, and
runs the pipeline. Open it first — VS Code **"Dev Containers: Reopen in Container"** — then run these in
its integrated terminal (you are the non-root `vscode` user; the repo is your working directory).

> **"Dev Containers: Reopen in Container" now offers THREE configs** (commit `187381b` split the old
> single image — see [`../.devcontainer/README.md`](../.devcontainer/README.md), authoritative for the
> internals):
>
> | Config (`devcontainer.json` location) | What it is | Has firewall? | Has Claude? |
> |---|---|---|---|
> | **default** (`.devcontainer/`) | run the pipeline straight from the published runtime image | no | no |
> | **claude-code** (`.devcontainer/claude-code/`) | the yolo sandbox — runtime image + node + Claude CLI + egress firewall | **yes** | **yes** |
> | **build** (`.devcontainer/build/`) | iterate the lean runtime image (base + Java + Nextflow + Apptainer + the 5 baked SIFs) | no | no |
>
> **Which checks apply where:**
> - **§1 (firewall)** and **§5 (yolo Claude)** apply **only to the `claude-code` config** — only it ships
>   the firewall + Claude CLI. Skip them in `default`/`build`.
> - **§2–§4 (runtime · rootless Apptainer · the offline assembly)** apply to **any** config — all three
>   `FROM` the same runtime image, so Apptainer + the baked SIFs + the AppArmor profile are present
>   everywhere. (In `default`/`build`, omit the `claude --version` line of §2.)

> The one-time **host** setup (loading the `pcv-apptainer` AppArmor profile) is assumed done — it applies
> to **all three** configs (each runs rootless Apptainer under `pcv-apptainer`). If the container failed
> to *start* with `apparmor profile pcv-apptainer not found`, do
> [`host_userns_prereq.md`](host_userns_prereq.md) on the host first, then reopen.

Pass criteria are summarized at the bottom.

---

## 1. The sandbox is in effect — **`claude-code` config only**

(Checks (a)–(b) are the egress firewall; (c)–(d) confirm the AppArmor profile via the firewall-shipped
container. The AppArmor confinement itself is present in every config — §3/§4 exercise it there too.)

```bash
# (a) Egress firewall is up — the guardrail for `claude --dangerously-skip-permissions`
cat /tmp/firewall-status                       # expect: ok

# (b) The firewall actually governs egress (denied host blocked, allowlisted host reachable)
curl -sS --max-time 6 https://example.com    >/dev/null 2>&1 && echo "example.com    REACHABLE (BAD)"  || echo "example.com    blocked (good)"
curl -sS --max-time 6 https://api.github.com >/dev/null 2>&1 && echo "api.github.com reachable (good)"  || echo "api.github.com BLOCKED (check)"

# (c) Confined by OUR profile (not docker-default / unconfined)
cat /proc/self/attr/current                    # expect: pcv-apptainer (enforce)

# (d) The HARDENED profile is the one loaded — sensitive /proc reads are denied
head -c 16 /proc/kallsyms >/dev/null 2>&1 && echo "kallsyms READABLE (stale/broad profile — reload it)" || echo "kallsyms denied (hardened profile active)"
```

## 2. The runtime is present — **any config**

All three configs `FROM` the runtime image, so these are present everywhere — **except the last line
(`claude`), which exists only in the `claude-code` config**:

```bash
apptainer --version          # apptainer version 1.3.x
nextflow info | head -3      # Version: 24.10.9 ...
seqkit version               # seqkit vX
java -version 2>&1 | head -1 # openjdk 17 ...
claude --version             # Claude Code CLI    — claude-code config only
```

## 3. Rootless Apptainer works (the core fix) — **any config**

```bash
id -un                                                          # vscode  (non-root)
apptainer exec /opt/sif-cache/ontresearch-wf-common-*.img echo "rootless apptainer OK"
```
Success here is exactly what was blocked before the `pcv-apptainer` profile + `systempaths=unconfined`
runArgs — no sudo, no `--privileged`, global userns sysctl untouched. The baked SIFs are `root:root`
0755 (world-readable, deliberately **not** chowned), so `vscode` can `exec` them in any config.

## 4. End-to-end: reproduce the canu reference, offline (~a few minutes) — **any config**

```bash
EXTRA_NF_ARGS="--assembly_tool canu --assm_coverage 60" PROFILE=singularity \
  ./clone_validate.sh example_rawdata runs/cv_canu 5000 5000 20 6000

cat runs/cv_canu/cloneval/sample_status.txt                    # expect: barcode69,Completed successfully,5652

# byte-identical to the reference assembly (not just the same length):
md5sum runs/cv_canu/cloneval/*/*.final.fasta 2>/dev/null || \
  find runs/cv_canu -name '*.fasta' -exec md5sum {} +          # expect md5: 2b78d8db…7538c
```
Nextflow drives a nested rootless Apptainer per process, entirely from the baked SIF cache (no registry
egress). Pass = **1 contig, 5,652 bp, "Completed successfully"** and **byte-identical** output
(md5 `2b78d8db…7538c`), matching `reference_run_canu/`.

## 5. Yolo Claude (the point of the sandbox) — **`claude-code` config only**

```bash
# (a) Config dir is writable by vscode (else auth/onboarding can't persist)
ls -ld ~/.claude && touch ~/.claude/.wtest && rm ~/.claude/.wtest && echo "~/.claude writable (good)"

# (b) Token reached the container
echo "${CLAUDE_CODE_OAUTH_TOKEN:+token present}${CLAUDE_CODE_OAUTH_TOKEN:-NO TOKEN — set it in the host launch env}"

# (c) Non-interactive auth round-trip through the firewall (the real confirmation)
claude -p "Reply with exactly: AUTH_OK" --dangerously-skip-permissions    # expect: AUTH_OK

# (d) Interactive yolo — only with the firewall up
[ "$(cat /tmp/firewall-status)" = ok ] && claude --dangerously-skip-permissions \
  || echo "firewall NOT ok — do not run yolo"
```
Runs as non-root `vscode`; the firewall is the guardrail (confirm §1a/§1b first). Auth is the
`CLAUDE_CODE_OAUTH_TOKEN` / `ANTHROPIC_API_KEY` injected from the host env (interactive `claude /login`
won't work — the firewall blocks `claude.ai`). **Use a long-lived `claude setup-token`** for the host
env var, not a normal login's access token: access tokens expire in hours and can only refresh via
claude.ai (blocked here), so they die mid-session and can't renew. A `401 Invalid bearer token` from
(c) with a valid-looking token usually means it expired — regenerate with `claude setup-token`.

---

## Pass criteria

Scope: **any** = all three configs; **claude-code** = the yolo-sandbox config only.

| Check | Applies to | Pass |
|---|---|---|
| Firewall | claude-code | `/tmp/firewall-status` = `ok`; `example.com` blocked, `api.github.com` reachable |
| AppArmor | any | `/proc/self/attr/current` = `pcv-apptainer (enforce)`; `/proc/kallsyms` read **denied** |
| Runtime | any | apptainer 1.3.x · nextflow **24.10.9** · seqkit · java 17 (· `claude` in claude-code) — all report a version |
| Rootless Apptainer | any | `apptainer exec …wf-common….img` prints `rootless apptainer OK` as `vscode` |
| Pipeline | any | `sample_status.txt` = `Completed successfully, 5652` (one contig, 5,652 bp); md5 `2b78d8db…7538c` |
| Claude auth | claude-code | `~/.claude` is `vscode`-owned & writable; `claude -p "…"` round-trips (no `401`) |
| Yolo | claude-code | `claude --dangerously-skip-permissions` starts **only** with firewall `ok` |

In the **claude-code** config, if §1 fails-open (firewall not `ok`), capture the container log — Command
Palette → **"Dev Containers: Show Container Log"** — the firewall is the safety interlock for yolo mode.
Background: [`setup_and_plan.md`](archive/setup_and_plan.md) ·
[`host_userns_prereq.md`](host_userns_prereq.md) · [`decision_log.md`](decision_log.md) ·
[`../.devcontainer/README.md`](../.devcontainer/README.md).
