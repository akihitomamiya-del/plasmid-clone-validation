#!/bin/bash
# claude-guarded.sh — refuse to launch the yolo agent unless the egress firewall is confirmed up.
#
# SCOPE: this is an INTERACTIVE-SHELL CONVENIENCE guard, not the enforcing boundary. It is aliased to
# `claude` in vscode's ~/.bashrc, so it only fires for interactive bash; a non-interactive `bash -c
# claude`, an absolute-path call, or a Claude subprocess bypasses it BY DESIGN. The ENFORCING controls
# are init-firewall.sh's fail-closed EXIT trap (a failed firewall leaves egress DROPped) plus the
# sudo-lockdown (the agent has no NET_ADMIN and can't flush iptables). This just stops a human/agent
# from launching --dangerously-skip-permissions after a VISIBLY failed firewall without noticing the
# banner.
set -euo pipefail

if [ "$(cat /tmp/firewall-status 2>/dev/null || true)" != ok ]; then
    echo "REFUSING to launch Claude: egress firewall is not active (/tmp/firewall-status != ok)." >&2
    echo "  Bring it up first:  sudo /usr/local/bin/start-firewall.sh" >&2
    exit 1
fi

# Resolve the real CLI. Aliases do NOT expand in this non-interactive script, so `command -v claude`
# finds the npm-global binary, not this guard. Hard-fail rather than exec a guessed path, so a future
# install-location change surfaces loudly instead of silently exec'ing nothing.
_claude="$(command -v claude || true)"
if [ ! -x "$_claude" ]; then
    echo "ERROR: could not find the 'claude' CLI on PATH (looked via 'command -v claude')." >&2
    exit 127
fi
exec "$_claude" "$@"
