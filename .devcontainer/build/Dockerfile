# ============================================================
# plasmid-clone-validation — RUNTIME image  (published to GHCR)
# ------------------------------------------------------------
# The reusable, fully-offline pipeline runtime: base + EPI2ME runtime
# (Java + Nextflow + Apptainer) + seqkit + the 5 wf-clone-validation SIFs
# + the wf-amplicon SIF + the pulled workflow code (wf-clone-validation AND wf-amplicon)
# + our wrapper scripts.
#
# NOT here (added by .devcontainer/claude-code on top — the L3R-seq pattern):
#   Claude Code CLI, node, the egress firewall, sudo-lockdown.
#
# Built LEAN (Option A): the SIFs are baked so the image runs AIRGAPPED, but the
# Apptainer OCI pull-cache is purged in the SAME RUN layer as the pulls, so the
# ~5 GB of duplicate OCI blobs never persist in the image (~5.3 GB built, not the ~40 GB dev monolith).
#
# MUST be built on a host/CI with OPEN network (build-time SIF pulls from Docker
# Hub). Afterward it runs fully offline (NXF_OFFLINE=true + the baked SIF cache).
# Lines marked VERIFY need confirmation on first build; SIF cache details: docs/sif_cache.md.
# ============================================================
FROM mcr.microsoft.com/devcontainers/base:ubuntu-22.04

ARG TZ
ENV TZ="${TZ:-America/Los_Angeles}"
USER root

# --- OS deps: EPI2ME runtime prerequisites only (NO firewall/dev tooling) ---
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl wget ca-certificates gnupg \
    openjdk-17-jre-headless \
    uidmap squashfuse fuse-overlayfs \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# --- seqkit (the read filter / peak finder needs it) ---
ARG SEQKIT_VERSION=2.9.0
RUN ARCH=$(dpkg --print-architecture) && \
    wget -q "https://github.com/shenwei356/seqkit/releases/download/v${SEQKIT_VERSION}/seqkit_linux_${ARCH}.tar.gz" && \
    tar xzf "seqkit_linux_${ARCH}.tar.gz" -C /usr/local/bin seqkit && \
    rm "seqkit_linux_${ARCH}.tar.gz" && seqkit version

# --- Nextflow (needs Java, installed above) ---
# PINNED to 24.10.9 (last 24.10 patch). wf-clone-validation v1.8.4 declares only
# `nextflowVersion = '>=23.04.2'`, which 25.x/26.x satisfy numerically but then BREAK it
# (post-25 strict config parser rejects the workflow; 26.x relocates pulled pipelines).
# 24.10.x keeps the lenient parser + classic assets/<org>/ layout. NXF_VER pins it.
ENV NXF_VER=24.10.9
RUN curl -s https://get.nextflow.io | bash && mv nextflow /usr/local/bin/ && nextflow info

