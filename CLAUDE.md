# plasmid-clone-validation — Claude Code guide

Baked-in context for working in this repo. This file is auto-loaded every session; the full detail
lives in `docs/`.

## What this repo is
CLI tooling to run Oxford Nanopore's **EPI2ME `wf-clone-validation`** (plasmid assembly + QC) with our
own **read pre-filtering** (length window + mean Q) applied *before* assembly — plus a **dedicated
sandboxed devcontainer** so Claude Code runs firewalled (safe for `--dangerously-skip-permissions`)
while the workflow runs **offline** via Apptainer.

A **second pipeline** wraps EPI2ME **`wf-amplicon`** (de-novo amplicon consensus) and adds **pLannotate-style
BLAST annotation** of that consensus + an offline HTML report — `amplicon_validate.sh` → `amplicon_annotate/`.

## Start here (docs map)
- `docs/getting_started.md` — **newcomer walkthrough** (run the shipped example → your own data → read the
  report); the gentle, hand-holding path before this terse guide. Point a brand-new user here first.
- `.devcontainer/README.md` — **authoritative for the devcontainer** (the runtime image `build/` vs the
  Claude-Code sandbox `claude-code/`, the containment model, host prereq, local build vs GHCR pull).
- `docs/archive/setup_and_plan.md` — *archived* original build plan (now executed); see `.devcontainer/README.md`.
- `docs/verify_devcontainer.md` — in-container checks: confirm the build is sandboxed and runs the pipeline.
- `docs/sif_cache.md` — pre-stage the workflow images for offline runs (**required**; exact SHAs).
- `docs/assembly_testing.md` — canu vs flye: the param sweep + why flye fails on this data.
- `docs/assembly_findings_2026-06-21.md` — **which lever decides the assembly** (assembler ≫ filtering); the
  validated flye-`SIGFPE` mechanism, the data-driven peak finder (`estimate_length_peak.sh`), inside-vs-outside.
- **Amplicon pipeline:** `docs/amplicon_plan.md` (design/roadmap), `docs/amplicon_annotate.md` (the
  pLannotate BLAST annotation + HTML report), `docs/amplicon_testing.md` (host build/test). Code:
  `amplicon_validate.sh` + `amplicon_annotate/`; example reads in `examples/amplicon/raw/`, correctness
  target in `examples/amplicon/reference_run_wf-amplicon/` (de-identified; 2 amplicons, ~2,156 & ~3,283 bp).
  Both pipelines share the layout `examples/<pipeline>/{raw/, reference_run_*/}`.
- **Annotation add-ons:** `docs/arabidopsis_annotation_plan.md` (custom *A. thaliana* AGI/gene/function DB —
  amplicons **and** plasmids via `CIRCULAR`; §9), `docs/arabidopsis_annotation_testing.md` (host-side test
  runbook), `docs/reference_validation.md` (`validate_against_reference.sh` — flag consensus-vs-reference
  mutations: subs/indels/truncations + which feature each lands in).
- `examples/plasmid/reference_run_canu/` — EPI2ME **canu** reference output = the build's correctness target
  (expected: **1 contig, 5,652 bp, "Completed successfully"**; that run used `approx_size=5000`).
- `README.md` — quickstart + **"Before you build"** host prerequisites/secrets + the **PI amplicon
  walkthrough** (run the example → your data → open the report).

## Playbook: "run the amplicon workflow with annotation" (a PI request)
When the user asks in plain language to **run the amplicon workflow (with annotation) on a directory**
(e.g. *"run the amplicon validation on runs/plate3"*, *"annotate the amplicons in <dir>"*), just do it —
don't make them recall a flag:
1. **One entrypoint:** `./amplicon_validate.sh <raw_dir> <out_dir>`. `<raw_dir>` is the dir they named;
   **expected layout `<raw_dir>/barcodeNN/*.fastq.gz`** (two-digit barcodes). If they gave no out dir, use
   `runs/<basename-of-raw_dir>` and say where it went. **No other args** — leave `none 300 15` (medaka
   auto-picks its model from the read headers); add a pre-filter / `REF=` / `OVERRIDE_BASECALLER_CFG` only
   if explicitly asked. This runs wf-amplicon de-novo **then** the annotation + combined report + the
   deliverables bundle automatically.
2. **Report back, leading with the bundle:** `<out_dir>/deliverables/` (a tidy folder — open
   `amplicon-report-with-annotation.html`; `README.txt` explains every file) and `<out_dir>/deliverables.zip`.
   The key per-file paths (combined report, `<barcode>_<bp>bp.gbk`, `feature_table.txt`) are echoed by the
   wrapper — relay those as clickable paths. To view the HTML in-container: right-click → Live Preview.
