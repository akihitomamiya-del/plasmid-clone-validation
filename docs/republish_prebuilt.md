# Republish the prebuilt images — runbook (run on the HOST, not in the sandbox)

**Goal:** make the **default (prebuilt-pull) devcontainer config** — top-level `.devcontainer/devcontainer.json`,
which pulls `:claude-code` — carry everything on `main`: the **Arabidopsis DB** *and* the **firewall hardening**.

**Run all of this on a networked machine with Docker — NOT inside the sandbox** (its egress firewall blocks
the registry and there's no Docker in it). The machine already running your devcontainer is fine.

---

## Why two images (and why CI isn't enough)
- **runtime `:latest`** (`.devcontainer/build/Dockerfile`) — heavy (~6–7 GB): base + Apptainer + the 6 SIFs +
  the pipelines **+ the Arabidopsis DB** (`ENV ARAB_DB=/opt/pcv/arabidopsis_db`).
- **sandbox `:claude-code`** (`.devcontainer/claude-code/Dockerfile`) — thin (~230 MB), `FROM …:latest`: adds
  node + Claude CLI **+ the (now hardened) egress firewall**.
- The prebuilt config **pulls `:claude-code`**. So `:claude-code` must be rebuilt **FROM a fresh `:latest`** to
  carry both changes.
- **CI publishes ONLY the runtime** (on a `v*` tag / manual dispatch) and **never the sandbox**. So the
  sandbox step below is **always a manual host build+push**.

---

## Prereqs (once)
- Docker on a networked host; repo checked out on **`main`** at the merge (`87752e2` or later — `git pull` if
  it's a separate clone from the one bind-mounted into your devcontainer).
- A **GHCR PAT with `write:packages`**, exported as `$CR_PAT`.
- **Runtime build only:** `/dev/fuse` + ~30 GB free disk (it bakes SIFs). The **sandbox** build needs neither.
- To later *run* the container: load the AppArmor profile once — `sudo bash .devcontainer/setup-host-apparmor.sh`.

```bash
IMG=ghcr.io/akihitomamiya-del/plasmid-clone-validation
VER=v0.3.0          # pick your version (these are new features: Arab DB + reference-validation + firewall hardening)
echo "$CR_PAT" | docker login ghcr.io -u akihitomamiya-del --password-stdin
```

---

## Step 1 — publish the runtime `:latest` (carries the Arabidopsis DB)

> Skip Step 1 **only** if you want the firewall hardening now and can defer the Arab DB — then the sandbox in
> Step 2 builds FROM the *existing* `:latest` (hardening yes, Arab DB no).

**Option 1a — build on the host (reliable; needs `/dev/fuse`):**
```bash
docker build -f .devcontainer/build/Dockerfile -t "$IMG:latest" .
docker push "$IMG:latest"
docker tag "$IMG:latest" "$IMG:${VER#v}" && docker push "$IMG:${VER#v}"   # optional immutable, e.g. :0.3.0
```

**Option 1b — offload the heavy build to CI (no local Docker for this step):**
```bash
git tag "$VER" && git push origin "$VER"     # triggers "Publish runtime image to GHCR" -> :latest (+ the tag)
# or, no tag:  gh workflow run docker-publish.yml
gh run watch                                  # wait for it to finish BEFORE Step 2
```
> ⚠️ **Caveat:** CI bakes the SIFs *inside* the Docker build on a GitHub runner — this is **unverified** and may
> fail on disk/userns. If the run fails, fall back to **Option 1a**.

---

## Step 2 — publish the sandbox `:claude-code` (adds the firewall hardening, FROM the new runtime)

Thin layer — **any** networked Docker host, no `/dev/fuse`. `--pull` forces it to use the **fresh** `:latest`
base (not a cached old one).
```bash
docker build --pull -f .devcontainer/claude-code/Dockerfile -t "$IMG:claude-code" .
docker push "$IMG:claude-code"
# fresh immutable tag (last was :claude-code-0.2.1 — don't move it, bump):
docker tag "$IMG:claude-code" "$IMG:claude-code-${VER#v}" && docker push "$IMG:claude-code-${VER#v}"
```

---

## Step 3 — use the prebuilt config
In VS Code: **Reopen in Container** (the **default** config now pulls `:claude-code`). Then **Dev Containers:
Rebuild Without Cache** to force a fresh pull of `:claude-code` (nothing pins the image digest, so the new one
is fetched).
- Set `CLAUDE_CODE_OAUTH_TOKEN` (or `ANTHROPIC_API_KEY`) in your **host** env first — `claude /login` can't
  reach claude.ai through the firewall. Use a long-lived `claude setup-token`, not a normal login token.

---

## Step 4 — verify the new container (inside it)
```bash
# Arabidopsis DB baked:
ls /opt/pcv/arabidopsis_db && printenv ARAB_DB                         # dir exists + ARAB_DB set
# Firewall hardening live:
grep -q 'trap .*DROP' /usr/local/bin/init-firewall.sh && echo 'fail-closed trap OK'
ls /usr/local/bin/claude-guarded.sh && type claude                    # launch gate present + aliased
cat /tmp/firewall-status                                              # ok
```
Full pass-criteria (DNS pin, no `tcp/22`, scoped sudo, host raw-rule check): `docs/verify_devcontainer.md` §1
checks (e)–(g). Or just tell Claude "verify the new container" and it'll run the lot.