# --- Apptainer ---  VERIFY: .deb exists for the build arch
ARG APPTAINER_VERSION=1.3.6
RUN ARCH=$(dpkg --print-architecture) && \
    wget -q -O /tmp/apptainer.deb \
      "https://github.com/apptainer/apptainer/releases/download/v${APPTAINER_VERSION}/apptainer_${APPTAINER_VERSION}_${ARCH}.deb" && \
    apt-get update && apt-get install -y /tmp/apptainer.deb && \
    rm /tmp/apptainer.deb && apt-get clean && rm -rf /var/lib/apt/lists/* && \
    apptainer --version

# --- Pre-stage the 5 workflow images as SIF + pipeline code (BUILD-TIME, network OPEN) ---
# Reads the pinned SHAs from the workflow's base.config so they never drift, and pulls each
# image to the exact filename Nextflow's singularity cache expects (docs/sif_cache.md).
# LEAN: `apptainer cache clean` + rm the OCI cache in THIS layer, else the duplicate ~5 GB
# of OCI blobs persist in the image. NXF_OFFLINE stays unset until AFTER the pulls.
ENV NXF_SINGULARITY_CACHEDIR=/opt/sif-cache NXF_HOME=/opt/nextflow
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
    apptainer cache clean -f || true; \
    rm -rf /root/.apptainer/cache "${APPTAINER_CACHEDIR:-/root/.apptainer/cache}" /tmp/* ; \
    ls -la /opt/sif-cache
# Pre-cache the pipeline code so `nextflow run … -r v1.8.4` is fully offline. Chown NXF_HOME to vscode
# in THIS (small, ~77 MB) layer so the default user can write it offline; doing it here avoids a
# separate recursive-chown layer that would copy-up the big SIF cache.
RUN nextflow pull epi2me-labs/wf-clone-validation -r "${WF_VERSION}" \
    && chown -R vscode:vscode /opt/nextflow

# --- Pre-stage wf-amplicon (de-novo amplicon consensus) — ONE additional SIF ----------------
# wf-amplicon shares medaka + wf-common with wf-clone-validation at the SAME pinned SHAs
# (baked above), so ONLY the wf-amplicon image itself is new (~1.5 GB). wf-amplicon has NO
# base.config (404) — its container SHA lives in nextflow.config. Same lean pattern: pull the SIF
# to the exact filename Nextflow's singularity cache expects, then purge the OCI cache in THIS
# layer. The de-novo (1 amplicon/barcode) and the future multi-amplicon reference path use the
# SAME SIF — no extra image. See docs/amplicon_plan.md.
ARG WF_AMPLICON_VERSION=v1.2.2
RUN set -eux; \
    curl -fsSL -o /tmp/amplicon.config \
      "https://raw.githubusercontent.com/epi2me-labs/wf-amplicon/${WF_AMPLICON_VERSION}/nextflow.config"; \
    amplicon=$(sed -n 's/^[[:space:]]*container_sha[[:space:]]*=[[:space:]]*"\(sha[0-9a-f]*\)".*/\1/p' /tmp/amplicon.config | head -n1); \
    test -n "${amplicon}"; \
    apptainer pull --force "/opt/sif-cache/ontresearch-wf-amplicon-${amplicon}.img" \
      "docker://ontresearch/wf-amplicon:${amplicon}"; \
    apptainer cache clean -f || true; \
    rm -rf /root/.apptainer/cache "${APPTAINER_CACHEDIR:-/root/.apptainer/cache}" /tmp/* ; \
    ls -la /opt/sif-cache
# Pre-cache the wf-amplicon pipeline code so `nextflow run … -r v1.2.2` is fully offline.
RUN nextflow pull epi2me-labs/wf-amplicon -r "${WF_AMPLICON_VERSION}" \
    && chown -R vscode:vscode /opt/nextflow

# --- Offline gate (medaka model): verify at RUNTIME, not build (apptainer exec mounts the SIF -> needs
#     /dev/fuse, which `apptainer pull` above does not). wf-amplicon polishes with
#     `medaka inference --model <basecaller_cfg>:consensus`; the basecaller cfg is AUTO-DETECTED from the
#     read headers (MinKNOW sup embeds it). Auto-selection picks the model NAME from the data; offline we
#     also need its WEIGHTS bundled in the medaka SIF. After building, confirm the R10.4.1 E8.2 5 kHz sup
#     model is present (the running container has fuse; the build does not):
#       docker run --rm --device /dev/fuse --cap-add SYS_ADMIN --security-opt apparmor=pcv-apptainer <image> \
#         bash -lc 'apptainer exec "$(ls /opt/sif-cache/ontresearch-medaka-*.img)" medaka tools list_models'
#     If the sup model is absent, pin a bundled one at runtime via OVERRIDE_BASECALLER_CFG (amplicon_validate.sh
#     exposes it). See docs/amplicon_plan.md §8b.

