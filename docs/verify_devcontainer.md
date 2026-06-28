# Verify the devcontainer (run these *inside* the VS Code container)

Quick checks confirming the `plasmid-clone-validation` devcontainer is correctly built, sandboxed, and
runs the pipeline. Open it first — VS Code **"Dev Containers: Reopen in Container"** — then run these in
its integrated terminal (you are the non-root `vscode` user; the repo is your working directory). A
**config** change (`devcontainer.json`) is itself tested from the **host**: **Rebuild**/Reopen applies the
new config — you can't test a config edit from inside the already-built container.

> **"Dev Containers: Reopen in Container" offers TWO configs** — both are the Claude-Code yolo sandbox
> (the **default pulls** the prebuilt `:claude-code`; **`claude-code`** *builds* it locally). See
> [`../.devcontainer/README.md`](../.devcontainer/README.md), authoritative for the internals:
>
> | Config (`devcontainer.json` location) | What it is | Has firewall? | Has Claude? |
> |---|---|---|---|
> | **default** (`.devcontainer/`) | the yolo sandbox, **pulled** prebuilt (`:claude-code`) | **yes** | **yes** |
> | **claude-code** (`.devcontainer/claude-code/`) | the same yolo sandbox, **built locally** | **yes** | **yes** |
>
> **Which checks apply where:**
> - **Both configs are the Claude-Code sandbox** (default = pull, `claude-code` = local build), so **§1
>   (firewall) and §5 (yolo Claude) apply to both** — both ship the firewall + Claude CLI.
> - **§2–§4 (runtime · rootless Apptainer · the offline assembly)** apply to **both** configs — both
>   `FROM` the same runtime image, so Apptainer + the baked SIFs + the AppArmor profile + the Claude CLI
>   are present in both.

> The one-time **host** setup (loading the `pcv-apptainer` AppArmor profile) is assumed done — it applies
> to **both** configs (each runs rootless Apptainer under `pcv-apptainer`). If the container failed
> to *start* with `apparmor profile pcv-apptainer not found`, do
> [`host_userns_prereq.md`](host_userns_prereq.md) on the host first, then reopen.

Pass criteria are summarized at the bottom.

---

## 1. The sandbox is in effect — **both configs**

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

The firewall **hardening** (fail-closed init, a pinned resolver, no blanket SSH, a launch gate, a
sudo-lockdown) adds checks (e)–(g). ⚠️ **They require the *republished* `:claude-code`** — the
currently-published image (what the **default** config pulls until you run
[`republish_prebuilt.md`](republish_prebuilt.md)) is **pre-hardening**, so (e)–(g) and the host raw-rule
check below pass only after that republish; the baseline firewall (a)–(b) is present either way. The
local-build **`claude-code`** config gets the hardening as soon as you rebuild from `main`:

```bash
# (e) DNS is PINNED to the configured resolver (resolution works; not open to arbitrary resolvers)
getent hosts api.github.com >/dev/null && echo "DNS resolves (good)" || echo "DNS broken (check the resolv.conf pin)"

# (f) Launch gate — `claude` is aliased to the guard, which refuses to start unless firewall-status==ok
type claude | grep -q claude-guarded && echo "launch gate wired (good)" || echo "launch gate MISSING (check ~/.bashrc)"

# (g) Sudo-lockdown — the agent can re-APPLY but NOT flush the firewall, and has no blanket sudo
sudo -n -l 2>/dev/null | grep -qE 'init-firewall|start-firewall' && echo "scoped firewall sudo (good)" || echo "scoped sudo missing (check)"
sudo -n iptables -F 2>/dev/null && echo "iptables -F ALLOWED (BAD)" || echo "iptables -F denied (good)"
```

**(host)** Confirm the raw ruleset reflects the hardening (the in-container `vscode` is denied `iptables`):
```bash
docker exec -u root <container> iptables -S OUTPUT | grep -E 'dport 53|dport 22|REJECT'
# expect: a `-d <resolver-ip>/32 ... --dport 53 ACCEPT` pin, NO `--dport 22` rule, a final REJECT
```

