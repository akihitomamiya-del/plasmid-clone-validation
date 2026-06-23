# Decision log

Short records of non-obvious choices and *why* we made them, newest first — so a future session (or
teammate) doesn't re-litigate a settled question. See also `setup_and_plan.md` (the plan) and each
topic doc in `docs/`.

---

## 2026-06-19 — Rootless Apptainer on a userns-hardened host: scoped AppArmor profile, not the global sysctl

**Decision.** The devcontainer enables rootless Apptainer with a **custom, opt-in AppArmor profile**
`pcv-apptainer` (loaded once on the host via `.devcontainer/setup-host-apparmor.sh`) — **not** by
relaxing the global `kernel.apparmor_restrict_unprivileged_userns` sysctl. Runtime flags:
`seccomp=unconfined` + `apparmor=pcv-apptainer` + `systempaths=unconfined` + `/dev/fuse`. How-to +
trade-off + revert: `host_userns_prereq.md`.

**Why we had to do this.** The lab host (`validation-host`, Ubuntu, kernel 6.17) ships the
Ubuntu 23.10+ hardening `apparmor_restrict_unprivileged_userns = 1`. Rootless Apptainer (the
devcontainer's setuid-less install) must create an unprivileged **user namespace** *and* perform
**mounts** to set up each workflow container. On this host those are blocked by **two separate**
AppArmor gates, and no single stock setting opens both:

- **userns gate** — at `sysctl=1`, unprivileged userns creation is denied for *unconfined* processes
  (so `apparmor=unconfined`, and even `--privileged`, fail at `Could not write info to setgroups:
  Permission denied`); but it is *allowed* for a process confined by a named profile carrying `userns,`.
- **mount gate** — Docker's stock `docker-default` profile denies the `mount` Apptainer needs (fails at
  `Failed to set mount propagation: Permission denied`).

`pcv-apptainer` is the one config that opens both: it stays **confined** (userns gate ✅) *and* permits
**mount** (mount gate ✅).

**Options considered and rejected.**

| Option | Why rejected |
|---|---|
| `apparmor=unconfined` + global `sysctl=0` (the previously-committed recipe) | Works only *while* the sysctl is 0: the live toggle reverts on reboot, the no-sudo user `user` can't set it, and it weakens userns hardening **host-wide** for every user (incl. the sequencing user). On this box at `sysctl=1` it simply fails. |
| setuid Apptainer + `CAP_SYS_ADMIN` (instead of rootless) | Insufficient — still fails at the mount-namespace setup short of near-`--privileged`, and adds privilege the design avoids. |
| `--privileged` workflow container | Defeats the yolo sandbox (container escape) and *still* needs `sysctl=0` for the unconfined userns. |
| Run the workflow on host Docker (`-profile standard`) instead of nested Apptainer | Would hand a yolo-mode agent the Docker socket (host root) or bypass the egress firewall. The nested-Apptainer design is deliberately daemon-less for sandbox safety. |

**Consequences.**
- A **one-time admin step** (`sudo bash .devcontainer/setup-host-apparmor.sh`) is required before the
  devcontainer's first use on a host. It persists across reboots (profile lives in `/etc/apparmor.d/`)
  and is reversible.
- After that, **non-sudo users** (e.g. `user`, in the `docker` group) use the devcontainer with no
  further privilege — `docker run` only *names* the already-loaded profile.
- Host-wide userns hardening is **preserved** (the relaxation is opt-in per container).
- The profile is intentionally broad on AppArmor mediation; the real controls are the egress firewall,
  Docker's default capability drop, the non-root user, and userns isolation. Tightening it toward a
  `docker-default`-plus-`userns`/`mount` profile is future hardening.

**Also required (found while validating the full pipeline): `systempaths=unconfined`.** Docker masks
parts of `/proc`, so the workflow's *nested* Apptainer (`--containall`/`--pid`) can't mount a fresh
`/proc` (`mount proc: operation not permitted`). This is **independent** of the userns gate above — and
the reason the prior `apparmor=unconfined`+`sysctl=0` recipe never actually completed a real run. Fix:
add `--security-opt systempaths=unconfined` to the devcontainer runArgs (container-scoped; far short of
`--privileged`).

**Validated end-to-end** 2026-06-19 on `validation-host` (native Docker 29, kernel 6.17.0-35,
`sysctl=1`): the full **offline** canu pipeline (`PROFILE=singularity clone_validate.sh … --assembly_tool
canu`, `--network none`) runs as non-root `vscode` under the profile and reproduces the reference
exactly — **1 contig, 5,652 bp, "Completed successfully"** (matches `reference_run_canu/`). Profile +
`apparmor=pcv-apptainer` introduced in commit `0f3ea77`; `systempaths=unconfined` in the follow-up.