# --- Our wrapper scripts (so the image is runnable standalone via `docker run`) ---
# clone_validate.sh / amplicon_validate.sh resolve their siblings (the filter/peak scripts) via
# SCRIPT_DIR, so all of them live together; /opt/pcv on PATH makes `clone_validate.sh …` and
# `amplicon_validate.sh …` work without the workspace bind-mount.
COPY filter_nanopore_reads.sh estimate_length_peak.sh clone_validate.sh amplicon_validate.sh amplicon_split.sh build_arabidopsis_db.sh /opt/pcv/
COPY amplicon_annotate /opt/pcv/amplicon_annotate
RUN chmod +x /opt/pcv/*.sh /opt/pcv/amplicon_annotate/*.sh && chown -R vscode:vscode /opt/pcv
ENV PATH="/opt/pcv:${PATH}"

# --- Custom Arabidopsis thaliana protein DB for amplicon annotation (BUILD-TIME, network OPEN) ---
# Fetch the Ensembl Plants A. thaliana proteome and build the diamond DB that amplicon_annotate uses
# to add the AGI locus + gene symbol + function to each consensus. `apptainer exec` does NOT work at
# build time (no /dev/fuse), so the SIF's diamond is unreachable here -- install a matching diamond
# binary (the plannotate SIF ships diamond 2.1.15, so the baked .dmnd must be readable by it) for
# this layer only and remove it after. The DB is bind-mounted at runtime (NOT baked into the SIF);
# ENV ARAB_DB below makes the annotation use it by default. Lean: drop the proteome FASTA + the
# diamond binary in the SAME layer. MUST run on a host that can reach Ensembl Plants. x86_64 only
# (matches the amd64 SIFs). See docs/arabidopsis_annotation_plan.md.
ARG ARAB_ENSEMBL_RELEASE=63
ARG DIAMOND_VERSION=2.1.15
RUN set -eux; \
    wget -q -O /tmp/diamond.tar.gz \
      "https://github.com/bbuchfink/diamond/releases/download/v${DIAMOND_VERSION}/diamond-linux64.tar.gz"; \
    tar xzf /tmp/diamond.tar.gz -C /usr/local/bin diamond; diamond version; \
    /opt/pcv/build_arabidopsis_db.sh /opt/pcv/arabidopsis_db --release "${ARAB_ENSEMBL_RELEASE}"; \
    rm -f /opt/pcv/arabidopsis_db/_ensembl_pep.fa.gz \
          /opt/pcv/arabidopsis_db/arabidopsis_proteins.faa \
          /usr/local/bin/diamond /tmp/diamond.tar.gz; \
    chown -R vscode:vscode /opt/pcv/arabidopsis_db; \
    ls -la /opt/pcv/arabidopsis_db
# Make the amplicon annotation use the baked Arabidopsis DB by default. annotate.sh validates the dir
# (arabidopsis.dmnd + arabidopsis.csv) and silently falls back to the stock DBs if it is absent, so
# this is safe even for an image built without the step. Override per-run with ARAB_DB=… .
ENV ARAB_DB=/opt/pcv/arabidopsis_db

# NOTE: /opt/sif-cache is intentionally NOT chowned/chmod'd. `apptainer pull` already writes the SIFs
# as root:root mode 0755 (world-readable+executable), so any runtime uid reads them — and a recursive
# chown/chmod of the ~4.6 GB cache would copy-up the whole thing into a DUPLICATE layer, ~doubling the
# image (10 GB → ~6 GB once removed). /opt/nextflow + /opt/pcv were chowned to vscode in small layers above.

# Now safe to flip offline (all build-time pulls are done):
ENV NXF_OFFLINE=true
ENV DEVCONTAINER=true

# Link the published GHCR package to its source repo (shows on the package page; lets the package
# inherit the repo's visibility/README). Placed late so it doesn't bust the SIF-layer cache.
LABEL org.opencontainers.image.source="https://github.com/akihitomamiya-del/plasmid-clone-validation" \
      org.opencontainers.image.description="ONT wf-clone-validation + wf-amplicon fully-offline pipeline runtime (Nextflow + Apptainer + baked SIFs + pre-filter wrappers)" \
      org.opencontainers.image.licenses="MIT"

USER vscode
ENV SHELL=/bin/bash EDITOR=nano
