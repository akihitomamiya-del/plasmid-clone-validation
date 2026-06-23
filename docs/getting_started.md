# Getting started — a beginner's walkthrough

**Audience:** someone new to this repo who wants to *use* it to validate a plasmid from Oxford
Nanopore reads. No prior knowledge of Nextflow, containers, or this codebase assumed. If you just want
the terse reference, see the top-level [`README.md`](../README.md); this page is the slow, linear version.

---

## 1. What does this actually do?

You have Oxford Nanopore sequencing reads of a **plasmid** (a small circular DNA construct), typically
one folder of `*.fastq.gz` files per barcode. This tool:

1. **Pre-filters** the reads — keeps only the full-length, high-quality ones *before* assembly (this is
   the part we add; it noticeably improves the result).
2. Runs Oxford Nanopore's official **`wf-clone-validation`** workflow on the filtered reads to
   **assemble** the plasmid and **QC/annotate** it.
3. Gives you, per sample: a consensus **`.final.fasta`** (the assembled plasmid sequence), a
   plain-text **status**, an annotation file, and an **interactive HTML report** — the *same* report
   the EPI2ME Desktop GUI produces (this is CLI-native; the GUI is just a front-end over the same
   workflow).

A successful run of the bundled example produces **1 contig, 5,652 bp, "Completed successfully."**