3. **Multi-barcode** is normal: one consensus + one `.gbk` per barcode, all folded into the one combined
   report and the one bundle. Say how many barcodes were annotated.
4. **If it fails / no consensus:** the wrapper prints a `NO DELIVERABLE` banner — relay it plainly, point at
   `<out_dir>/amplicon/wf-amplicon-report.html`, and don't claim an annotation was produced.

## Locked decisions (don't re-litigate)
- Integration = **pre-filter wrapper** (`clone_validate.sh`), NOT a fork of the workflow.
- **Amplicon = a second wrapper** (`amplicon_validate.sh`) over `wf-amplicon` **de-novo** (never `--reference`)
  + a **pLannotate `--linear` annotation** post-step (`amplicon_annotate/`) that BLASTs the consensus, renders
  an offline HTML report, and **splices that annotation into the wf-amplicon report → one combined
  `amplicon-report-with-annotation.html`** (`merge_report.py`, a post-hoc HTML splice — NOT a re-render).
  NOT a fork; the `--linear` patch to `run_plannotate.py` is vendored.
- Runtime = **Apptainer/Singularity**, NOT Docker-in-Docker (Apptainer shares the host netns, so the
  egress firewall governs the workflow for free).
- The devcontainer is a **multi-artifact split** under `.devcontainer/` (built + validated):
  `build/` = the publishable lean runtime image (→ `ghcr.io/akihitomamiya-del/plasmid-clone-validation:latest`;
  base + Java + Nextflow + Apptainer + seqkit + **6 baked SIFs** (5 clone-val + wf-amplicon) + workflows + scripts
  + amplicon annotation; ~6 GB, no Claude/firewall), and `claude-code/` = the yolo sandbox built `FROM` it
  (+ node + Claude + egress firewall + sudo-lockdown), **also published** as `:claude-code`. `claude-code-image/`
  is a **pull** config for that prebuilt sandbox (no local build). Top-level `.devcontainer/devcontainer.json` is
  the default (pipeline from the published image). Authoritative detail: `.devcontainer/README.md`.
- Rootless Apptainer on a userns-hardened host (`apparmor_restrict_unprivileged_userns=1`) is enabled
  by a **scoped AppArmor profile** (`pcv-apptainer`), NOT the global `sysctl=0`. Why + options
  rejected: `docs/decision_log.md`; how-to: `docs/host_userns_prereq.md`.

## Critical gotchas (expensive to rediscover)
- **The images can't be built inside the firewalled sandbox** (only GitHub/npm/Anthropic reachable) — build
  the runtime on a networked host with Docker + `/dev/fuse`, or just **pull** it from GHCR. The `build/`
  runtime is heavy (~5.3 GB, 5 baked SIFs); the `claude-code/` sandbox layers `FROM` it and is thin (~230 MB).
- **Host AppArmor prereq (one-time, admin):** any config that runs Apptainer (default / build / claude-code)
  uses `--security-opt apparmor=pcv-apptainer`. On a host with `apparmor_restrict_unprivileged_userns=1`
  (Ubuntu 23.10+) load it first: `sudo bash .devcontainer/setup-host-apparmor.sh` — else Docker errors
  *"apparmor profile pcv-apptainer not found"* and the container won't start. **No global sysctl
  change** (the old `sysctl=0` recipe is a not-recommended fallback). Validated 2026-06-19; see
  `docs/host_userns_prereq.md`.
- **`approx_size` envelope rule:** keep `ceil(max_len/1.2) ≤ approx_size ≤ 2×min_len`, ≈ the true
  construct size, or `wf-clone-validation` silently re-clips your reads. `clone_validate.sh` guards it.
