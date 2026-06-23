# validation_findings_2026-06-19.md — ARCHIVED

> **This document is archived.** It was the devcontainer security-validation session log.
> Its three findings are all **shipped** and summarized in
> [`.devcontainer/README.md`](../.devcontainer/README.md) ("Claude yolo-mode containment"):
> (1) the uid-portability fix, (2) the sudo lockdown (so a yolo agent can't flush the egress
> firewall), and (3) the fail-open `/tmp/firewall-status` pre-plant hardening.

**Full historical record:** [`docs/archive/validation_findings_2026-06-19.md`](archive/validation_findings_2026-06-19.md).

⚠️ **Do NOT act on this doc's old §3.1/§4 advice to chown `/opt/sif-cache`.** The refactor
**deliberately reversed** it: `fix-opt-ownership.sh` now chowns **only** `/opt/nextflow`; the
SIFs are left world-readable `root:root 0755`.
