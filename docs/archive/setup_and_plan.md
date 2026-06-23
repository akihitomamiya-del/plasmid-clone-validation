# Plan: EPI2ME `wf-clone-validation` in the CLI, with custom read pre-filtering, in a sandboxed container

**Purpose:** a self-contained handoff so a fresh session can build the environment and run
assemblies. Records the goal, the locked decisions, what's already built, the host facts we
measured, the target architecture, and an ordered build plan.

**Last updated:** 2026-06-19. Workflow analysed/pinned: `epi2me-labs/wf-clone-validation` **v1.8.4**.

**Read alongside:** `sif_cache.md` (how to pre-stage the images for offline runs — **required**) and
`assembly_testing.md` (canu vs flye + a test matrix). All paths in this repo are repo-relative.
The `.devcontainer/` and `example_rawdata/` now live together on `main`.

---

## 0. TL;DR + decisions locked

- **Goal:** run ONT's clone-validation pipeline from the CLI, with our own read length/quality
  trimming applied *before* assembly, in a container where **Claude Code stays firewalled exactly
  as it is now** and is usable in `--dangerously-skip-permissions` ("yolo") mode.
- **`wf-clone-validation` is already CLI-native**; the EPI2ME Desktop app is only a GUI over it. It
  already quality-filters with `seqkit seq -Q` (same error-probability mean-Q we use).
- **Decision 1 — Integration:** ✅ **pre-filter wrapper** (`clone_validate.sh`). Option 2 (fork &
  embed) deferred.
- **Decision 2 — Runtime:** ✅ **Apptainer/Singularity**, not Docker-in-Docker (rationale §4).
- **Decision 3 — Where:** ✅ a **dedicated sandboxed devcontainer at `.devcontainer/`** (in THIS
  repo), modeled on L3Rseq's `claude-code` config so Claude + firewall behave identically. A plain
  Docker host is the simpler fallback (Appendix A).

---

## 1. What's already built

| Artifact | Path (repo-relative) | Status |
|---|---|---|
| Read filter (length window + mean-Q) | `filter_nanopore_reads.sh` | ✅ built, tested |
| Clone-validation wrapper | `clone_validate.sh` | ✅ built, tested (filter+reshape+`approx_size` guard); `EXTRA_NF_ARGS` passthrough; prints the `nextflow` cmd when nextflow is absent |
| This plan | `docs/archive/setup_and_plan.md` | ✅ this file |
| SIF pre-staging manifest+recipe | `docs/sif_cache.md` | ✅ exact SHAs + pull recipe; ⚠️ cache filenames need one online validation run (doc explains) |
| Assembly testing (canu vs flye) | `docs/assembly_testing.md` | ✅ params + test matrix |
| Trimmed devcontainer | `.devcontainer/` | ⚠️ **DRAFT** — fixes applied, but **unbuilt/untested** (needs a networked host) |
| Runnable example | `example_rawdata/barcode69/` | ✅ raw concat + reference filtered output |

`clone_validate.sh`: filter → reshape to the `barcodeNN/reads.fastq.gz` layout `--fastq` expects →
`nextflow run … -r v1.8.4 -profile $PROFILE` (+`$EXTRA_NF_ARGS`), with the `approx_size` guard (§2).
Quick check: `./filter_nanopore_reads.sh example_rawdata filtered 5000 20 6000` → ~128 reads,
matching `example_rawdata/barcode69.len5kb-6kb_q20.fastq.gz`.