> **Plain-language glossary** is at the [bottom of this page](#glossary) — plasmid, contig, Q-score,
> `approx_size`, SIF, Apptainer, barcode, etc.

---

## 2. Pick how you'll run it

| You have… | Use this path | Section |
|---|---|---|
| VS Code + Docker, and you want the easy button | **Dev Container** (recommended) | [§4](#4-easy-path-vs-code-dev-container) |
| A host that already has Nextflow + `seqkit` + Docker/Apptainer | **run the scripts directly** | [§5](#5-scripts-directly-on-your-own-host) |
| Neither, and you don't want to install anything | get the **prebuilt image** first | [§3](#3-getting-the-prebuilt-image-the-access-question) |

Either way you need the **container image** (it bundles Nextflow, Apptainer, seqkit, and the 5 workflow
images so the pipeline runs **offline**). The next section is about getting access to it.

---

## 3. Getting the prebuilt image (the access question)

The image is published to **GitHub's Container Registry (GHCR)** at:

```
ghcr.io/akihitomamiya-del/plasmid-clone-validation:latest
```

**Important:** on GitHub, an image's visibility is set **separately from the repository**. Being able
to see this (private) repo does **not** automatically let you download the image. One of these must be
true:

1. **The image package is public** → anyone can pull it, no login:
   ```bash
   docker pull ghcr.io/akihitomamiya-del/plasmid-clone-validation:latest
   ```
2. **You were granted read access to the private package** → log in first with a GitHub token that has
   the `read:packages` scope, then pull:
   ```bash
   echo "$GITHUB_TOKEN" | docker login ghcr.io -u YOUR_GITHUB_USERNAME --password-stdin
   docker pull ghcr.io/akihitomamiya-del/plasmid-clone-validation:latest
   ```
3. **You build it yourself** instead of pulling — see [§5](#5-scripts-directly-on-your-own-host) /
   [`../.devcontainer/README.md`](../.devcontainer/README.md). Needs Docker + `/dev/fuse` + open network
   during the build; no GHCR access required.

If `docker pull` fails with `denied`/`unauthorized`, the package isn't public and you don't yet have
access — ask the repo owner to make the package public or grant you access (see the owner note in
[`README.md`](../README.md#sharing-the-image)).

---

## 4. Easy path: VS Code Dev Container

1. **One-time host setup (admin, only on Linux hosts that harden user namespaces — Ubuntu 23.10+):**
   ```bash
   sudo bash .devcontainer/setup-host-apparmor.sh
   ```
   This loads a scoped AppArmor profile so rootless Apptainer works **without** weakening anything
   host-wide. Skip it and the container will refuse to start with *"apparmor profile pcv-apptainer not
   found."* Details: [`host_userns_prereq.md`](host_userns_prereq.md).

2. Open the repo in **VS Code** → command palette → **"Dev Containers: Reopen in Container"** → pick
   **the default** config (`plasmid-clone-validation`). This *pulls* the published image — no build, no
   Claude, no firewall. (The other two configs are for Claude-assisted work and for rebuilding the
   image; you don't need them just to run the pipeline.)

3. Once inside, jump to [§6 — run the example](#6-run-the-bundled-example-prove-it-works).

> The image already has the wrapper scripts on `PATH` and the offline cache wired up, so the commands
> in §6 work as-is.

---

## 5. Scripts directly on your own host

If your machine already has the tools, you can skip containers entirely:

- **Nextflow 24.10.x** (pinned — 25+ breaks this workflow) on **Java 17–21**
- **`seqkit` 2.9+** on `PATH`
- **Docker** (`-profile standard`) **or** Apptainer (`-profile singularity`)

```bash
git clone <this repo>            # you already have read access
cd plasmid-clone-validation
./clone_validate.sh example_rawdata runs/cv auto
```

`PROFILE` auto-detects (`singularity` if only Apptainer is present, else `standard`). On first run
Nextflow downloads the 5 workflow images (needs network once); to go fully offline, pre-stage them per
[`sif_cache.md`](sif_cache.md). More detail: README → *"Running outside the container."*

---

## 6. Run the bundled example (prove it works)

This repo **ships a real example** (`example_rawdata/barcode69/`), so you can confirm everything works
before touching your own data. The recommended command lets the data size itself (**AUTO mode**):

```bash
./clone_validate.sh example_rawdata runs/cv auto
```

Expected (takes ~2–3 min):

```
$ cat runs/cv/cloneval/sample_status.txt
Sample,Assembly completed / failed reason,Length
sample69,Completed successfully,5652
```

That's **1 contig, 5,652 bp, success** — the correct answer for this example. If you got that, the
whole stack works. (AUTO names outputs by sample-sheet *alias*, so the file is `sample69.*`, not
`barcode69.*`.)

Want byte-for-byte proof against the reference? Use **matched parameters** and compare md5:
```bash
./clone_validate.sh example_rawdata runs/cv_ref 5000 5000 20 6000
md5sum <(grep -v '^>' runs/cv_ref/cloneval/barcode69.final.fasta | tr -d '\n' | tr a-z A-Z) \
       <(grep -v '^>' reference_run_canu/output/barcode69.final.fasta | tr -d '\n' | tr a-z A-Z)
# both → 2b78d8db3aacbc918d3e031d8ee7538c
```
(AUTO and matched-params give the *same length* but slightly different consensus — both valid. The
md5 check only matches with the matched-params command above. See
[`verify_rebuild.md`](verify_rebuild.md).)

---

## 7. Run it on YOUR data

1. **Lay your reads out** as one `barcodeNN/` folder per sample, each holding that sample's
   `*.fastq.gz` (any number of files — they're concatenated for you):
   ```
   my_run/
     barcode01/  *.fastq.gz
     barcode02/  *.fastq.gz
     …
   ```
   The folder names **must** be `barcode` + at least two digits (e.g. `barcode01`). Outputs will be
   named `sample01`, `sample02`, …

2. **Run AUTO mode** (no hand-picked numbers — each sample is sized from its own read-length peak):
   ```bash
   ./clone_validate.sh my_run runs/my_run auto
   ```
   To change the minimum quality (default Q20), pass it as the 5th argument:
   ```bash
   ./clone_validate.sh my_run runs/my_run auto "" 25
   ```

3. **Check each sample** in `runs/my_run/cloneval/sample_status.txt`, then read the report (next
   section).

> **Prefer to set the size yourself?** Use *manual* mode:
> `./clone_validate.sh my_run runs/my_run <approx_size> <min_len> <min_qual> <max_len>`, e.g.
> `… 5000 5000 20 6000`. `approx_size` ≈ your expected plasmid size in bp. The wrapper guards a sane
> range (see [§8](#8-the-knobs-worth-knowing)).

---

## 8. Reading the output

Everything lands in `<out_dir>/cloneval/`. The files you'll care about:

| File | What it is |
|---|---|
| **`wf-clone-validation-report.html`** | **Open this in a web browser.** The full interactive report — sample status, read & assembly QC, inserts, annotation. *Identical to the EPI2ME Desktop GUI report.* |
| `sample_status.txt` | One line per sample: `Completed successfully` (+ assembled length) or the failure reason. |
| `<alias>.final.fasta` | The assembled plasmid consensus sequence. |
| `<alias>.annotations.gbk` / `.bed` | Feature annotation (plannotate) — genes, origins, resistance markers, etc. |
| `<alias>.assembly_stats.tsv` | Length / coverage stats. |
| `plannotate.json`, `feature_table.txt` | Machine-readable annotation. |

You don't need EPI2ME Desktop installed — the HTML report is self-contained; just double-click it.

---

## 9. The knobs worth knowing

- **AUTO vs manual sizing.** AUTO (`auto`) finds each sample's full-length read peak and sizes from it
  — best default. Manual lets you pin a length window + `approx_size` yourself.
- **`approx_size`.** Roughly your plasmid's true size in bp. It matters because the workflow *re-clips*
  reads around it (0.5–1.5× early, ≤1.2× at the assembler). If you set it badly the wrapper **refuses**
  and tells you the safe range (`ceil(max_len/1.2) ≤ approx_size ≤ 2×min_len`); override with `FORCE=1`
  if you really mean it. AUTO is always in range.
- **Minimum quality (Q).** Default Q20 (mean read quality; the same metric MinKNOW/Dorado report).
  5th positional argument.
- **Assembler = canu (default).** Validated as the robust choice for full-length plasmid reads. You can
  force flye with `EXTRA_NF_ARGS="--assembly_tool flye"`, but **expect it to fail** on this kind of data
  (it auto-picks a min-overlap larger than the reads → crashes). Why:
  [`assembly_findings_2026-06-21.md`](assembly_findings_2026-06-21.md).

---

## 10. Troubleshooting

| Symptom | Likely cause → fix |
|---|---|
| Container won't start: *"apparmor profile pcv-apptainer not found"* | Host setup not done → run `sudo bash .devcontainer/setup-host-apparmor.sh` once ([host_userns_prereq.md](host_userns_prereq.md)). |
| `docker pull …` → `denied` / `unauthorized` | The image package isn't public / you lack access → see [§3](#3-getting-the-prebuilt-image-the-access-question). |
| `ERROR: raw dir not found` | First argument must be the folder that *contains* the `barcodeNN/` subfolders, not a barcode folder itself. |
| `WARNING: subdir '…' is not in barcodeNN format … skipping` | Rename sample folders to `barcode` + ≥2 digits (e.g. `barcode01`). |
| `Refusing to continue` (approx_size) | Your `approx_size` would let the workflow re-clip your window → use the printed safe range, or `auto`, or `FORCE=1`. |
| `0` reads after filtering | Your length window / Q is too strict for this data → loosen `min_len`/`max_len`/`min_qual`, or use `auto`. |
| Sample shows `Failed to assemble using Flye` | You forced flye; switch back to the canu default (drop `--assembly_tool flye`). |
| Nextflow tries to download images and you're offline | Pre-stage the SIFs per [`sif_cache.md`](sif_cache.md), or do one online run first. |

---

## 11. Where to go next

- [`README.md`](../README.md) — concise reference (all flags, pipeline diagram, tool versions).
- [`../.devcontainer/README.md`](../.devcontainer/README.md) — authoritative container guide (runtime
  image vs Claude sandbox, containment model, build vs pull).
- [`verify_rebuild.md`](verify_rebuild.md) — the full self-check (containment + reproduce the reference).
- [`assembly_findings_2026-06-21.md`](assembly_findings_2026-06-21.md) — why canu, why flye fails, the
  data-driven peak finder.
- [`sif_cache.md`](sif_cache.md) — pre-stage the workflow images for fully-offline runs.

---

## Glossary

| Term | Plain meaning |
|---|---|
| **Plasmid** | A small, usually circular piece of DNA — what you're sequencing and validating. |
| **Read** | One sequenced DNA fragment from the Nanopore device. |
| **Barcode** | A tag that groups reads by sample; here, one `barcodeNN/` folder per sample. |
| **RBK** | Rapid Barcoding Kit — a Nanopore library prep that yields full-length plasmid reads. |
| **Assembly / contig** | Reconstructing the plasmid sequence from many reads; a *contig* is one contiguous assembled sequence. A clean plasmid = **1 contig**. |
| **Q-score** | A read's mean quality (higher = fewer errors). Q20 ≈ 99% accuracy. |
| **`approx_size`** | The expected plasmid size in bp; the workflow uses it to bound read lengths. |
| **Consensus / polishing** | Combining many reads (medaka) into one accurate final sequence. |
| **Annotation** | Labeling features on the plasmid (genes, origins, resistance) — done by plannotate. |
| **Nextflow** | The workflow engine that runs the assembly/QC steps. |
| **Apptainer / Singularity** | A container runtime that runs each step in isolation, rootless. |
| **SIF** | A single-file container image Apptainer uses; we pre-bake 5 of them so it runs offline. |
| **GHCR** | GitHub Container Registry — where the prebuilt image is hosted. |