- **Wrappers `cd "$OUT"` before Nextflow (work-dir fix, 2026-06-24):** a standalone `docker run …
  *_validate.sh …` starts in CWD `/` (non-root `vscode` can't write), so Nextflow's `work/`/`.nextflow/`
  creation aborts the run. Both wrappers resolve `$OUT` absolute and launch from it. The mounted output dir
  must be writable by the container **uid 1000** (`chmod 777` it if your host UID differs).
- **Amplicon annotation is offline + Apptainer-only:** `amplicon_annotate/annotate.sh` runs `run_plannotate.py
  --linear` (plannotate SIF) then `combined_report.py` (wf-clone-validation SIF) via `apptainer exec` — all
  BLAST DBs are baked. The report has a **linear feature track** (`linear_feature_map()`) plus pLannotate's
  native circular map. The Apptainer stages are skipped on a Docker-only host (no Apptainer).
- **Arabidopsis mode (`ARAB_DB`, opt-in, 2026-06-25):** set `ARAB_DB=<dir with arabidopsis.dmnd +
  arabidopsis.csv>` on `amplicon_validate.sh`/`annotate.sh` to also `diamond blastx` each consensus against a
  custom *A. thaliana* proteome → adds an **`Accession` (AGI locus)** column + `arabidopsis` features carrying
  gene symbol (`Feature`) + function (`Description`), and folds the AGI into the `.gbk` `/label`. All changes
  are **gated** — unset ⇒ output byte-identical to stock. The DB is **bind-mounted** (no SIF rebuild); the real
  config is the runtime-generated `plannotate.yaml` in `run_plannotate.py:make_yaml`, NOT the SIF's
  `databases.yml`. Build the DB **outside the firewall** (`build_arabidopsis_db.sh`; Ensembl Plants pep is
  egress-blocked inside — it now auto-fetches a version-matched diamond 2.1.15 if none is on PATH). Full
  runbook + design rationale: `docs/arabidopsis_annotation_plan.md`. **Now baked into the published runtime
  image** at build time (`ENV ARAB_DB=/opt/pcv/arabidopsis_db`), so it's on by default — `env -u ARAB_DB`
  for the stock baseline. **Plasmids:** `CIRCULAR=1 annotate.sh` (omits `--linear` → circular GenBank) + an
  `ARAB_DB`-gated post-step in `clone_validate.sh` annotate the plasmid assembly the same way (§9).
- **Reference check (`validate_against_reference.sh`, 2026-06-26):** the complementary "does my clone match
  the intended construct?" step — `minimap2 -a --cs -x asm10` (wf-amplicon SIF) + the stdlib
  `amplicon_annotate/variant_parser.py` flag substitutions/indels/truncations vs a user `.gbk`/`.fasta` and
  tag which annotated feature each lands in → `variants_vs_reference.csv` + `variant_summary.txt`. Apptainer-
  only (no-ops on a Docker-only host); `variant_parser.py --selftest` runs host-side. See `docs/reference_validation.md`.
- **Combined report (Stage 5):** when the wf-amplicon report is passed as `annotate.sh` arg 5
  (`amplicon_validate.sh` does this automatically), `merge_report.py` splices the annotation section into it
  → one self-contained `amplicon-report-with-annotation.html` = wf-amplicon QC + annotation. It is **pure
  stdlib** (host `python3`, SIF `python` fallback — NOT Apptainer-only) and safe because both reports embed
  byte-identical ezcharts/bokeh bundles (reuse the base runtime; UUID ids ⇒ no collisions). Don't add JS
  libraries to the splice or re-carry the DataTable init (it's inline in the section). See `docs/amplicon_annotate.md`.
- **Mode B — single barcode, multiple amplicons (`SPLIT=1`, prototype):** stock wf-amplicon de-novo keeps only
  ONE consensus per barcode (`trim_and_qc.py` picks the highest-depth contig), so a mixed barcode collapses to
  one product. `SPLIT=1 amplicon_validate.sh …` runs `amplicon_split.sh` first — **reference-free** read
  clustering by `minimap2 -x ava-ont` overlap (union-find) → one wf-amplicon sample (`barcodeNN_cK`) per
  amplicon → each assembled + annotated in the one combined report. **Distinct-locus only** (amplicons sharing
  a region longer than `SPLIT_MIN_OVERLAP` merge → use `REF=`). `none` filter mode only. Validated on the
  committed example (`examples/amplicon/raw/`): mixing its two barcodes into one →
  2 clusters → both amplicons (~2,156 & ~3,283 bp) recovered @100%. See `docs/amplicon_plan.md` §3 (B2-reffree).
- **SIF cache filenames** Nextflow expects must be confirmed by one online run (`docs/sif_cache.md`) —
  the #1 thing that silently breaks offline.
- **Assembler is THE critical lever (validated 2026-06-21):** `clone_validate.sh` now **defaults to
  canu**; force flye with `EXTRA_NF_ARGS="--assembly_tool flye"` (expect failure). Canu gives 1 contig /
  5,652 bp in *every* condition (raw, Q-only, length-only, length+Q, even wrong `approx_size`). **Flye
  fails** on RBK full-length plasmid reads: it auto-picks min-overlap ≈6000 bp > the ~5.6 kb reads →
  zero overlaps → `SIGFPE` (divide-by-zero). min-overlap is **read-driven, not approx_size-driven**
  (`flye_assembly.nf:27` only overrides it for approx_size ≤ 3000), so length-/quality-selecting does
  NOT rescue flye (it makes it worse) — the assembler choice does. Mechanism + factorial:
  `docs/assembly_findings_2026-06-21.md`.
- **Data-driven sizing:** `estimate_length_peak.sh <reads.fastq.gz> --report-only` finds the full-length
  read-length peak + window (no hand-picked threshold) and prints `PEAK_WINDOW peak lo hi`. The wrapper
  automates this **per sample** via `clone_validate.sh <raw> <out> auto` (peak → window + per-sample
  `approx_size` through a generated sample sheet; outputs are named by alias `sampleNN`). Yield-weighted
  histogram robustly picks the full-length peak over short adapter/fragment junk.
  - **Plasmid filter defaults loosened 2026-06-25 → window peak ±15% (`estimate_length_peak.sh` `WIDTH=pct:15`)
    and min Q 15 (`clone_validate.sh` `MINQ` default).** Rationale: keep low-yield samples analyzable by
    default — on the MT260625 ~17 kb plasmids the old peak ±10% / Q20 starved the thin barcodes (51–52 full-length
    reads); ±15% / Q15 recovers ~2–3× the depth (→ 144–160 reads), all still full-length, with no loss on
    high-yield samples. Override per run with args 4/5/6 (MANUAL) or `--width`/`--min-qual` on the peak finder.
- **seqkit `-Q`** is the Nanopore error-probability mean Q (the same metric the workflow uses) — correct
  for read filtering; it is NOT the arithmetic Phred mean.
- **Claude yolo mode** runs as the non-root `vscode` user, but **Claude is installed as root** (global prefix
  root-owned) so the contained agent can't modify/replace its own CLI or `npm i -g` (the one sanctioned
  update is the scoped, root-owned `install-claude.sh` refresh — still root-owned, so the binary stays
  immutable to the agent). It needs a token in the
  host env (`CLAUDE_CODE_OAUTH_TOKEN`/`ANTHROPIC_API_KEY`); `claude /login` won't work (firewall blocks
  claude.ai). The firewall is the guardrail — confirm `/tmp/firewall-status` is `ok` before relying on it.
  Two non-obvious requirements (both silently break auth):
  (1) **`~/.claude` must be `vscode`-owned.** The config volume mounts there; if the image doesn't
  pre-create+chown `/home/vscode/.claude` the named volume comes up `root`-owned and the CLI can't
  persist credentials/onboarding. `.devcontainer/claude-code/Dockerfile` creates+chowns it — don't drop that line.
  (2) **Use a long-lived `claude setup-token`, NOT a normal login's access token.** Access tokens expire
  in hours and refresh via claude.ai, which the firewall blocks → the token dies and can't renew
  in-container. `setup-token` is long-lived and used directly as a bearer (no refresh needed).
