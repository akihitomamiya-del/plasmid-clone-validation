#!/bin/bash
set -euo pipefail

# install-live-preview.sh — ensure the "Live Preview" (ms-vscode.live-server) VS Code
# extension is installed, so the workflow HTML report
# (runs/<out>/cloneval/wf-clone-validation-report.html) opens in-editor via right-click
# "Show Preview". Invoked from .devcontainer/claude-code/devcontainer.json postCreateCommand
# (the PRE-firewall window) on every container create/rebuild.
#
# WHY NOT just `code --install-extension ms-vscode.live-server`:
#   * The egress firewall (postStartCommand) blocks the extension gallery byte-CDN
#     (*.gallerycdn.vsassets.io, Akamai — its IPs are resolved once and go stale), so the
#     normal marketplace install AND the declarative customizations.vscode.extensions route
#     both fail in this sandbox. (The marketplace 'vspackage' API host IS allowlisted and
#     serves the .vsix directly — only the byte-CDN is blocked.)
#   * postCreateCommand runs BEFORE the firewall, but the remote-cli `code` needs an editor
#     IPC socket (VSCODE_IPC_HOOK_CLI) that is not set at create time. So we install with the
#     SERVER's headless `code-server` CLI, whose default extensions-dir is the one the editor
#     reads and which needs no attached window.
#
# Install source, in order (NEITHER reuses the VS Code extensionsCache):
#   1) the .vsix baked into the image at build time (offline + reproducible) — see Dockerfile;
#   2) a fresh download from the marketplace 'vspackage' endpoint (allowlisted) — covers an
#      image that predates the bake, and lets you run this by hand in an existing container.
#
# Non-fatal by design: a missing HTML viewer must never block container creation. On failure
# it prints a loud banner and records the reason in the log; re-run by hand to retry.

EXT_ID="ms-vscode.live-server"
BAKED_VSIX="${LIVE_PREVIEW_VSIX:-/usr/local/share/live-preview/ms-vscode.live-server.vsix}"
LIVE_PREVIEW_VERSION="${LIVE_PREVIEW_VERSION:-0.4.19}"
VSPACKAGE_URL="https://marketplace.visualstudio.com/_apis/public/gallery/publishers/ms-vscode/vsextensions/live-server/${LIVE_PREVIEW_VERSION}/vspackage"
LOG=/tmp/live-preview-install.log

log() { echo "[live-preview] $*" | tee -a "$LOG" ; }
fail() {
    log "FAILED: $*"
    log "Re-run by hand to retry:  bash /usr/local/bin/install-live-preview.sh"
    {
        echo
        echo "##############################################################"
        echo "## Live Preview (HTML report viewer) NOT installed.         ##"
        echo "## Details: $LOG"
        echo "##############################################################"
    } >&2
    exit 0   # never block container creation over a convenience viewer
}

: > "$LOG"
log "ensuring $EXT_ID is installed (log: $LOG)"

# 1. Locate the ACTIVE VS Code server's headless CLI — newest by mtime, covering both the
#    /vscode volume layout (this host) and the standard ~/.vscode-server layout.
CODE_SERVER=$(find /vscode/vscode-server /home/vscode/.vscode-server "$HOME/.vscode-server" \
                -maxdepth 5 -type f -name code-server -printf '%T@ %p\n' 2>/dev/null \
              | sort -rn | head -1 | cut -d' ' -f2- || true)
[ -n "${CODE_SERVER:-}" ] && [ -x "$CODE_SERVER" ] \
    || fail "no code-server CLI found under /vscode or ~/.vscode-server (is the VS Code server provisioned yet?)"
log "code-server: $CODE_SERVER"

# 2. Already installed? Done.
if "$CODE_SERVER" --list-extensions 2>/dev/null | grep -qx "$EXT_ID"; then
    log "OK: $EXT_ID already installed."
    exit 0
fi

# 3. Resolve a .vsix: baked first (offline), else fresh download (pre-firewall + allowlisted).
VSIX=""
if [ -f "$BAKED_VSIX" ]; then
    VSIX="$BAKED_VSIX"
    log "using baked vsix: $VSIX"
else
    log "no baked vsix at $BAKED_VSIX; downloading from marketplace"
    TMP_VSIX="$(mktemp --suffix=.vsix)"
    if curl -fsSL --compressed --retry 3 -o "$TMP_VSIX" "$VSPACKAGE_URL" \
       && [ "$(head -c2 "$TMP_VSIX")" = "PK" ]; then
        VSIX="$TMP_VSIX"
        log "downloaded vsix: $VSIX ($(stat -c%s "$TMP_VSIX") bytes)"
    else
        fail "could not obtain a .vsix (no baked copy and download failed/blocked: $VSPACKAGE_URL)"
    fi
fi

# 4. Install headlessly, then verify it is actually present.
"$CODE_SERVER" --install-extension "$VSIX" --force >>"$LOG" 2>&1 \
    || fail "code-server --install-extension errored (see log)"
if "$CODE_SERVER" --list-extensions 2>/dev/null | grep -qx "$EXT_ID"; then
    log "OK: $EXT_ID installed. Reload the VS Code window if 'Show Preview' is not available yet."
    exit 0
else
    fail "install reported success but $EXT_ID is not listed"
fi
