# setup_and_plan.md — ARCHIVED

> **This document is archived.** It was the original build/architecture plan (the ordered
> build phases, target devcontainer design, host probes). That plan is **fully executed**:
> the devcontainer was split into a publishable lean runtime image + a Claude-Code yolo
> sandbox, and GHCR CI ships it — done in commit **187381b**.

**Full historical record:** [`docs/archive/setup_and_plan.md`](archive/setup_and_plan.md).

**For the current state, read instead:**
- [`.devcontainer/README.md`](../.devcontainer/README.md) — authoritative devcontainer structure (runtime image + Claude-Code sandbox).
- [`docs/decision_log.md`](decision_log.md) — locked decisions.
- [`docs/host_userns_prereq.md`](host_userns_prereq.md) — the rootless-Apptainer `runArgs` rationale.

The durable `approx_size` envelope rule (`ceil(max_len/1.2) ≤ approx_size ≤ 2×min_len`) now
lives in `CLAUDE.md` and `docs/assembly_testing.md`.
