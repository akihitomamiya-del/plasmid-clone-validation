# Test the amplicon runtime image (build + run from OUTSIDE the sandbox)

How to build the wf-amplicon–enabled runtime image and confirm it runs the **de-novo amplicon** pipeline
offline. Run everything here on a **networked host with Docker + `/dev/fuse`** — the firewalled
Claude-Code sandbox cannot do this (Docker Hub is blocked, so the wf-amplicon SIF can't be pulled there).

Companion docs: design/rationale in [`amplicon_plan.md`](amplicon_plan.md); the analogous
clone-validation checks in [`verify_devcontainer.md`](verify_devcontainer.md); host AppArmor setup in
[`host_userns_prereq.md`](host_userns_prereq.md).

> **Scope of this test — read first.**
> - ✅ **In the image now:** EPI2ME **wf-amplicon v1.2.2** baked as one new SIF
>   (`ontresearch-wf-amplicon-sha0ba6…img`) + the pulled workflow code, plus the wrapper
>   `amplicon_validate.sh`. medaka + wf-common are **reused** from the clone-validation set (same SHAs).
> - ✅ **What this verifies:** the image builds, the wf-amplicon SIF + code are baked, rootless Apptainer
>   runs them, the medaka polishing model is bundled, and a de-novo run produces a **per-amplicon
>   consensus + wf-amplicon's QC report — fully offline**.
> - ✅ **Now also in the image (built 2026-06-24):** the plannotate **`--linear` annotation** (Stage 3), the
>   annotation HTML report (Stage 4, `amplicon-annotation-report.html`), and the **combined report** (Stage 5,
>   `amplicon-report-with-annotation.html` = wf-amplicon report + annotation). These run offline via
>   `apptainer exec` post-steps after the de-novo run; `amplicon_validate.sh` invokes them automatically. See
>   [`amplicon_annotate.md`](amplicon_annotate.md). (This §-by-§ guide still focuses on the de-novo consensus;
>   the annotation is exercised end-to-end by just running the full wrapper in §4.)
> - 🔵 **Mode B (multiplex / multiple amplicons per barcode)** is an off-by-default `REF=` hook only — no
>   data of that type yet; §5 just confirms the guard, it is not a functional test.

Pass criteria are summarized at the bottom.

---

## 0. Prerequisites (host)

- **Docker** + network access to Docker Hub (build-time SIF pull) + **`/dev/fuse`** (Apptainer mounts SIFs).
- **One-time AppArmor profile** (Ubuntu 23.10+/userns-hardened hosts): `sudo bash .devcontainer/setup-host-apparmor.sh`
  (loads `pcv-apptainer`; without it the container errors *"apparmor profile pcv-apptainer not found"*).
- **Amplicon reads** in the `barcodeNN/` layout the wrapper expects:
  ```
  amplicon_raw/
    barcode01/   *.fastq.gz      # one amplicon per barcode (Mode A)
    barcode02/   *.fastq.gz
  ```
  **The amplicon example fixture is currently being replaced.** It lives under `examples/amplicon/` as a
  self-contained dir (`barcodeNN/` reads + its committed EPI2ME reference run, the correctness target — the
  amplicon analogue of `examples/plasmid/reference_run_canu/`). The previous fixture (a single ~3,249 bp
  amplicon) was **removed** pending a new, non-sensitive dataset; see `examples/amplicon/README.md`. Until it
  lands, supply your own data: drop a `barcodeNN/*.fastq.gz` dir anywhere (subdir names **must** match
  `barcodeNN`, ≥2 digits) and point the wrapper at its parent; or run a data-free smoke test with
  wf-amplicon's bundled `test_data/` de-novo demo on the host. When the new fixture lands at
  `examples/amplicon/<name>_example/`, point the wrapper there — it picks up the `barcodeNN/` reads dir and
  **warns-and-skips** the sibling `wf-amplicon_*/` run dir (not `barcodeNN`).

The four run-time security args used throughout mirror `.devcontainer/build/devcontainer.json` (the
validated rootless-Apptainer recipe). Export them once to keep commands short:
```bash
RUNARGS=(--security-opt seccomp=unconfined --security-opt apparmor=pcv-apptainer \
         --security-opt systempaths=unconfined --device /dev/fuse)
IMG=pcv-runtime:amplicon
```

---

## 1. Build the image

From the repo root (build context = repo root, per `build/devcontainer.json`):
```bash
docker build -f .devcontainer/build/Dockerfile -t "$IMG" .
```
**Watch the log for:**
- the wf-amplicon SIF pull → a line like `ontresearch-wf-amplicon-sha0ba67476938520e6f132759780d0a0e902925c59.img` in the `ls -la /opt/sif-cache` dump (5 clone-val SIFs **+** this one = 6 total);
- `nextflow pull epi2me-labs/wf-amplicon` succeeding.

**Pass:** build completes; final image ≈ 6.5–7 GB (≈ +1.5 GB over the clone-validation-only image).

> **Sizing caveat:** read the size with `docker inspect -f '{{.Size}}' "$IMG"` (bytes; ÷1e9 ≈ GB), **not**
> `docker images`. With the containerd/BuildKit image store, `docker images` can report ~2× (e.g. **13 GB**
> for a **6.1 GB** image) because it counts shared/attestation layers differently; `docker inspect` is the
> true layer total.

> Same host prereqs as the existing runtime build — nothing new was added that needs a capability the
> current build doesn't already use (only an extra `apptainer pull`; the build does **not** `apptainer
> exec`). If `docker pull`/`apptainer pull` can't reach Docker Hub, you're not on a networked host.

## 2. Confirm the workflow is baked (no fuse needed)

```bash
docker run --rm "$IMG" bash -lc \
  'echo "== SIF cache =="; ls -1 /opt/sif-cache; \
   echo "== workflows =="; ls /opt/nextflow/assets/epi2me-labs'
```
**Pass:** `/opt/sif-cache` lists `ontresearch-wf-amplicon-sha0ba6…img` (alongside the 5 clone-val SIFs),
and `assets/epi2me-labs` lists **both** `wf-amplicon` and `wf-clone-validation`.

## 3. Rootless Apptainer + the medaka model (needs fuse + AppArmor)

```bash
# (a) rootless Apptainer can mount the new SIF as the non-root user
docker run --rm "${RUNARGS[@]}" "$IMG" bash -lc \
  'id -un; apptainer exec /opt/sif-cache/ontresearch-wf-amplicon-*.img echo "rootless apptainer OK"'

# (b) the medaka polishing model is bundled (THE offline gate). de-novo polish runs
#     `medaka inference --model <basecaller_cfg>:consensus`, auto-detected from your reads.
docker run --rm "${RUNARGS[@]}" "$IMG" bash -lc \
  'apptainer exec "$(ls /opt/sif-cache/ontresearch-medaka-*.img)" medaka tools list_models' \
  | tr ',' '\n' | grep -iE 'r10\.?4\.?1.*sup' || echo "NO r10.4.1 sup model listed — see §6"
```
**Pass:** (a) prints `vscode` then `rootless apptainer OK`; (b) lists an **R10.4.1 … sup** model. Note
`medaka tools list_models` prints the **undotted internal** name (e.g. `r1041_e82_400bps_sup_v5.0.0` /
`…v5.2.0`), *not* the dotted MinKNOW form `dna_r10.4.1_e8.2_400bps_sup@v5.*` — both denote the same model,
which is why the grep above uses `r10\.?4\.?1` (a literal `r10.4.1` pattern would false-negative). If the
model is genuinely absent → §6 (pin one).

## 4. End-to-end: de-novo amplicon run, offline

Needs an amplicon example dir (one or more `barcodeNN/*.fastq.gz` under a parent). The shipped fixture is
currently being replaced (§0) — use `examples/amplicon/<name>_example` once it lands, or your own data dir.
`amplicon_validate.sh` is on `PATH`. Pass `300 15` (`min_read_length 300`, `min_read_qual 15`, de-novo):
```bash
mkdir -p amp_out && chmod 777 amp_out      # /out must be writable by the container's uid 1000 (vscode);
                                           # the chmod is only needed if your host account isn't uid 1000
docker run --rm "${RUNARGS[@]}" \
  -v "$PWD/examples/amplicon/<name>_example":/data:ro \   # <-- your amplicon example dir
  -v "$PWD/amp_out":/out \
  "$IMG" \
  amplicon_validate.sh /data /out none 300 15
```
(Substitute any `barcodeNN/` parent dir for `/data` to test other amplicons.)

> **Writable out dir:** the bind-mounted `/out` must be writable by the container user (**uid 1000**). If
> your host account isn't uid 1000, the `chmod 777` above (it's throwaway test scratch) is the simplest fix —
> otherwise the wrapper aborts at `mkdir $OUT/nf_input`. The wrapper `cd`s into `$OUT` before launching
> Nextflow, so `work/`, `.nextflow/` and `.nextflow.log` land inside it — no `-w`/`--workdir` needed.

**Expect:** the banner `== amplicon_validate == … mode=de-novo … profile=singularity`, then
`Prepared 1 sample(s)` — the bundled `wf-amplicon_*/` reference-run dir is **silently skipped** (it has no
top-level `*.fastq.gz`; the `not in barcodeNN format` WARNING fires only for a non-`barcodeNN` dir that
*does* contain reads). Nextflow then runs each barcode through filter → draft (miniasm/spoa) → medaka polish, and
finishes with its normal completion summary. Outputs:
- `/out/amplicon/wf-amplicon-report.html` — read/consensus QC report
- `/out/amplicon/all-consensus-seqs.fasta` (+ `.fai`) — all per-amplicon consensuses
- `/out/amplicon/<alias>/consensus/consensus.fastq` — per-sample consensus

**Correctness target:** each barcode yields a **single consensus ~the length of its amplicon**. When the
shipped fixture is restored (it ships its own `wf-amplicon_*/output/` reference run), diff against its `.fai`:
```bash
seqkit stats amp_out/amplicon/all-consensus-seqs.fasta                                  # produced now
cat examples/amplicon/<name>_example/wf-amplicon_*/output/all-consensus-seqs.fasta.fai  # the target length(s)
```
The **length** should match. The exact bases may differ by a few if your basecaller model/params differ from
the reference (300/Q15, de-novo) — expected, like the plasmid AUTO-vs-matched-params caveat.

**Prove it's airgapped (the definitive offline test):** rerun with the network removed — if the medaka
model is bundled, it still completes; if it tries to download a model, this is where it fails (→ §6).
```bash
mkdir -p amp_out_offline && chmod 777 amp_out_offline     # writable by uid 1000 (see the §4 note above)
docker run --rm --network none "${RUNARGS[@]}" \
  -v "$PWD/examples/amplicon/<name>_example":/data:ro -v "$PWD/amp_out_offline":/out \
  "$IMG" amplicon_validate.sh /data /out none 300 15
```
**Pass:** a consensus FASTA is produced for each barcode that had enough reads, the report renders, and
the `--network none` run completes without a model-download error.

## 5. Options & guards (quick, optional)

```bash
# Pin the medaka model (fallback if §3b didn't show your exact model)
OVERRIDE_BASECALLER_CFG=dna_r10.4.1_e8.2_400bps_sup@v5.0.0   # -> adds --override_basecaller_cfg
docker run --rm "${RUNARGS[@]}" -e OVERRIDE_BASECALLER_CFG \
  -v …:/data:ro -v …:/out "$IMG" amplicon_validate.sh /data /out none

# Optional pre-filter (operator-chosen window; e.g. trim concatemers): mode 'window' min max
#   amplicon_validate.sh /data /out window 800 12 3500
# Mode B (multiplex) is FUTURE: REF=<multi.fasta> only prints a warning + appends --reference.
```
**Pass (guards):** with `OVERRIDE_BASECALLER_CFG` set, the printed `nextflow … ` command contains
`--override_basecaller_cfg …`; `REF=` prints the `FUTURE, untested` warning; a `--reference` placed in
`EXTRA_NF_ARGS` is rejected with a non-zero exit.

---

## 6. Troubleshooting / amplicon-specific gotchas

| Symptom | Cause / fix |
|---|---|
| Container won't start: *apparmor profile pcv-apptainer not found* | Load it on the host: `sudo bash .devcontainer/setup-host-apparmor.sh` ([`host_userns_prereq.md`](host_userns_prereq.md)). |
| `apptainer exec` fails to mount the SIF | Missing `--device /dev/fuse` or the AppArmor/`systempaths` args — use the full `RUNARGS` set (§0). |
| medaka tries to **download** a model / `--network none` run fails at polishing | The auto-selected model's weights aren't in the SIF. Confirm with §3b; pin a **bundled** model via `OVERRIDE_BASECALLER_CFG` (§5). This is the one runtime-network dependency. |
| A barcode produced **no** consensus | wf-amplicon drops samples with `< min_n_reads` (40 reads after trimming), and a consensus can fail QC (`mean_depth < 30` or `primary_ratio < 0.7`). Low-yield/low-quality barcodes legitimately yield nothing — outputs are optional. |
| A barcode silently skipped | Subdir isn't named `barcodeNN` (≥2 digits) — the wrapper warns and skips. |
| Auto model selection misses (run wants a model despite §3b looking fine) | Don't strip FASTQ headers before the run — they carry the basecaller id. Mode A defaults to `none` (concat only, headers preserved); if you used a pre-filter, prefer pinning with `OVERRIDE_BASECALLER_CFG`. |
| Offline run can't find the workflow/containers on a *fresh* image | The Nextflow SIF cache **filename** must match what Nextflow expects (`ontresearch-<img>-<sha>.img`). The build bakes the right name; if you bumped `WF_AMPLICON_VERSION`, confirm the new SHA/filename from one online run (cf. [`sif_cache.md`](sif_cache.md)). |
| Amplicons > 5 kb give no de-novo consensus | The spoa fallback aborts above 5,000 bp. Your stated range is 1–3 kb, so this shouldn't occur; if it does, the read length is the cause. |

---

## 7. Record the result (paste back when reporting)

```
amplicon image test — <date>, host <name>
  image tag / built:        pcv-runtime:amplicon  /  <ok? size?>
  §2 baked:                 wf-amplicon SIF present? <y/n>   sha0ba6… ? <y/n>   assets has wf-amplicon? <y/n>
  §3a rootless apptainer:   <"rootless apptainer OK"? y/n>
  §3b medaka sup model:     <model string(s) listed, e.g. dna_r10.4.1_e8.2_400bps_sup@v5.0.0 ; or "none">
  §4 de-novo run:           <completed? y/n>   barcodes in / consensus out: <n/n>
       consensus lengths:   <bp per barcode>   (each ≈ its amplicon length)
  §4 offline (--network none): <completed? y/n>   (proves medaka model bundled)
  §5 guards:                override injected <y/n> · REF warns <y/n> · --reference rejected <y/n>
  notes / errors:           <…>
```

---

## Pass criteria

| Check | Pass |
|---|---|
| Build (§1) | `docker build` completes; 6 SIFs in `/opt/sif-cache`; wf-amplicon code pulled |
| Baked (§2) | `ontresearch-wf-amplicon-sha0ba6…img` present; `wf-amplicon` + `wf-clone-validation` in assets |
| Rootless Apptainer (§3a) | `apptainer exec …wf-amplicon….img` prints `rootless apptainer OK` as `vscode` |
| Medaka model (§3b) | an `r10.4.1 … sup` model is listed (matching your basecaller) |
| De-novo run (§4) | run completes; per-barcode consensus in `all-consensus-seqs.fasta`; QC report renders (each consensus ≈ its amplicon length) |
| Offline (§4) | the `--network none` rerun completes (no model download) |
| Guards (§5) | `OVERRIDE_BASECALLER_CFG` injected; `REF=` warns; smuggled `--reference` rejected |

The annotation, the annotation report, and the combined report (`amplicon-report-with-annotation.html`) are
**now built and in scope** (Phase 0–2; run automatically by `amplicon_validate.sh` §4 and described in
[`amplicon_annotate.md`](amplicon_annotate.md)). Mode B (reference/multiplex) in
[`amplicon_plan.md`](amplicon_plan.md) remains future.
