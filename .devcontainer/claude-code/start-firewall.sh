#!/bin/bash
# start-firewall.sh -- Initialize the network firewall with retries.
# Called by devcontainer postStartCommand. Wraps init-firewall.sh to
# handle transient failures (DNS not ready, network not yet available)
# that can occur during early container startup.
#
# Writes the final status ("ok" or "failed") to /tmp/firewall-status so
# that firewall-warning.sh (sourced from ~/.bashrc) can display a visible
# banner in every new shell if the firewall never came up.

set -euo pipefail
LOG="/tmp/firewall-init.log"
STATUS_FILE="/tmp/firewall-status"
MAX_RETRIES=3
RETRY_DELAY=5

echo "=== Firewall init starting at $(date -Iseconds) ===" | tee "$LOG"

# Mark status as "failed" up-front so partial runs don't look healthy.
# rm -f FIRST (defense-in-depth): /tmp is world-writable+sticky, so a contained
# agent could pre-plant a vscode-owned /tmp/firewall-status="ok". With the host's
# fs.protected_regular=2 that foreign-owned file makes the redirect below fail with
# EACCES *even for root* -> `set -e` aborts the script HERE, before the firewall is
# ever applied, while the stale "ok" suppresses the firewall-warning.sh banner =
# SILENT FAIL-OPEN. root can unlink it (CAP_FOWNER in a sticky dir); recreating it
# makes the file root-owned, after which the agent can neither overwrite (DAC 0644)
# nor delete (sticky bit) it. Validated 2026-06-20.
rm -f "$STATUS_FILE"
echo "failed" > "$STATUS_FILE"
chmod 644 "$STATUS_FILE"

for attempt in $(seq 1 "$MAX_RETRIES"); do
    echo "[Attempt $attempt/$MAX_RETRIES]" | tee -a "$LOG"
    if /usr/local/bin/init-firewall.sh >> "$LOG" 2>&1; then
        echo "Firewall active (attempt $attempt)" | tee -a "$LOG"
        echo "ok" > "$STATUS_FILE"
        exit 0
    fi
    echo "Attempt $attempt failed" | tee -a "$LOG"
    [ "$attempt" -lt "$MAX_RETRIES" ] && sleep "$RETRY_DELAY"
done

echo "ERROR: Firewall failed after $MAX_RETRIES attempts. See $LOG" >&2
echo "WARNING: Container is running WITHOUT network restrictions." | tee -a "$LOG"
# Exit 0 on failure so postStartCommand does not abort the container rebuild.
# The "failed" status file + firewall-warning.sh banner in every new shell
# already surface the fail-open state to the user (commit 98ad0bf).
exit 0
