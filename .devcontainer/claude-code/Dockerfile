# ============================================================
# plasmid-clone-validation — Claude Code SANDBOX layer
# ------------------------------------------------------------
# Extends the published, fully-offline runtime image with the agent-containment
# stack: node + the Claude Code CLI + the egress firewall + sudo-lockdown +
# the uid-remap ownership helper. This is the only layer that changes when
# Claude Code updates, so it stays tiny and the ~7 GB runtime base is untouched.
#
# Built locally by .devcontainer/claude-code/devcontainer.json (the yolo sandbox).
# Build on a networked host: node/Claude install + firewall deps need egress
# (the firewall only closes at *runtime*). Context = repo root (../..).
# ============================================================
FROM ghcr.io/akihitomamiya-del/plasmid-clone-validation:latest

ARG TZ
ENV TZ="${TZ:-America/Los_Angeles}"
USER root

# --- Firewall + dev tooling not in the runtime base ---
RUN apt-get update && apt-get install -y --no-install-recommends \
    iptables ipset iproute2 dnsutils aggregate jq \
    nano vim man-db bsdmainutils \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# --- Node.js (for the Claude Code CLI) ---  VERIFY: Node 20 LTS
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && \
    apt-get install -y nodejs && apt-get clean && rm -rf /var/lib/apt/lists/*

# --- Mounted config/history volumes must be vscode-owned (see devcontainer.json) ---
# A named volume mounted on a path that does NOT exist in the image is created
# root-owned, so the non-root vscode user can't write it. For ~/.claude that means
# Claude Code can't persist credentials/onboarding → auth silently fails. Pre-create
# + chown so each named volume inherits vscode ownership on first mount.
RUN mkdir -p /home/vscode/.claude /commandhistory \
    && touch /commandhistory/.bash_history \
    && chown -R vscode:vscode /home/vscode/.claude /commandhistory

# --- Firewall scripts + SCOPED passwordless sudo ---
COPY .devcontainer/claude-code/init-firewall.sh \
     .devcontainer/claude-code/start-firewall.sh \
     .devcontainer/claude-code/firewall-warning.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/init-firewall.sh /usr/local/bin/start-firewall.sh /usr/local/bin/firewall-warning.sh && \
    echo "vscode ALL=(root) NOPASSWD: /usr/local/bin/init-firewall.sh, /usr/local/bin/start-firewall.sh" > /etc/sudoers.d/vscode-firewall && \
    chmod 0440 /etc/sudoers.d/vscode-firewall

# --- Launch gate: refuse to start Claude unless the firewall is confirmed up ---
# An interactive-shell CONVENIENCE guard (aliased to `claude` in vscode's ~/.bashrc below), NOT the
# enforcing boundary — the fail-closed trap in init-firewall.sh + the sudo-lockdown are. Bypassable by
# non-interactive / absolute-path calls by design; it just stops a launch after a visibly-failed firewall.
COPY .devcontainer/claude-code/claude-guarded.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/claude-guarded.sh

# --- uid-portability helper + sudo lockdown ---
# /opt/{nextflow,sif-cache} are baked + owned by the build vscode (uid 1000). When the host
# dev-uid != 1000, updateRemoteUserUID remaps vscode at runtime but does NOT chown outside
# $HOME, orphaning /opt → the 0600 nextflow jar is unreadable + NXF_HOME unwritable. The helper
# re-chowns /opt to the runtime uid at postStartCommand via the scoped grant below.
# We ALSO drop the base image's blanket `vscode ALL=(root) NOPASSWD: ALL`: the egress firewall
# is the guardrail that makes --dangerously-skip-permissions safe, and blanket sudo would let the
# agent flush it. Only the scoped firewall + ownership grants survive.
COPY .devcontainer/claude-code/fix-opt-ownership.sh /usr/local/bin/
RUN rm -f /etc/sudoers.d/vscode \
    && chmod +x /usr/local/bin/fix-opt-ownership.sh \
    && echo "vscode ALL=(root) NOPASSWD: /usr/local/bin/fix-opt-ownership.sh" > /etc/sudoers.d/vscode-fixopt \
    && chmod 0440 /etc/sudoers.d/vscode-fixopt

# --- Live Preview (HTML report viewer) — baked .vsix for OFFLINE install in this sandbox ---
# The runtime egress firewall blocks the extension gallery byte-CDN (*.gallerycdn.vsassets.io,
# Akamai), so `code --install-extension <id>` and the declarative customizations.vscode.extensions
# route BOTH fail here. We bake the .vsix at build time (networked) and install it from disk at
# postCreateCommand (pre-firewall) via the headless code-server CLI — see install-live-preview.sh.
# (The marketplace 'vspackage' endpoint serves the .vsix directly, gzip-encoded, and IS allowlisted;
#  --compressed yields the real zip. The PK check asserts it is a real vsix, not an error page.)
# Placed before the @latest Claude CLI layer so a Claude bump never re-downloads it.
ARG LIVE_PREVIEW_VERSION=0.4.19
ENV LIVE_PREVIEW_VERSION=${LIVE_PREVIEW_VERSION}
RUN mkdir -p /usr/local/share/live-preview \
    && curl -fsSL --compressed --retry 3 \
        "https://marketplace.visualstudio.com/_apis/public/gallery/publishers/ms-vscode/vsextensions/live-server/${LIVE_PREVIEW_VERSION}/vspackage" \
        -o /usr/local/share/live-preview/ms-vscode.live-server.vsix \
    && [ "$(head -c2 /usr/local/share/live-preview/ms-vscode.live-server.vsix)" = "PK" ] \
    && chmod 0644 /usr/local/share/live-preview/ms-vscode.live-server.vsix
COPY .devcontainer/claude-code/install-live-preview.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/install-live-preview.sh

# --- Claude Code CLI — installed as ROOT, deliberately (SECURITY) ---
# Root-owned global install so the CONTAINED yolo agent (vscode, running --dangerously-skip-permissions)
# CANNOT modify its own Claude binary, replace it, or `npm i -g` other global packages — it has no sudo
# for npm, and the global prefix is root-owned. (A vscode-writable npm prefix would hand the agent exactly
# that capability; we don't want it here.) Intentionally @latest (decision 2026-06-21); Claude updates by
# REBUILDING this thin layer, NOT via in-container self-update — keeping the agent's tooling immutable is
# part of the containment. This is also the only frequently-changing layer, so rebuilding it never touches
# the runtime base/SIFs.
ARG CLAUDE_CODE_VERSION=latest
RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}

USER vscode
ENV SHELL=/bin/bash EDITOR=nano
# Wire the fail-open firewall banner into the (bash) shell — WITHOUT this the
# "running WITHOUT network restrictions" warning never fires (silent fail-open).
RUN echo '[ -f /usr/local/bin/firewall-warning.sh ] && . /usr/local/bin/firewall-warning.sh' >> /home/vscode/.bashrc \
    && echo "alias claude='/usr/local/bin/claude-guarded.sh'" >> /home/vscode/.bashrc
