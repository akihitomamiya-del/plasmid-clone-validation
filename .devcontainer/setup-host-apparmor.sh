#!/usr/bin/env bash
# One-time host setup (admin/sudoer) enabling rootless Apptainer in the
# plasmid-clone-validation devcontainer WITHOUT weakening host-wide security.
#
# Installs the `pcv-apptainer` AppArmor profile into /etc/apparmor.d/ (where
# AppArmor auto-loads it on every boot) and loads it now. The devcontainer opts
# into it via `--security-opt apparmor=pcv-apptainer` (wired in devcontainer.json).
# The global kernel.apparmor_restrict_unprivileged_userns sysctl is left UNTOUCHED.
#
# Rationale, security trade-off, verification and revert: docs/host_userns_prereq.md
#
#   sudo bash .devcontainer/setup-host-apparmor.sh
#
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)/pcv-apptainer.aaprofile"
DEST=/etc/apparmor.d/pcv-apptainer

if [ "$(id -u)" -ne 0 ]; then
  echo "Please run as root:  sudo bash $0" >&2
  exit 1
fi
if ! command -v apparmor_parser >/dev/null 2>&1; then
  echo "apparmor_parser not found — is AppArmor installed/enabled on this host?" >&2
  exit 1
fi
if [ ! -f "$SRC" ]; then
  echo "Profile not found at $SRC" >&2
  exit 1
fi

echo "[1/3] Installing profile  -> $DEST"
install -m 0644 "$SRC" "$DEST"

echo "[2/3] Parse-checking"
apparmor_parser -Q "$DEST"

echo "[3/3] Loading profile 'pcv-apptainer'"
apparmor_parser -r -W "$DEST"

echo
echo "Done. 'pcv-apptainer' is loaded and will auto-load on every boot."
echo "  Verify:  sudo aa-status | grep pcv-apptainer"
echo "  Revert:  sudo apparmor_parser -R '$DEST' && sudo rm -f '$DEST'"
echo
echo "The global userns sysctl was NOT changed:"
echo "  kernel.apparmor_restrict_unprivileged_userns = $(sysctl -n kernel.apparmor_restrict_unprivileged_userns)"
