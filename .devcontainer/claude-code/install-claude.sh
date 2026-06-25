#!/bin/bash
# install-claude.sh — refresh the Claude CLI to @latest, AS ROOT, into the root-owned global npm
# prefix, so the contained --dangerously-skip-permissions agent still cannot modify or replace its
# own CLI. Invoked ONLY via the single SCOPED sudoers grant added in the Dockerfile
# (/etc/sudoers.d/vscode-claude-refresh) — never blanket sudo. Two entry points, same script:
#   • automatic, at container-create  → devcontainer postCreateCommand "claudeRefresh" (pre-firewall)
#   • on demand, any time             → `sudo /usr/local/bin/install-claude.sh`
# registry.npmjs.org is in the egress-firewall allowlist (init-firewall.sh), so the on-demand path
# also works once the firewall is up. The image still bakes a Claude as an OFFLINE FALLBACK; this
# only moves it forward — it never has to be the only copy.
#
# This script is the new root-trigger surface, so it is deliberately tight:
#   • the package + version are hardcoded — the agent can change WHEN it installs, not WHAT;
#   • the default AND the @anthropic-ai-scoped registry are pinned to registry.npmjs.org, and we cd
#     to a root-owned dir, so a planted ./.npmrc, a scoped "@anthropic-ai:registry=", or npm_config_*
#     cannot redirect the install (sudo's env_reset already strips the caller's NPM_CONFIG_*);
#   • best-effort: a failed/offline run keeps the baked Claude and never aborts container creation.
# Rationale + the Anthropic-reference (scoped-vs-blanket sudo) comparison:
#   docs/claude_cli_version_handoff.md
set -uo pipefail

cd /usr/local/lib 2>/dev/null || cd /          # root-owned cwd: ignore any agent-writable ./.npmrc
NPM="$(command -v npm || echo /usr/bin/npm)"
CLAUDE="$(command -v claude || echo /usr/bin/claude)"

if "$NPM" install -g \
        --registry=https://registry.npmjs.org/ \
        --@anthropic-ai:registry=https://registry.npmjs.org/ \
        @anthropic-ai/claude-code@latest; then
    if v="$("$CLAUDE" --version 2>/dev/null)"; then
        echo "install-claude: refreshed to $v"
    else
        echo "install-claude: npm install reported success but 'claude --version' failed" >&2
    fi
else
    echo "install-claude: refresh failed (offline?); keeping the baked $("$CLAUDE" --version 2>/dev/null || echo '?')" >&2
fi
exit 0                                          # never fail container creation
