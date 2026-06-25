#!/bin/bash
# claude-guarded.sh — refuse to launch the yolo agent unless the egress firewall is confirmed up.
#
# Belt-and-suspenders to init-firewall.sh's fail-closed EXIT trap: a failed firewall already leaves
# egress DROPped, but we ALSO refuse to start Claude so nobody runs --dangerously-skip-permissions
# while unprotected (and nobody has to notice a shell banner). The claude-code Dockerfile aliases
# `claude` to this script in vscode's ~/.bashrc.
set -euo pipefail

if [ "$(cat /tmp/firewall-status 2>/dev/null || true)" != ok ]; then
    echo "REFUSING to launch Claude: egress firewall is not active (/tmp/firewall-status != ok)." >&2
    echo "  Bring it up first:  sudo /usr/local/bin/start-firewall.sh" >&2
    exit 1
fi

# In this non-interactive script the `claude` shell alias does not apply, so command -v resolves the
# real npm-global CLI; fall back to the conventional NodeSource path if PATH is unusual.
exec "$(command -v claude || echo /usr/bin/claude)" "$@"
