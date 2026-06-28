# Build, publish, and test a new image — runbook (run on the HOST, not in the sandbox)

**What this is.** A straight-line recipe to bake your latest changes into a new container image, push it to
GitHub Container Registry (GHCR), then pull and test it locally. Do this whenever you change something that
lives **inside the image** — e.g. the Arabidopsis gene-name database (`build_arabidopsis_db.sh`), a pipeline
script, or the firewall.

**Run everything here on a normal networked machine with Docker — NOT inside the devcontainer.** The sandbox's
egress firewall blocks the registry and the gene-name download, and there's no Docker in it. A host terminal
(Terminal.app / PowerShell / a plain Linux shell) on the same computer is fine — the repo folder is shared.

---

## Who does what (important)

| Person | Does | Steps |
|---|---|---|
| **You** (build the image) | build → push → test the new image | this whole doc |
| **Your PI** (just uses it) | open the project; everything is already baked in | **only** the box below |

> ### For your PI — the entire instructions (no programming)
> 1. In VS Code: **Dev Containers: Reopen in Container**.
> 2. Then **Dev Containers: Rebuild Container Without Cache** (this pulls the newest published image).
> 3. Done — the gene names and everything else are already inside it.
>
> (One-time on their machine: a `CLAUDE_CODE_OAUTH_TOKEN` in the host env, and the AppArmor profile —
> `sudo bash .devcontainer/setup-host-apparmor.sh`. After that it's just the two clicks above.)

The PI's "Rebuild Without Cache" only **pulls** the image you publish — it does **not** rebuild anything. The
gene-name database is baked in by **you** in Step 1 below. That is the key point: *the image build is where the
data gets baked; the PI's rebuild just downloads the result.*

---

## The two images (why there are two)

- **runtime `:latest`** — heavy (~6–7 GB), `.devcontainer/build/Dockerfile`. Holds the pipelines, the 6
  workflow SIFs, **and the Arabidopsis gene-name DB** (`ENV ARAB_DB=/opt/pcv/arabidopsis_db`). The gene names
  are built **here**, at image-build time, when the network is open.
- **sandbox `:claude-code`** — thin (~230 MB), `.devcontainer/claude-code/Dockerfile`, `FROM …:latest`. Adds
  node + the Claude CLI + the egress firewall.

The default devcontainer config **pulls `:claude-code`**. So after changing anything in the runtime you must
rebuild **both**: `:latest` first, then `:claude-code` **FROM** the fresh `:latest`. (CI publishes **only** the
runtime, on a `v*` tag / manual dispatch — the sandbox is always a manual host build+push.)

---

## Prereqs (once)

```bash
# On the networked host, in the repo checked out on `main`:
IMG=ghcr.io/akihitomamiya-del/plasmid-clone-validation
VER=v0.3.0                      # bump this each release

# GHCR login (PAT needs write:packages):
echo "$CR_PAT" | docker login ghcr.io -u akihitomamiya-del --password-stdin
```
- Docker installed; for **Step 1** you also need **`/dev/fuse`** and ~30 GB free disk (it bakes the SIFs). The
  **sandbox** build (Step 2) needs neither.
- If this host is a *different* clone from the one bind-mounted into your devcontainer, `git pull` first so it
  has your latest `build_arabidopsis_db.sh`.
- To later *run* the container, load the AppArmor profile once: `sudo bash .devcontainer/setup-host-apparmor.sh`.

---

## Step 1 — build & push the runtime `:latest` (bakes the gene-name DB)

```bash
docker build -f .devcontainer/build/Dockerfile -t "$IMG:latest" .
docker push "$IMG:latest"
docker tag "$IMG:latest" "$IMG:${VER#v}" && docker push "$IMG:${VER#v}"   # optional immutable tag, e.g. :0.3.0
```

**About the cache (this is why the SIFs don't rebuild every time):** the 6 SIF layers sit *above* the script
COPY in the Dockerfile, so they stay cached. Because you **edited `build_arabidopsis_db.sh`**, Docker
invalidates the gene-name DB layer (and everything below it) automatically — so a **plain `docker build`
re-runs the DB build and bakes the new names, while reusing the cached SIFs.** Fast.

- **Force a totally fresh build** (rebuilds the SIFs too — slow; only if you suspect stale layers):
  `docker build --no-cache -f .devcontainer/build/Dockerfile -t "$IMG:latest" .`
- **Watch the build log** for the gene-name step — it prints, e.g.
  `aliases: named 968 previously un-named loci, added synonyms to 20617` then `ls -la /opt/pcv/arabidopsis_db`.
  (Order of magnitude: ~1k loci gain a real symbol + ~20k gain synonyms — BioMart mostly carries clone-id
  synonyms, which we keep as synonyms, never as the label. A `named 0` means the alias join didn't run.)
  If you see `WARNING: BioMart alias download failed`, the names did **not** bake — see
  [Gene names didn't appear?](#gene-names-didnt-appear) before pushing.

**No local Docker for the heavy build?** Offload to CI: `git tag "$VER" && git push origin "$VER"` triggers the
"Publish runtime image to GHCR" workflow (`gh run watch` to follow it; or `gh workflow run docker-publish.yml`
without a tag). You still do Step 2 by hand. (CI bakes SIFs on a GitHub runner — if it fails on disk/userns,
fall back to the local `docker build` above.)

---

## Step 2 — build & push the sandbox `:claude-code` (FROM the fresh runtime)

Thin layer — any networked Docker host, no `/dev/fuse`. `--pull` forces it onto the **new** `:latest` base.

```bash
docker build --pull -f .devcontainer/claude-code/Dockerfile -t "$IMG:claude-code" .
docker push "$IMG:claude-code"
# fresh immutable tag (last was :claude-code-0.2.1 — don't move it, bump):
docker tag "$IMG:claude-code" "$IMG:claude-code-${VER#v}" && docker push "$IMG:claude-code-${VER#v}"
```

---

## Step 3 — pull & open it locally

In VS Code: **Dev Containers: Reopen in Container** (the default config pulls `:claude-code`), then **Dev
Containers: Rebuild Container Without Cache** to force a fresh pull (nothing pins the digest, so the new one is
fetched). Set `CLAUDE_CODE_OAUTH_TOKEN` (a long-lived `claude setup-token`, **not** a normal login token) in
your **host** env first — `claude /login` can't reach claude.ai through the firewall.

---

## Step 4 — test the new container (inside it)

```bash
# (a) image basics + Arabidopsis DB baked:
ls /opt/pcv/arabidopsis_db && printenv ARAB_DB                 # dir exists + ARAB_DB=/opt/pcv/arabidopsis_db

# (b) GENE NAMES are the new, refined ones (this is the whole point): a real symbol fills
#     loci that have one; obsolete clone ids (F10N7.90) stay in the Description as
#     "synonyms: ...", never as the label; loci with no real name keep the clean AGI.
grep '^AT2G43120,' /opt/pcv/arabidopsis_db/arabidopsis.csv     # AT2G43120 -> PIRIN2 (was a bare AGI)
grep '^AT1G01010,' /opt/pcv/arabidopsis_db/arabidopsis.csv     # NAC001 + 'synonyms: ANAC001, ...'
grep '^AT4G32100,' /opt/pcv/arabidopsis_db/arabidopsis.csv     # stays AT4G32100 (BioMart only had clone ids) + clone ids as synonyms
awk -F, 'NR>1{t++} NR>1 && $1==$2{u++} /synonyms:/{s++} END{print u" of "t" un-named; "s" carry synonyms"}' \
    /opt/pcv/arabidopsis_db/arabidopsis.csv                    # expect ~16,130 un-named (down from 17,098) + ~20,600 with synonyms

# (c) end-to-end: run the shipped amplicon example and look at the names:
./amplicon_validate.sh examples/amplicon/raw runs/smoke
grep ',arabidopsis,' runs/smoke/annotation/feature_table.txt | cut -d, -f2,3 | head   # Feature, Accession

# (d) firewall + sandbox still good:
grep -q 'trap .*DROP' /usr/local/bin/init-firewall.sh && echo 'fail-closed trap OK'
ls /usr/local/bin/claude-guarded.sh && type claude            # launch gate present + aliased
cat /tmp/firewall-status                                       # ok
```
Full sandbox pass-criteria (DNS pin, no tcp/22, scoped sudo, AppArmor, rootless Apptainer, the canu
reproduction): **`docs/verify_devcontainer.md`** — or just tell Claude **"verify the new container"** and it
runs the lot.

---

## Gene names didn't appear?

The names come from an **alias table** joined at build time (`build_arabidopsis_db.sh`, see
`docs/arabidopsis_annotation_plan.md` §3a). Two reasons a locus can still show the bare AGI:

1. **BioMart was unreachable during the build** — the log shows `WARNING: BioMart alias download failed`.
   Re-run Step 1 (the join is best-effort and won't fail the build, so a stale-but-working DB can slip
   through). A `--no-cache` runtime build forces a fresh attempt.
2. **BioMart simply doesn't carry that name.** Lab/publication names (e.g. **NUWA**, **LPE1**) are
   TAIR/Araport-curated and are **not always in Ensembl/BioMart**. If a name you care about is missing even
   after a clean build, switch the build to an authoritative TAIR/Araport alias file — the most reliable
   option for a PI-facing deliverable, with **no** dependence on BioMart being up:
   - Put a `gene_aliases.txt` (`AGI <tab> symbol <tab> full_name`, multiple rows per locus) in the repo root.
   - In `.devcontainer/build/Dockerfile`, add it to the `COPY … /opt/pcv/` line and change the DB build to:
     `… /opt/pcv/build_arabidopsis_db.sh /opt/pcv/arabidopsis_db --aliases /opt/pcv/gene_aliases.txt …`
   - Rebuild (Step 1). Every build now bakes those exact curated names.

> Edits under `.devcontainer/build/` can't be validated inside the sandbox — they only take effect on a host
> `docker build` (Step 1).

---

## Quick reference

```bash
IMG=ghcr.io/akihitomamiya-del/plasmid-clone-validation; VER=v0.3.0
echo "$CR_PAT" | docker login ghcr.io -u akihitomamiya-del --password-stdin
# runtime (bakes gene names):
docker build -f .devcontainer/build/Dockerfile -t "$IMG:latest" . && docker push "$IMG:latest"
# sandbox (FROM fresh runtime):
docker build --pull -f .devcontainer/claude-code/Dockerfile -t "$IMG:claude-code" . && docker push "$IMG:claude-code"
# then in VS Code: Reopen in Container -> Rebuild Without Cache -> verify (Step 4)
```
