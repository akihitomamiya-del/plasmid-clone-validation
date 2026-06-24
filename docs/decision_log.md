# Decision log

Short records of non-obvious choices and *why* we made them, newest first — so a future session (or
teammate) doesn't re-litigate a settled question. See also `archive/setup_and_plan.md` (the plan) and each
topic doc in `docs/`.

---

## 2026-06-24 — Combined amplicon report: post-hoc HTML splice, not a re-render

**Decision.** The single "wf-amplicon QC + annotation" report (the PI's deliverable) is produced by
**splicing** the annotation section into the *finished* `wf-amplicon-report.html`
(`amplicon_annotate/merge_report.py`, run as Stage 5 of `annotate.sh`), **not** by re-composing
wf-amplicon's QC sections from data inside our `combined_report.py`. The splice carries only the annotation
section markup + its one Bokeh embed script and reuses the base report's JS runtime; output is
`amplicon-report-with-annotation.html`.

**Why.** Both reports are `LabsReport`s built by the **same ezcharts version** (wf-amplicon SIF and
wf-clone-validation SIF), so they embed **byte-identical** bokeh/echarts/datatables/bootstrap bundles, and
all element ids are UUIDs. That makes a splice robust (no library version clash, no id collisions, no
duplicated megabytes) and **sidesteps the entire `combined_report.py` re-render risk register** in
`amplicon_plan.md` §8d (R1 ezcharts 0.12.0-vs-0.15.2 behavioural drift, R2 harvesting wf-amplicon's internal
QC files like `qc-summary.tsv`). The merge is pure stdlib → runs on host `python3` (SIF `python` fallback),
so it isn't gated on Apptainer.

**Options considered and rejected.**

| Option | Why rejected |
|---|---|
| Re-render QC+annotation in one `combined_report.py` (the original §8d plan) | Would re-derive wf-amplicon's QC sections in the wrong ezcharts version and require harvesting its internal QC files — exactly R1/R2. The splice reuses wf-amplicon's own already-rendered, already-correct QC. |
| Fork wf-amplicon's `makeReport` to add our section | A fork (drift/maintenance); also can't run — annotation needs the consensus, which only exists *after* wf-amplicon finishes. |
| `<iframe>`/data-URI embed of the whole wf-amplicon report | Bulletproof but ~2× size and a non-unified nav (report-in-a-frame); worse UX than genuinely merged sections. |

**Consequence.** `combined_report.py` is now (slightly misleadingly) named — it builds the **annotation-only**
report; the true combine is `merge_report.py`. Kept the name to avoid churn. The splice depends on ezcharts
HTML structure staying stable across a wf-amplicon bump (anchors: `main-content`/`meta-content`, `Section_*`
ids, `Bokeh.safely`); a bump should re-verify the merged report renders.

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
