# Pre-staging the EPI2ME container images as SIF (offline Apptainer)

For the sandboxed devcontainer to run `wf-clone-validation` with the egress firewall **on**,
every container image the workflow uses must be present locally as a Singularity/Apptainer
`.img` **before** the firewall closes. This doc is the authoritative manifest + recipe.

> Pinned to **`wf-clone-validation` v1.8.4**. The build recipe below re-reads the SHAs from the
> workflow's `base.config` at build time, so it stays correct if you bump the version — but the
> explicit table is here for reference and offline validation.

## The 5 images (from `epi2me-labs/wf-clone-validation@v1.8.4` `base.config`, repo root)

| Nextflow label | Image | Tag (SHA) — `base.config` var |
|---|---|---|
| `wfplasmid` | `ontresearch/wf-clone-validation` | `sha0ebc91d22c0ea5183272af8bf2b96ca51e88ad5d` (`container_sha_cloneval`) |
| `canu` | `ontresearch/canu` | `sha50e56c57b7dfcc28ea176895c6ad98b43c607df2` (`container_sha_canu`) |
| `medaka` | `ontresearch/medaka` | `shacf8338462607b17b1d68dbce212cb93daea50bad` (`container_sha_medaka`) |
| `wf_common` | `ontresearch/wf-common` | `shafdd79f8e4a6faad77513c36f623693977b92b08e` (`common_sha`) |
| `plannotate` | `ontresearch/plannotate` | `shae4901fb4353581a26049f564d279edd81fe38805` (`plannotate_sha`) |

Notes:
- The tag string literally begins with `sha` (it is a tag, not a `@sha256:` digest) — pull as
  `docker://ontresearch/<image>:sha…` verbatim.
- The `flye` assembler runs inside the `wfplasmid` (`wf-clone-validation`) image — there is **no**
  separate flye image. These 5 cover both assemblers.

## ⚠️ The cache-filename convention (the #1 thing that silently breaks offline)

When `NXF_SINGULARITY_CACHEDIR` is set and `NXF_OFFLINE=true`, Nextflow looks for a file named
after the image with `/`→`-`, `:`→`-`, and an `.img` suffix. It does **not** re-pull if the file
is missing — it **fails**. So you must `apptainer pull` to the *exact* expected name, e.g.:

```
ontresearch-wf-clone-validation-sha0ebc91d22c0ea5183272af8bf2b96ca51e88ad5d.img
```

The exact mangling is Nextflow-version-dependent. **Validate empirically once**: on a networked
host, run a single online `nextflow run … -profile singularity` with `NXF_SINGULARITY_CACHEDIR`
set, then `ls "$NXF_SINGULARITY_CACHEDIR"` and codify *those* names. This is the single most
likely offline-build failure.

## Build-time recipe (network open; runs as root in the Dockerfile)

This is implemented in `.devcontainer/build/Dockerfile` (the publishable lean runtime image). It
reads the SHAs from `base.config` (so no drift) and pulls each image to the Nextflow-expected
filename. **`.devcontainer/build/Dockerfile` is the source of truth**; the snippet below is
illustrative and omits the real Dockerfile's `apptainer cache clean -f` + OCI pull-cache purge
(done in the same `RUN`) that keep the image lean (~5.3 GB):

```bash
ENV NXF_SINGULARITY_CACHEDIR=/opt/sif-cache NXF_OFFLINE=true
ARG WF_VERSION=v1.8.4
RUN set -eux; mkdir -p /opt/sif-cache; \
    curl -fsSL -o /tmp/base.config \
      "https://raw.githubusercontent.com/epi2me-labs/wf-clone-validation/${WF_VERSION}/base.config"; \
    cloneval=$(sed -n 's/.*container_sha_cloneval *= *"\(sha[0-9a-f]*\)".*/\1/p' /tmp/base.config); \
    canu=$(    sed -n 's/.*container_sha_canu *= *"\(sha[0-9a-f]*\)".*/\1/p'     /tmp/base.config); \
    medaka=$(  sed -n 's/.*container_sha_medaka *= *"\(sha[0-9a-f]*\)".*/\1/p'   /tmp/base.config); \
    common=$(  sed -n 's/.*common_sha *= *"\(sha[0-9a-f]*\)".*/\1/p'             /tmp/base.config); \
    plan=$(    sed -n 's/.*plannotate_sha *= *"\(sha[0-9a-f]*\)".*/\1/p'         /tmp/base.config); \
    pull() { apptainer pull --force "/opt/sif-cache/ontresearch-$1-$2.img" "docker://ontresearch/$1:$2"; }; \
    pull wf-clone-validation "$cloneval"; pull canu "$canu"; pull medaka "$medaka"; \
    pull wf-common "$common"; pull plannotate "$plan"; \
    ls -la /opt/sif-cache
# pre-cache the pipeline code too, so `nextflow run` is fully offline:
RUN nextflow pull epi2me-labs/wf-clone-validation -r v1.8.4
```

Caveats (validate on first build):
- **`apptainer pull docker://…` runs as root at build**, so the docker→SIF conversion usually works
  without `--fakeroot`. Add `--fakeroot` (and `/etc/subuid`,`/etc/subgid` ranges for `vscode`) only
  if you hit setuid/extraction errors.
- **Confirm the `.img` filenames** match what Nextflow expects (see the empirical step above). If they
  differ, rename or adjust the `pull()` target.
- Do **not** rely on `nextflow inspect` to enumerate images — it needs a real `--fastq`/sample and is
  brittle at build time. The SHA-from-`base.config` approach above is deterministic.

## Bake into the image — do NOT also mount a volume over it

`/opt/sif-cache` is populated at **build time** into the image layer. A named volume mounted at the
same path would **shadow** the baked content with an empty volume on first run → empty cache →
(with `NXF_OFFLINE=true`) the run fails. Therefore **no devcontainer config mounts a volume over
`/opt`** (the SIF cache + `NXF_HOME` are baked into the runtime image). (If you ever prefer a
volume, then *don't* bake into the image and instead seed the volume from a `postCreateCommand` —
pick exactly one strategy.)