**Not done:** actually building/running the devcontainer — needs a networked host with Docker (this
firewalled container has no Nextflow/Java/Apptainer and can't pull images; see §5).

---

## 2. How `wf-clone-validation` filters reads (+ the gotcha)

No explicit min/max read-length param — length is derived from `--approx_size`:

| Where | Tool | Effect | Default |
|---|---|---|---|
| `checkIfEnoughReads` (`main.nf`) | `fastcat -a/-b` | keep `0.5×…1.5× approx_size` (length only) + drop sample if `< assm_coverage*0.8` reads | `approx_size=7000`, `assm_coverage=60` |
| Flye/Canu module (`modules/local/*_assembly.nf`) | `seqkit subseq -r 1:(1.2×approx_size)` + `seqkit seq -m 100 -Q $min_quality -g` | length ceiling/floor + **quality** | `--min_quality 9` |

**Gotcha:** a wrong `approx_size` silently re-clips your window. Keep
`ceil(Lmax/1.2) ≤ approx_size ≤ 2×Lmin` (5–6 kb → `approx_size ∈ [5000,10000]`; ≈ true plasmid
size). `clone_validate.sh` enforces this. Full assembly-param detail in `docs/assembly_testing.md`.

---

## 3. Integration = pre-filter wrapper (locked)

`clone_validate.sh <raw_dir> <out_dir> <approx_size> [min_len] [min_qual] [max_len]`.
Env: `PROFILE` (default `standard`; **use `singularity` inside the devcontainer**), `FORCE=1` (bypass
the guard), `EXTRA_NF_ARGS` (extra Nextflow flags, e.g. `--assembly_tool canu`), `WF_VERSION`
(default `v1.8.4`). The wrapper itself exposes only fastq/approx_size/min_quality — anything else
(assembler choice, coverage) goes through `EXTRA_NF_ARGS`.

---

## 4. Runtime = Apptainer/Singularity (locked) — why, not DinD

**Apptainer does not create a network namespace by default — its containers share the host
(outer-container) network stack.** So:
- Workflow processes run in the **same netns as Claude Code** → the **existing `OUTPUT` firewall
  governs them automatically, zero firewall changes.**
- DinD routes inner-container egress through `FORWARD`, **bypassing** the `OUTPUT` allowlist; you'd
  have to add `FORWARD`/`DOCKER-USER` policy, run a `dockerd` daemon, and use `--privileged`.
- Apptainer needs **no daemon** and **no `--privileged`** — only targeted loosenings (§6).

With SIFs **pre-staged at build** (`docs/sif_cache.md`), a run on local FASTQs needs **no registry
egress**, so the runtime firewall stays fully closed and the workflow is sandboxed for free.

---

## 5. Host-probe findings (why the current container can't run it as-is)

Measured 2026-06-19 inside this devcontainer:

| Probe | Result | Implication |
|---|---|---|
| `user.max_user_namespaces`=504928; `unprivileged_userns_clone`=1 | host **allows** userns | kernel not the blocker |
| `unshare --user` / `--mount` | ❌ Operation not permitted | container **blocks** namespace creation |
| `/dev/fuse` | absent; no `fusermount` | no FUSE for rootless SIF mounting |
| `CapEff` | `0x0` | hardened; no `CAP_SYS_ADMIN` |

**Cause (full picture, validated end-to-end 2026-06-19):** four layers, all cleared in the
devcontainer — no global host change:
1. Docker's default **seccomp** denies `clone/unshare` with `CLONE_NEWUSER` → `seccomp=unconfined`.
2. Rootless SIF mounting needs FUSE → `--device /dev/fuse`.
3. With `kernel.apparmor_restrict_unprivileged_userns=1`, the **userns gate** blocks *unconfined*
   processes while **`docker-default` denies `mount`**; a custom **`pcv-apptainer`** AppArmor profile
   (confined *and* permits userns+mount) opens both → `--security-opt apparmor=pcv-apptainer`.
   (`apparmor=unconfined` would instead need a global `sysctl=0`; the profile avoids that.)
   See `docs/host_userns_prereq.md`.
4. Docker **masks parts of `/proc`**, so the workflow's nested Apptainer (`--containall`/`--pid`)
   can't mount a fresh `/proc` ("operation not permitted") → `--security-opt systempaths=unconfined`.
   Independent of the userns gate — and the reason the earlier `sysctl=0` recipe never completed a
   real pipeline run.

---

## 6. Target architecture: the `.devcontainer/` (DRAFT, in this repo)

Built (as a draft) at **`.devcontainer/`** — `Dockerfile`, `devcontainer.json`, the vendored
firewall scripts (`init-firewall.sh`, `start-firewall.sh`, `firewall-warning.sh`), and a `README.md`.
Design vs L3Rseq `claude-code`:

- **Dropped:** the heavy `l3rseq` base image (conda envs, BLAST DBs), Puppeteer/Chrome, conda init.
- **Kept:** the egress firewall (vendored) + Claude Code CLI + non-root `vscode` user.
- **Added:** Java 17, Nextflow, Apptainer, `seqkit`; pre-staged SIFs (`docs/sif_cache.md`).
- **runArgs:** `--cap-add=NET_ADMIN/NET_RAW` (firewall) + `--security-opt seccomp=unconfined` +
  `--security-opt apparmor=pcv-apptainer` + `--security-opt systempaths=unconfined` +
  `--device /dev/fuse` (rootless Apptainer — §5). Much
  narrower than DinD's `--privileged`; network egress is still the firewall's. **HOST PREREQUISITE
  (one-time, admin):** `sudo bash .devcontainer/setup-host-apparmor.sh` loads the profile — no global
  sysctl change (`docs/host_userns_prereq.md`). **CAVEAT: `runArgs` are ignored by GitHub Codespaces**
  — build locally (VS Code / devcontainer-CLI), not on Codespaces, or Apptainer won't run.

Fixes already applied to the draft (were bugs found in review):
- **firewall-warning banner wired into `~/.bashrc`** (else fail-open is silent — the safety
  interlock for yolo mode).
- **SIF pre-staging implemented** in the Dockerfile (SHAs read from `base.config`; see
  `docs/sif_cache.md`) + `nextflow pull -r v1.8.4`; `NXF_OFFLINE=true` set **after** the pulls.
- **No volume mounted over `/opt/sif-cache`** (a volume would shadow the baked cache → empty →
  offline run fails). `/opt/sif-cache` + `/opt/nextflow` are baked into the image.

Still **DRAFT / unverified** — see §9. Claude yolo mode: launch `claude --dangerously-skip-permissions`
as the `vscode` user (it refuses to run as root); auth via injected `CLAUDE_CODE_OAUTH_TOKEN` or
`ANTHROPIC_API_KEY` (both wired in `devcontainer.json`); the firewall is the guardrail — verify
`/tmp/firewall-status` is `ok` before relying on it.

---

## 7. Build plan for the next session (ordered, on a networked host)

**Phase 0 — De-risk spike (do first).** On any host with open network + Docker + `/dev/fuse`, build a
throwaway image with Apptainer and confirm a **rootless** SIF run works with
`--security-opt seccomp=unconfined --device /dev/fuse` and **no** `--privileged`:
`apptainer exec <some>.sif echo ok` as non-root. Resolve §9. If FUSE is troublesome, test the
`apptainer build --sandbox` (exploded-dir) fallback.

**Phase 1 — Build the devcontainer.** It already exists at `.devcontainer/`. Build it (VS Code
"Reopen in Container" or `devcontainer build`). *Success:* image builds; firewall verification passes
(`example.com` blocked, `api.github.com` allowed); Claude CLI runs; the fail-open banner appears if
you deliberately break the firewall.

**Phase 2 — Confirm the runtime.** Inside the built container: `java -version`, `nextflow info`,
`apptainer --version`, `seqkit version`, `claude --version`.

**Phase 3 — Validate the offline SIF cache.** Per `docs/sif_cache.md`: confirm the 5 `.img` files in
`/opt/sif-cache` and — critically — that their **filenames match what Nextflow expects** (do one
online run and `ls` the cache to read back the exact names, then codify them). `nextflow pull` of the
pipeline is baked in.

**Phase 4 — End-to-end offline run** with the firewall **on**:
`PROFILE=singularity ./clone_validate.sh example_rawdata runs/cv 5500 5000 20 6000`. *Success:*
completes purely from `/opt/sif-cache` (watch `ss`/`conntrack` for zero non-allowlisted egress);
`runs/cv/cloneval/` has an assembly + report; surviving-read count ≈ the ~128 pre-filtered reads.
Then sweep assemblers per `docs/assembly_testing.md` (`EXTRA_NF_ARGS="--assembly_tool canu"`, etc.).
**Correctness target:** `reference_run_canu/` (an EPI2ME canu run on this same data) — a canu run should
reproduce **1 contig, ~5,652 bp, status `Completed successfully`**. Match the reference exactly with
`EXTRA_NF_ARGS="--assembly_tool canu --assm_coverage 60" ./clone_validate.sh example_rawdata runs/cv_canu 5000 5000 20 6000`
(it used `approx_size=5000`). flye on the same data is expected to fail.

**Phase 5 — Publish.** Dockerfile changes → tagged release → CI builds/publishes the image → rebuild
the devcontainer. Decide the image registry/namespace.

---

## 8. Verification plan

- **Sandbox intact:** `init-firewall.sh` self-test passes; Claude works as now; banner fires on a
  forced fail-open.
- **Offline workflow:** Phase-4 run completes with no non-allowlisted egress.
- **Filter correctness:** workflow input counts match `filter_nanopore_reads.sh`; no zero-read
  samples (would signal `approx_size` re-clipping).
- **Negative check:** rename one SIF and re-run — it should **fail offline**, proving `NXF_OFFLINE` +
  cache wiring are in force (not silently re-pulling).

---

## 9. Open unknowns — mostly RESOLVED (2026-06-19, on `validation-host`)

1. ✅ **RESOLVED.** `seccomp=unconfined` + `/dev/fuse` are necessary but **not** sufficient on a host
   with `apparmor_restrict_unprivileged_userns=1`: also need the **`pcv-apptainer`** AppArmor profile
   (unconfined userns is blocked; `docker-default` blocks `mount`). **No cap add needed.** Validated
   on the real image (non-root `apptainer exec` of the workflow SIFs). See `docs/host_userns_prereq.md`.
2. ✅ **RESOLVED.** `/dev/fuse` is present and squashfuse mounts the SIFs on this host (native Docker
   29, **not** Desktop — confirmed via `docker context`/kernel check). No `--sandbox` fallback needed.
3. ✅ **RESOLVED.** Build-time `apptainer pull` (root in BuildKit) needs no `--fakeroot`; the image
   builds and stages the 5 SIFs. `/etc/subuid`,`/etc/subgid` for `vscode` are present.
4. The exact **SIF cache filename mangling** for the installed Nextflow version (validate per
   `docs/sif_cache.md`) — and a full end-to-end `nextflow run` under the profile (the Apptainer layer
   is validated; the full pipeline run is the remaining confirmation).

---

## 10. References / key paths

- Workflow: `github.com/epi2me-labs/wf-clone-validation` @ **v1.8.4**
  - filtering: `main.nf` `checkIfEnoughReads` (fastcat `-a/-b`); `modules/local/{flye,canu}_assembly.nf` (`seqkit seq -Q`)
  - assembler switch: `main.nf:7-11` (`--assembly_tool`, default `flye`)
  - containers/SHAs: `base.config` (`params.wf.*`) — enumerated in `docs/sif_cache.md`
- This repo: `.devcontainer/{Dockerfile,devcontainer.json,init-firewall.sh,start-firewall.sh,firewall-warning.sh}`,
  `filter_nanopore_reads.sh`, `clone_validate.sh`, `docs/{sif_cache,assembly_testing}.md`,
  `example_rawdata/barcode69/`
- Source we modeled the firewall/devcontainer on (in the **L3Rseq** repo, not here):
  `.devcontainer/claude-code/`
- `--fastq` layout: single FASTQ | flat dir (single sample, `--sample`) | dir of `barcodeNN/` subdirs
  (multiplexed; `example_rawdata/` uses this). `--reference` is deprecated; use `--insert_reference`.

---

## Appendix A — Simpler fallback: run on a plain host (no devcontainer work)

```bash
# Java 17+, then:
curl -s https://get.nextflow.io | bash && sudo mv nextflow /usr/local/bin/
nextflow pull epi2me-labs/wf-clone-validation -r v1.8.4
# Docker workstation: PROFILE=standard ; HPC: PROFILE=singularity (+ NXF_SINGULARITY_CACHEDIR)
PROFILE=standard ./clone_validate.sh example_rawdata runs/cv 5500 5000 20 6000
```
Same wrapper and `approx_size` discipline; only the execution host differs. Use this to get results
immediately while the sandboxed-container build proceeds in parallel.