- **Claude CLI is intentionally `@latest`, NOT pinned** (decision 2026-06-21) — it lives only in the thin
  `claude-code` layer (a rebuild is ~230 MB and never disturbs the runtime base/SIFs). Don't pin
  `CLAUDE_CODE_VERSION`. The live CLI is kept current **without an image rebuild** by `install-claude.sh`
  (a third scoped-sudo, root-owned `npm i -g` refresh): it runs at container-create (postCreate
  `claudeRefresh`, pre-firewall) and on demand (`sudo /usr/local/bin/install-claude.sh`), and
  `registry.npmjs.org` is firewall-allowlisted so it works post-firewall too. The baked install is the
  **offline fallback** — a *warm* image rebuild keeps that cached/stale copy (it does NOT advance the
  version; the refresh or a `--no-cache` rebuild does). See `docs/claude_cli_version_handoff.md`.

## Conventions & guardrails
- Shell scripts use `set -euo pipefail`, live at the repo root, and are reusable/parameterized.
- Runnable example: `examples/plasmid/raw/barcode69/` (raw concat). Length/quality thresholds are inclusive (`≥`).
- **Never commit real sequencing data** — `.gitignore` blocks `*.fastq.gz` etc.; only `examples/plasmid/raw/**`
  is allowlisted. Pipeline outputs (`runs/`, `cloneval/`, `nf_input/`, `work/`, `*.sif`) are ignored.
- `PROFILE` auto-detects: `singularity` when only Apptainer is present (the devcontainer), else `standard`.
- Verify changes: `bash -n` the scripts; the filter on `examples/plasmid/raw` yields **128 reads** (5–6 kb, Q≥20).
- Changes under `.devcontainer/build/` or `.devcontainer/claude-code/` can't be validated inside the firewalled
  sandbox — say so and defer to a host build (or a GHCR pull for the runtime).
