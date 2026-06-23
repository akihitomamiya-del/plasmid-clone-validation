#!/usr/bin/env bash
#
# fix-opt-ownership.sh
# --------------------
# Re-align the baked NXF_HOME (/opt/nextflow) to the *runtime* `vscode` uid. Invoked as root via a
# scoped NOPASSWD sudoers entry from devcontainer.json's postStartCommand.
#
# Why this exists:
#   The Dockerfile bakes /opt/{nextflow,sif-cache} into the image and chowns them to `vscode` —
#   but at BUILD time `vscode` = uid 1000 (the devcontainers base-image default). devcontainer.json
#   sets updateRemoteUserUID:true, so when the HOST dev-user uid != 1000 the container's `vscode`
#   is remapped at start (e.g. to 1001). That remap chowns $HOME but NOT /opt, leaving /opt orphaned
#   at uid 1000: the 0600 nextflow jar becomes unreadable and NXF_HOME unwritable, so the pipeline
#   can't start (`nextflow -version` -> "Unable to access jarfile").
#
#   Running `chown vscode:vscode` as root resolves `vscode` from the (already-remapped) /etc/passwd,
#   so this is correct for ANY host uid — no need to know the number at build time.
#
# Safety: takes NO arguments and touches only the fixed /opt/nextflow path (non-injectable); the script
# is root-owned and not writable by `vscode`. Idempotent + cheap (~77 MB, sub-second).
set -euo pipefail

# Only /opt/nextflow needs re-aligning: its baked nextflow jar is mode 0600 and NXF_HOME must be
# WRITABLE at runtime. /opt/sif-cache is deliberately NOT chowned — its SIFs are mode 0755
# (world-readable), so the runtime uid reads them fine, and a recursive chown of ~4.6 GB would
# needlessly copy-up the whole cache into the container at every start.
if [[ -d /opt/nextflow ]]; then
    chown -R vscode:vscode /opt/nextflow
fi