## 2. The runtime is present — **both configs**

Both configs `FROM` the runtime image, so all of these — including `claude` — are present in both:

```bash
apptainer --version          # apptainer version 1.3.x
nextflow info | head -3      # Version: 24.10.9 ...
seqkit version               # seqkit vX
java -version 2>&1 | head -1 # openjdk 17 ...
claude --version             # Claude Code CLI
```

## 3. Rootless Apptainer works (the core fix) — **both configs**

```bash
id -un                                                          # vscode  (non-root)
apptainer exec /opt/sif-cache/ontresearch-wf-common-*.img echo "rootless apptainer OK"
```
Success here is exactly what was blocked before the `pcv-apptainer` profile + `systempaths=unconfined`
runArgs — no sudo, no `--privileged`, global userns sysctl untouched. The baked SIFs are `root:root`
0755 (world-readable, deliberately **not** chowned), so `vscode` can `exec` them in either config.

## 4. End-to-end: reproduce the canu reference, offline (~a few minutes) — **both configs**

```bash
EXTRA_NF_ARGS="--assembly_tool canu --assm_coverage 60" PROFILE=singularity \
  ./clone_validate.sh examples/plasmid/raw runs/cv_canu 5000 5000 20 6000

cat runs/cv_canu/cloneval/sample_status.txt                    # expect: barcode69,Completed successfully,5652

# byte-identical to the reference assembly (not just the same length):
md5sum runs/cv_canu/cloneval/*/*.final.fasta 2>/dev/null || \
  find runs/cv_canu -name '*.fasta' -exec md5sum {} +          # expect md5: 2b78d8db…7538c
```
Nextflow drives a nested rootless Apptainer per process, entirely from the baked SIF cache (no registry
egress). Pass = **1 contig, 5,652 bp, "Completed successfully"** and **byte-identical** output
(md5 `2b78d8db…7538c`), matching `examples/plasmid/reference_run_canu/`.

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

Both configs are the Claude-Code yolo sandbox (default = pull, `claude-code` = local build), so **every
check applies to both** — the only caveat is that the **Firewall hardening** row needs the *republished*
`:claude-code` (the default pulls the pre-hardening image until then; see
[`republish_prebuilt.md`](republish_prebuilt.md)).

| Check | Applies to | Pass |
|---|---|---|
| Firewall (baseline) | both | `/tmp/firewall-status` = `ok`; `example.com` blocked, `api.github.com` reachable |
| Firewall **hardening** | both¹ | DNS resolves (pinned resolver); `claude` aliased to the launch guard; `sudo iptables -F` **denied**; (host) `iptables -S OUTPUT` shows the `:53` pin, **no** `:22`, final REJECT |
| AppArmor | both | `/proc/self/attr/current` = `pcv-apptainer (enforce)`; `/proc/kallsyms` read **denied** |
| Runtime | both | apptainer 1.3.x · nextflow **24.10.9** · seqkit · java 17 · `claude` — all report a version |
| Rootless Apptainer | both | `apptainer exec …wf-common….img` prints `rootless apptainer OK` as `vscode` |
| Pipeline | both | `sample_status.txt` = `Completed successfully, 5652` (one contig, 5,652 bp); md5 `2b78d8db…7538c` |
| Claude auth | both | `~/.claude` is `vscode`-owned & writable; `claude -p "…"` round-trips (no `401`) |
| Yolo | both | `claude --dangerously-skip-permissions` starts **only** with firewall `ok` |

¹ Needs the **republished** `:claude-code` (the default pulls the pre-hardening image until then).

In either config, if §1 fails-open (firewall not `ok`), capture the container log — Command
Palette → **"Dev Containers: Show Container Log"** — the firewall is the safety interlock for yolo mode.
Background: [`setup_and_plan.md`](archive/setup_and_plan.md) ·
[`host_userns_prereq.md`](host_userns_prereq.md) · [`decision_log.md`](decision_log.md) ·
[`../.devcontainer/README.md`](../.devcontainer/README.md).
