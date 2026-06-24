# plasmid-clone-validation

CLI tooling for Oxford Nanopore data, with **two pipelines**:
- **Plasmid clones** — EPI2ME **`wf-clone-validation`** (assembly + QC) with custom read pre-filtering
  (length window + mean Q-score) applied *before* assembly.
- **Amplicons** — EPI2ME **`wf-amplicon`** (de-novo consensus) plus pLannotate BLAST **annotation** and one
  combined report. → **[Amplicon quick start](#amplicon-quick-start-with-annotation)**.

Integration approach: a **pre-filter wrapper** — our filter runs first, then the unmodified
`wf-clone-validation` workflow consumes the filtered reads. (The EPI2ME Desktop app is just a
GUI over this Nextflow workflow; it is CLI-native.)

> **New here and just want to run it?**
> - **Amplicon reads** (de-novo consensus + annotation) → **[Amplicon quick start](#amplicon-quick-start-with-annotation)** just below.
> - **Plasmid clones** (assembly + QC) → **[`docs/getting_started.md`](docs/getting_started.md)**, a step-by-step walkthrough.
>
> The rest of this README is the terse reference.

## Amplicon quick start (with annotation)

**Got Oxford Nanopore amplicon reads and want an annotated report?** Three steps.

**1 — Put your reads in barcode folders.** One folder per barcode, named `barcode01`, `barcode02`, … (this
is how MinKNOW already saves them):

```
my_amplicons/
  barcode01/   *.fastq.gz      ← one amplicon (one PCR product) per barcode
  barcode02/   *.fastq.gz
```

**2 — Run one command** (inside the devcontainer, where Nextflow + Apptainer are already set up):

```bash
./amplicon_validate.sh my_amplicons runs/my_amplicons
```

It builds a consensus sequence for each barcode, finds known elements in it (genes, promoters, sites…) by
BLAST, and makes one report. **Prefer to just ask Claude?** Say *“run the amplicon workflow with annotation
on my_amplicons”* — it runs the same thing and points you to the report.

**3 — Open your results.** Everything you need is gathered into one folder:

```
runs/my_amplicons/deliverables/
  amplicon-report-with-annotation.html   ← OPEN THIS  (QC + annotated features, one page)
  barcode01_3249bp.gbk                    ← annotated GenBank — open in SnapGene / Benchling / ApE
  feature_table.txt                       ← every feature, as a spreadsheet (Excel)
  README.txt                              ← says what each file is
  …                                       (one .gbk per barcode; plus deliverables.zip to email)
```

To view the `.html` inside VS Code: right-click it → **Show Preview**.

> **First time on this machine?** Two one-time admin steps are needed (pull the image; load the Apptainer
> security profile) — see **[Before you build](#before-you-build-host-prerequisites--secrets)**. After that,
> it's just the one command above (or asking Claude).

Full amplicon reference (options, how it works, the annotation): **[`docs/amplicon_annotate.md`](docs/amplicon_annotate.md)**.

### Two or more amplicons in the *same* barcode? (`SPLIT=1`)

If you pooled **several different PCR products into one barcode**, add `SPLIT=1`:

```bash
SPLIT=1 ./amplicon_validate.sh my_amplicons runs/my_amplicons
```

It automatically separates the reads by amplicon — **no reference needed** — and gives you **one consensus
+ one annotation per amplicon**, all in the same combined report and `deliverables/` folder (named
`<barcode>_c01_*`, `<barcode>_c02_*`, …). It’s safe to leave on for normal single-amplicon barcodes too
(they just come out as one cluster). It works when the amplicons are **different sequences**; if two
products share a long identical stretch, give a reference instead (`REF=amplicons.fasta`). How it works:
[`docs/amplicon_plan.md` §3](docs/amplicon_plan.md) (B2-reffree).

## Contents

| File | What it does |
|---|---|
| `filter_nanopore_reads.sh` | Concatenate per-barcode FASTQs and select reads by length window + mean Q (uses `seqkit seq`, the Nanopore error-probability mean-Q). |
| `estimate_length_peak.sh` | **Data-driven** read-length peak finder: estimates the full-length plasmid read-length mode and derives a length window (no hand-picked threshold), then filters reads for assembly. Feeds `clone_validate.sh`. |
| `clone_validate.sh` | Wrapper: select reads → reshape to the `barcodeNN/` layout `--fastq` expects → `nextflow run … -r v1.8.4`. **Defaults to canu**; `auto` mode does per-sample data-driven sizing (peak → window + `approx_size` via a generated sample sheet). `approx_size` guard; extra flags via `EXTRA_NF_ARGS`. |
| `amplicon_validate.sh` + `amplicon_annotate/` | **Amplicon pipeline** (the other half of this repo): run ONT `wf-amplicon` de-novo consensus → pLannotate BLAST **annotation** → one **combined report** + a tidy `deliverables/` bundle. See the [Amplicon quick start](#amplicon-quick-start-with-annotation) and [`docs/amplicon_annotate.md`](docs/amplicon_annotate.md). |
| `docs/getting_started.md` | **Start here if you're new** — a linear beginner walkthrough: get image access, run the shipped example, run your own data, read the HTML report; troubleshooting + glossary. |
| `.devcontainer/README.md` | **Authoritative** devcontainer guide: runtime image vs Claude sandbox, the containment model, host prereq, build-vs-pull. |
| `docs/sif_cache.md` | **How to pre-stage the 5 workflow images as SIF** (exact SHAs + the Nextflow cache-filename convention) so it runs offline. |
| `docs/assembly_testing.md` | **canu vs flye**: how to select the assembler, params to sweep, why flye fails here, and a ready test matrix. |
| `docs/assembly_findings_2026-06-21.md` | **Which lever decides the assembly** (length-selection vs quality vs assembler) — the controlled factorial, the validated canu-vs-flye mechanism (flye's SIGFPE), the data-driven peak finder, and an inside-vs-outside check. |
| `.devcontainer/` | **Two-artifact container layout** (see `.devcontainer/README.md`): `build/` = publishable lean runtime image → GHCR; `claude-code/` = the firewalled Claude yolo-mode sandbox `FROM` it; top-level `devcontainer.json` = default pipeline use. |
| `example_rawdata/` | A runnable example: `barcode69/` (raw ~765-read concat) + a reference filtered output. |

## Getting started

A thin **pre-filter wrapper** around EPI2ME `wf-clone-validation` (plasmid assembly + QC), packaged as a
**lean, fully-offline container** so the whole pipeline runs airgapped — and, optionally, so Claude Code
runs firewalled inside it. Defaults to the **canu** assembler.

**Pull the published runtime** (no build; needs the one-time host AppArmor profile in *Before you build*):
```bash
docker pull ghcr.io/akihitomamiya-del/plasmid-clone-validation:latest
```
Or **run the scripts directly** on any host with Nextflow + `seqkit` + Docker/Apptainer (3 commands):
```bash
# 1. data-driven read filtering (no hand-picked thresholds) on the shipped example
./estimate_length_peak.sh example_rawdata/barcode69/barcode69.concat.fastq.gz --report-only
# 2. filter + assemble — AUTO sizes each sample from its own read-length peak (canu)
./clone_validate.sh example_rawdata runs/cv auto
# 3. read the result
cat runs/cv/cloneval/sample_status.txt        # -> Completed successfully / 1 contig / 5652 bp
```

### Devcontainer configs (pick one in "Dev Containers: Reopen in Container")

| config | what it gives you | image |
|---|---|---|
| **default** (`.devcontainer/devcontainer.json`) | run the pipeline from the published runtime — no Claude, no firewall | pulls `ghcr.io/akihitomamiya-del/plasmid-clone-validation:latest` |
| **`claude-code`** | the offline **yolo-Claude sandbox** — node + Claude CLI + egress firewall + sudo-lockdown atop the runtime (safe for `--dangerously-skip-permissions`) | builds the thin `claude-code` layer `FROM` the runtime |
| **`build`** | build / iterate the **runtime image** itself | builds `.devcontainer/build/Dockerfile` locally |

Full structure + the containment model: **`.devcontainer/README.md`**.

## Before you build (host prerequisites & secrets)

Building is **optional** — the default path is to **pull** the published runtime (see *Getting started*).
Build locally only to **iterate on the runtime** (`build/`) or **run the Claude sandbox** (`claude-code/`),
on a **host you control** — **not** inside the firewalled sandbox. You need:

- **Docker** (or Podman) + the VS Code "Dev Containers" extension or the `devcontainer` CLI.
- **Open network during the build** — the **runtime** image pulls the base image, seqkit, Apptainer,
  Nextflow, and the 5 workflow SIFs from Docker Hub; the **`claude-code`** image additionally pulls Node +
  the Claude CLI. (The firewall only closes at *runtime*.)
- **`/dev/fuse` on the host** for rootless Apptainer (Linux / Docker Desktop: usually present — verify).
  `runArgs` are **ignored by GitHub Codespaces**, so build locally, not on Codespaces.
- **One-time AppArmor profile (admin/sudoer)** if the host hardens user namespaces
  (`kernel.apparmor_restrict_unprivileged_userns=1`, Ubuntu 23.10+): `sudo bash
  .devcontainer/setup-host-apparmor.sh`. Lets non-root Apptainer create its user namespace **without**
  relaxing any host-wide setting. Rationale/trade-off/revert: `docs/host_userns_prereq.md`.
- **Read access to this private repo** (`git`/`gh` authenticated).
- **A Claude auth token exported in the shell that launches the container** — the devcontainer passes
  it through from `localEnv`, so set one *before* opening/building:
  ```bash
  export CLAUDE_CODE_OAUTH_TOKEN=...     # or: export ANTHROPIC_API_KEY=...
  ```
  Interactive `claude /login` won't work at runtime (the firewall blocks `claude.ai`), so inject a token.

## Sharing the image

The runtime image is published to GHCR. **A GHCR package's visibility is set separately from the
repository**, so giving someone repo access does *not* let them pull the image. To let a collaborator
(e.g. a PI) run the pipeline, pick one — **making the package public is _not_ required**:

- **Make the package public** (lowest friction) — they `docker pull` with no login. The repo can stay
  private, and the image bakes **no sequencing data** (only public tools, ONT's public workflow SIFs,
  and these wrapper scripts), so this does *not* expose `example_rawdata/`. Flip it in the web UI:
  *your profile → Packages → `plasmid-clone-validation` → Package settings → Danger Zone → Change
  visibility → Public* (UI only — there is no REST/CLI to change package visibility).
- **Keep it private, grant access** — *Package settings → Manage access → Invite* the collaborator
  (or set visibility to **internal** if you share a GitHub org). They then authenticate with a token
  that has `read:packages` (`docker login ghcr.io -u <user>`) and pull.
- **Let them build it** — no GHCR at all: they build from this repo on a host with Docker + `/dev/fuse`
  (see [`.devcontainer/README.md`](.devcontainer/README.md)).

Whether the **repo and the example reads** become public is a *separate* decision from the image.

## Quickstart

```bash
# 1. Filter only (works anywhere seqkit is installed). Runs on the shipped example:
./filter_nanopore_reads.sh example_rawdata filtered 5000 20 6000
#   -> ~128 reads, matching example_rawdata/barcode69.len5kb-6kb_q20.fastq.gz

# 2. Select reads + run clone-validation (needs Nextflow + Docker/Apptainer). Defaults to canu.
./clone_validate.sh <raw_dir> <out_dir> <approx_size|auto> [min_len] [min_qual] [max_len]
#   PROFILE: 'standard' (Docker host) | 'singularity' (Apptainer; use this in the devcontainer)
PROFILE=standard ./clone_validate.sh example_rawdata runs/cv 5500 5000 20 6000

# 2b. AUTO (recommended) — data-driven per-sample sizing (peak → window + approx_size), canu:
PROFILE=standard ./clone_validate.sh example_rawdata runs/cv_auto auto

# 3. canu is the default assembler; to force flye instead, override via EXTRA_NF_ARGS
#    (expect it to fail on RBK full-length reads — see docs/assembly_findings_2026-06-21.md):
EXTRA_NF_ARGS="--assembly_tool flye" PROFILE=standard \
  ./clone_validate.sh example_rawdata runs/cv_flye 5500 5000 20 6000
```

`<raw_dir>` holds one `barcodeNN/` subdirectory per sample, each with `*.fastq.gz`
(see `example_rawdata/barcode69/`).

**`approx_size` matters:** the workflow re-filters by length around `approx_size`
(0.5–1.5× at fastcat, ≤1.2× at the assembler). Pick it so
`ceil(max_len/1.2) ≤ approx_size ≤ 2×min_len`, ideally ≈ your true construct size.
`clone_validate.sh` enforces this (override with `FORCE=1`).

**Let the data size it for you (AUTO mode)** — pass `auto` as the approx_size and `clone_validate.sh`
runs `estimate_length_peak.sh` on **each barcode**, filters that sample to its own full-length peak
±10% window (+ min Q), and feeds each sample's peak as its `approx_size` via a generated sample sheet
— no hand-picked numbers, and per-sample sizing for mixed runs. **canu is the default assembler.**

```bash
./clone_validate.sh example_rawdata runs/cv_auto auto          # data-driven per-sample sizing + canu
./clone_validate.sh example_rawdata runs/cv_auto auto "" 25    # arg 5 still sets min Q (default 20)
```
On `barcode69` AUTO finds peak≈5623, window 5061–6185 (→ 128 reads). Outputs are named by the sample
sheet **alias** (`sampleNN`). To inspect the peak call standalone:
`./estimate_length_peak.sh example_rawdata/barcode69/barcode69.concat.fastq.gz --report-only`.

## Pipeline

Steps 1–2 are **ours** (`clone_validate.sh`); step 3 is EPI2ME `wf-clone-validation` v1.8.4 on the
filtered input.

```
raw per-barcode FASTQs  (example_rawdata/barcodeNN/*.fastq.gz)
   │
   │  1. OUR pre-filter — select full-length, high-Q reads BEFORE assembly
   ├─ MANUAL  filter_nanopore_reads.sh : fixed window [min_len,max_len] + mean Q ≥ min_qual (seqkit)
   └─ AUTO    estimate_length_peak.sh  : per-barcode yield-weighted histogram → full-length peak →
   │                                     window peak ±10% (+ min Q); each sample's peak = its approx_size
   │  2. reshape into the barcodeNN/ layout `--fastq` expects (AUTO also writes a sample sheet)
   ▼
 wf-clone-validation  (-profile singularity, --assembly_tool canu)
   ├─ fastcat QC          : length window 0.5–1.5×approx_size + min Q
   ├─ checkIfEnoughReads  : per-sample read-count gate
   └─ per sample: rasusa downsample → trycycler subsample ×3 → canu assemble ×3 →
                  deconcatenate → trycycler reconcile → medaka polish → plannotate annotate + report
   ▼
 outputs (<out>/cloneval/): <alias>.final.fasta · sample_status.txt · annotations · HTML report
```

**Why canu is the default:** on RBK full-length plasmid reads (~5.6 kb), flye auto-picks a min-overlap
(~6000 bp) > the reads → zero overlaps → `SIGFPE`. Canu gives 1 contig / 5,652 bp in every condition.
Force flye (expect failure) with `EXTRA_NF_ARGS="--assembly_tool flye"`. Details:
`docs/assembly_findings_2026-06-21.md`.

## Running outside the container (host Docker)

The devcontainer (Apptainer, offline, firewalled — safe for yolo Claude) is the recommended runtime,
but `wf-clone-validation` is plain Nextflow, so you can run it directly on any Docker host with
`-profile standard`. **The assembly is byte-identical either way** — verified: inside-Apptainer,
host-Docker, and the EPI2ME reference all produce the same consensus md5 (`2b78d8db…7538c`). Inside
vs outside is an ergonomics/sandboxing choice, not a correctness one (`docs/assembly_findings_2026-06-21.md` §5).

**Host prerequisites**
- **Docker** running. Nextflow pulls the 5 EPI2ME images on first run (online); pre-stage them per
  `docs/sif_cache.md` to go fully offline.
- **Nextflow 24.10.x** — pinned; 25+ breaks this workflow — on **Java 17–21**.
- **seqkit 2.9+** on `PATH` (the pre-filter / peak-finder step).

```bash
# data-driven window, then filter + assemble with canu on the host (Docker)
read _ PEAK LO HI < <(./estimate_length_peak.sh example_rawdata/barcode69/barcode69.concat.fastq.gz --report-only | tail -1)
EXTRA_NF_ARGS="--assembly_tool canu --assm_coverage 60" PROFILE=standard \
  ./clone_validate.sh example_rawdata runs/cv_canu "$PEAK" "$LO" 20 "$HI"
```
`PROFILE` auto-detects `standard` on a Docker-only host; set it explicitly to be sure. Each workflow
step runs as a Docker container; outputs land in `runs/cv_canu/cloneval/` (`sample_status.txt`,
`barcode69.final.fasta`, annotations, HTML report). Expect `Completed successfully, 5652` / 1 contig.
The only host-side caveat vs. inside the container: work dirs + pulled images land on your host (no
firewall, no offline guarantee) — fine for a quick run on a trusted workstation.

## Repository layout

```
clone_validate.sh          # wrapper: pre-filter → reshape → run wf-clone-validation (MANUAL or AUTO; canu default)
filter_nanopore_reads.sh   # length-window + mean-Q read selection (seqkit), one window for all
estimate_length_peak.sh    # AUTO engine: yield-weighted histogram → full-length peak + window
.devcontainer/
  build/                   # RUNTIME image → GHCR (Java+Nextflow+Apptainer+seqkit+5 baked SIFs+workflow+scripts)
  claude-code/             # yolo SANDBOX FROM the runtime (node+Claude+egress firewall+sudo-lockdown+uid helper)
  devcontainer.json        # default config (pull + run the published runtime)
  pcv-apptainer.aaprofile  # scoped AppArmor profile for rootless Apptainer on userns-hardened hosts
  setup-host-apparmor.sh   # one-time host admin: load that profile
  README.md                # authoritative devcontainer guide
.github/workflows/docker-publish.yml   # CI: build + publish the runtime to GHCR on `git tag v*`
docs/                      # getting_started · sif_cache · host_userns_prereq · decision_log · assembly_testing ·
                           #   assembly_findings_2026-06-21 · verify_devcontainer · archive/
example_rawdata/barcode69/ # runnable example (raw concat) + its pre-filtered output
reference_run_canu/        # EPI2ME canu reference output = correctness target (1 contig, 5,652 bp)
# gitignored: runs/ cloneval/ nf_input/ work/ *.sif *.fastq.gz   (only example_rawdata/** is allowlisted)
```

## Tool provenance

| tool | version | source |
|---|---|---|
| nextflow | 24.10.9 | `get.nextflow.io` (pinned `NXF_VER`) |
| seqkit | 2.9.0 | GitHub release `shenwei356/seqkit` |
| apptainer | 1.3.6 | GitHub release `.deb` `apptainer/apptainer` |
| wf-clone-validation | v1.8.4 | `nextflow pull epi2me-labs/wf-clone-validation` |
| 5 SIFs (cloneval · canu · medaka · plannotate · wf-common) | SHAs from the workflow `base.config` | Docker Hub `ontresearch/*` |
| node | 20.x | nodesource *(claude-code layer only)* |
| Claude Code CLI | `latest` *(intentionally unpinned)* | npm `@anthropic-ai/claude-code` *(claude-code layer only)* |
| base image | ubuntu-22.04 | `mcr.microsoft.com/devcontainers/base` |

## Requirements

- **Filtering:** `seqkit` (v2.9+).
- **Clone validation:** Nextflow (Java 17+) and a container runtime — Docker
  (`-profile standard`) or Apptainer/Singularity (`-profile singularity`). The `.devcontainer/`
  provides a firewalled Apptainer setup; see `.devcontainer/README.md` + `docs/sif_cache.md`.

## Status

Built and validated. Filtering + wrapper are tested; the container is split into a lean, fully-offline
**runtime image** (`.devcontainer/build/`, ~5.3 GB, published to GHCR) and a **Claude yolo-mode sandbox**
layered on top (`.devcontainer/claude-code/`). Validated end-to-end on a uid-1001 host: byte-identical
assembly (`Completed successfully / 5652` / 1 contig, md5 `2b78d8db…7538c`), firewall up + sudo-lockdown
enforced. GHCR publish is wired via `.github/workflows/docker-publish.yml` (on `git tag v*`).

## Citation

This tooling is a thin wrapper around Oxford Nanopore's **`wf-clone-validation`** — that workflow does
the assembly and QC. If you use it in your analysis, please cite the workflow and the **nf-core
framework** (the citation the workflow itself requests at runtime):

- **wf-clone-validation** — EPI2ME Labs, Oxford Nanopore Technologies.
  <https://github.com/epi2me-labs/wf-clone-validation> (this repo pins **v1.8.4**).
- **The nf-core framework** — Ewels PA, Peltzer A, Fillinger S, *et al.* "The nf-core framework for
  community-curated bioinformatics pipelines." *Nat Biotechnol* **38**, 276–278 (2020).
  <https://doi.org/10.1038/s41587-020-0439-x>

The workflow bundles several tools that carry their own citations — notably **canu** (assembly),
**medaka** (consensus polishing) and **plannotate** (annotation); the pre-filter / peak-finder here use
**seqkit**. Cite the relevant ones when publishing.
