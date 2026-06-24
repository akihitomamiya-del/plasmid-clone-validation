# De-novo amplicon + annotation + visualization — implementation plan

**Status:** Phase 0–2 **BUILT + host-validated** (2026-06-24) — de-novo consensus + pLannotate `--linear` BLAST
annotation + combined HTML report all run offline; see [`amplicon_annotate.md`](amplicon_annotate.md). The
combined report (Stage 5) is delivered by **splicing** the annotation into the finished wf-amplicon report
(`merge_report.py`), **not** by the re-render in §8d below — see `decision_log.md` (2026-06-24); §8d is kept
as the rejected alternative. Phase 4+ (Mode B / reference) deferred. **Created:** 2026-06-23.
**Target workflow:** EPI2ME `wf-amplicon` **v1.2.2**.

A living roadmap for adding a second pipeline to this repo: take Oxford Nanopore **amplicon** reads,
build a **de-novo consensus** (no reference), **annotate** it with plannotate-style BLAST feature
detection, and render **one combined HTML report** with a linear feature map — mirroring how
`clone_validate.sh` wraps `wf-clone-validation`.

> This doc is the place to expand the design. Once built and validated on a host, archive the executed
> parts under `docs/archive/` (the `setup_and_plan.md` precedent) and keep the how-to in a `docs/amplicon_validate.md`.

---

## 1. What the PI asked for, and how it maps to reality

> "a feature of amplicon workflow + plannotate-type blast + annotation + visualization of the assembly"

The request is a **hybrid** that no single ONT workflow delivers:

| Piece | Where it comes from | New work? |
|---|---|---|
| Amplicon workflow (de-novo consensus from reads) | `wf-amplicon` v1.2.2, de-novo mode | **pull + wrap** (1 new SIF) |
| plannotate-type BLAST + annotation | `plannotate` SIF + `run_plannotate.py` (already vendored from clone-val) | **reuse + small patch** |
| Visualization of the assembly (combined report) | clone-val's `ezcharts`/bokeh report engine (already baked) + the plannotate linear map | **new `combined_report.py`** |

**Key fact (verified from source):** `wf-amplicon` de-novo mode produces a consensus + read/coverage QC
+ its own QC-only HTML report. It contains **no plannotate, no feature annotation, no canu/flye** (agent
scan of `nextflow.config`, `main.nf:384-444`, `modules/local/de-novo.nf`). The annotation and the combined
report are therefore **components we build**, not outputs we merely locate.

## 2. Confirmed scope — two modes (one now, one later)

| | **Mode A — single amplicon / de-novo (NOW)** | **Mode B — multiplex / reference-guided (FUTURE)** |
|---|---|---|
| When | one PCR product per barcode | several distinct-locus amplicons pooled per barcode ("to save barcodes") |
| Reference | none (`reference=null`) | a multi-record FASTA, one record per amplicon |
| wf-amplicon mode | de-novo consensus | variant-calling (reads bin by mapping) — or a custom binning+de-novo hybrid (§3) |
| Status | **building now** | **deferred — no data of this type yet**; documented direction only |

Confirmed parameters:
- **Amplicon size:** ~1–3 kb — comfortably under the 5 kb spoa cap (no truncation). (≤2 kb routes through spoa; larger may use miniasm.)
- **Construct type:** linear PCR products → plannotate in **linear** mode.
- **Deliverable:** **one combined HTML report** (read QC + consensus QC + linear feature map + annotation table; + a variants section in Mode B).
- **Multiplex (Mode B) specifics, confirmed for later:** distinct loci (reads map uniquely → separation reliable); 2–4 amplicons/barcode.
- **Basecaller:** MinKNOW **sup, R10.4.1 E8.2 5 kHz**. Medaka **auto-selects** its polishing model from the basecaller id embedded in the reads — we don't pin it (offline caveat in §8b).

## 3. Mode B (multiplex, single barcode / multiple amplicons)

Pooling **distinct-locus** amplicons per barcode and separating them is feasible (reads from different
products don't overlap/co-map). Three ways to reconstruct each amplicon:

- **B1 — reference-anchored consensus (native).** Same workflow, `--reference amplicons.fasta`
  (multi-record). Reads bin by mapping; each amplicon → `medaka.consensus.fasta` + `medaka.annotated.vcf.gz`.
  ~Zero custom code (just a different invocation). Best when amplicons closely match the reference; large
  indels show up as variants, not as freely-assembled sequence. (`amplicon_validate.sh` `REF=` hook.)
- **B2 — reference-for-binning + de-novo per bin (custom hybrid).** A `minimap2` binning pre-step assigns
  each read to its best-matching amplicon, writes one FASTQ bin per amplicon, then feeds each bin as a
  "sample" to wf-amplicon **de-novo**. Unbiased per-amplicon assembly. Best if amplicons may deviate
  substantially from the reference.
- **B2-reffree — UNGUIDED binning, no reference (PROTOTYPED 2026-06-24).** `amplicon_split.sh`: cluster the
  barcode's reads by **all-vs-all overlap** (`minimap2 -x ava-ont` → union-find connected components — reads
  from different products don't overlap, so they fall into separate clusters), emit one FASTQ per cluster,
  then de-novo each. Wired as `SPLIT=1 amplicon_validate.sh …` (Mode A 'none' filter only). **Validated**
  (2026-06-24) on the committed public example: its two amplicons (~2,156 & ~3,283 bp) mixed into one barcode
  → **0 cross-amplicon overlaps**, 2 clean clusters, both recovered at **100% identity** and annotated.
  **Why it matters:** stock wf-amplicon de-novo keeps only the single highest-depth contig (`trim_and_qc.py`),
  so a mixed barcode otherwise collapses to one product. **Caveat:** distinct-locus only — amplicons sharing a
  stretch longer than `SPLIT_MIN_OVERLAP` merge into one cluster (use B1); short fragments below `min_len` drop.

Each amplicon's consensus then flows through the same Stage 3 (plannotate, linear) + Stages 4–5 (annotation +
combined report) as Mode A, with one sub-section + one `.gbk` per amplicon. The committed example
(`examples/amplicon/raw/`, two distinct amplicons) validates B2-reffree with **public
data**: mixing its two barcodes into one and running `SPLIT=1` yields 2 clean clusters → both consensuses
recovered at **100% identity** (2026-06-24). `amplicon_validate.sh` carries a `REF=` hook (off by default;
prints a FUTURE warning) so the reference path (B1) can be enabled without restructuring.

---

## 4. Architecture (3 stages we add around wf-amplicon)

```
raw reads  (RAW/barcodeNN/*.fastq.gz)
  │
  │  [Stage 1] optional pre-filter (filter_nanopore_reads.sh; DEFAULT OFF) + reshape
  ▼            → NF_IN/barcodeNN/reads.fastq.gz
  │
  │  [Stage 2] nextflow run epi2me-labs/wf-amplicon -r v1.2.2   (DE-NOVO — no --reference)
  ▼            → per-sample consensus.fastq  +  all-consensus-seqs.fasta
  │            → read/consensus QC (fastcat stats, bamstats, per-window depth, qc-summary.tsv)
  │            → wf-amplicon-report.html   ← QC ONLY, no feature annotation
  │
  │  [Stage 3] apptainer exec <plannotate SIF>  run_plannotate.py --linear   (NEW: we add this)
  ▼            → plannotate_report.json (feature dataframe) + feature_table.txt + *.annotations.{bed,gbk}
  │
  │  [Stage 4] apptainer exec <wf-clone-validation SIF>  combined_report.py   (NEW: we write this)
  ▼            merge wf-amplicon QC sections + plannotate LINEAR map + annotation table
               → combined-report.html        ★ the PI's deliverable
```

**Orchestration choice:** Stages 3-4 are driven by the wrapper via `apptainer exec` (post-processing
outside Nextflow), keeping us on the repo's locked "**pre-filter wrapper, not a fork**" path. A
Nextflow-native alternative (Stages 3-4 as Nextflow processes, so the container runtime is profile-handled)
is deferred to Phase 4. Note the bash path assumes **Apptainer** (the offline devcontainer's only runtime);
a Docker-host (`-profile standard`) path would need the docker-run equivalents.

**Why the combined report runs in the wf-clone-validation SIF (not wf-common):** it is the *only* baked
image that simultaneously has ezcharts+bokeh3 (report framework), `plannotate 1.2.0` (the bokeh-3-safe
linear-map renderer), **and** wf-amplicon's report deps (`si_prefix`, `ezc.lineplot`, `choose_palette`,
`Progress`) — all verified present. The plannotate plot is *rebuilt from a dataframe* at report time
(bokeh-2 → JSON → bokeh-3), exactly as clone-val already does, so there's no bokeh major-version clash.

---

## 5. What we already have vs. the delta

Baked SIFs today (`/opt/sif-cache/`): `canu`, `medaka` `shacf833…`, `plannotate` `shae4901…`,
`wf-clone-validation` `sha0ebc91…`, `wf-common` `shafdd79…`.

| Container wf-amplicon v1.2.2 needs | Status | Action |
|---|---|---|
| `ontresearch/wf-common:shafdd79f8e4a6faad77513c36f623693977b92b08e` | **baked, same SHA** ✅ | reuse |
| `ontresearch/medaka:shacf8338462607b17b1d68dbce212cb93daea50bad` | **baked, same SHA** ✅ | reuse |
| `ontresearch/wf-amplicon:sha0ba67476938520e6f132759780d0a0e902925c59` | **NEW** 🆕 | pull (~1.5 GB) |
| `ontresearch/plannotate:shae4901…` (annotation + report SIFs) | **baked** ✅ | reuse |

**Net build delta: one new SIF (~1.5 GB) + `nextflow pull epi2me-labs/wf-amplicon`.** Image grows
~5.3 GB → ~6.5–7.1 GB. canu/plannotate are untouched by wf-amplicon but plannotate is reused by *our* Stage 3-4.

---

## 6. Phased implementation

Build order optimized so each phase is independently runnable. The **final deliverable is the Phase 2
combined report**; Phase 1 is the working skeleton.

### Phase 0 — Build delta (HOST/CI only; cannot be done in the firewalled sandbox)
- **Status 2026-06-23: written in-repo, build pending.** The `.devcontainer/build/Dockerfile` wf-amplicon
  bake block + `amplicon_validate.sh` are committed and syntax/dry-run-checked in the sandbox; the actual
  `docker build` (Docker Hub pull) + the verifications below run on a networked host.
- Add a wf-amplicon SIF-bake block to `.devcontainer/build/Dockerfile` (§8b). **wf-amplicon has no
  `base.config`** — read the SHA from `nextflow.config`, not `base.config`.
- `nextflow pull epi2me-labs/wf-amplicon -r v1.2.2` into `/opt/nextflow`.
- **Validate the medaka model is bundled** (§8b, the one runtime-network risk).
- Capture the exact Nextflow SIF cache filenames from one online run → `docs/amplicon_sif_cache.md`.

### Phase 1 — MVP wrapper + consensus + annotation (working skeleton)
- ✅ `amplicon_validate.sh` (§8e) written: pre-filter(optional)+reshape → `nextflow run wf-amplicon` de-novo → locate `all-consensus-seqs.fasta` (Stages 1–2; runs on a host with the baked image).
- TODO: patch `run_plannotate.py` to add `--linear` (§8c), run Stage 3 → annotation + a **standalone** linear map HTML per sample (bokeh `save(..., INLINE)`).
- Deliverable at end of Phase 1: wf-amplicon's own QC report **+** a separate plannotate map/table (the "separate, linked" shape — an engineering milestone, not the final ask). **Now superseded:** Stage 5 (`merge_report.py`) folds the annotation back into the wf-amplicon report → one combined report (the final ask).

### Phase 2 — Combined HTML report (the PI's deliverable)
- Write `combined_report.py` (§8d): merge wf-amplicon QC sections + the plannotate **linear** section into one `LabsReport`, run in the wf-clone-validation SIF.
- Resolve QC-file harvesting (some wf-amplicon QC inputs — notably `qc-summary.tsv` — are staged internally and may need pulling from the published out_dir or `work/`).
- Deliverable: `combined-report.html`.

### Phase 3 — Hardening & docs
- ⏳ Example amplicon test data + reference run: **pending** under `examples/amplicon/` — the previous
  fixture (the correctness target, analogous to `examples/plasmid/reference_run_canu/`) was removed pending
  replacement; how-to in [`amplicon_testing.md`](amplicon_testing.md) §0/§4.
- TODO: CLAUDE.md / README / `decision_log.md` updates, `docs/amplicon_validate.md`.

### Phase 4 — Mode B (multiplex, reference-guided) — when data exists (directions in §3)
- Enable the `REF=` path: B1 (native `--reference`) and/or B2 (binning + de-novo per bin); decision deferred.
- Per-amplicon report sub-sections (2–4 tabs) + a variants section (B1); a mapping-quality gate to warn on too-similar references.

### Phase 5 — Optional / future
- Convert Stages 3-4 to Nextflow processes for `-profile standard` (Docker) portability.
- Pooling *similar-locus* amplicons in one barcode (UMIs / flanking tags) — mapping alone can't separate those.

---

## 7. Component specs

### 8a. wf-amplicon de-novo internals (Stage 2)

De-novo is **miniasm→racon first, spoa fallback** (not spoa-first):

1. **Shared preprocessing:** fastcat ingress applies `min_read_length=300` / `max_read_length=null` /
   `min_read_qual=10` (`main.nf:508-511`); `subsetReads` drops the longest 5% then keeps the
   `reads_downsampling_size=1500` longest remaining (`subset_reads.py`); `porechop` adapter-trims; samples
   with `< min_n_reads=40` are dropped (`main.nf:333-337`).
2. **Draft (miniasm):** `minimap2 -x ava-ont | miniasm | racon` (one round). Passes only if the contig
   is non-empty and longer than `force_spoa_length_threshold=2000` (`de-novo.nf:42-123`).
3. **Draft fallback (spoa):** for samples miniasm failed/too-short — `run_spoa` (carries the **medaka**
   label, not wf-amplicon). ⚠️ **spoa aborts (no output) if any read > `spoa_max_allowed_read_length=5000`**
   (`run_spoa.py:28-35`) — relevant for amplicons near/over 5 kb.
4. **Polish + QC tail (both routes):** `minimap2 map-ont` reads→draft → `medaka inference … --model
   <cfg>:consensus` → `medaka sequence --qualities` → consensus FASTQ; then `trim_and_qc.py` selects the
   single best contig, trims low-coverage ends, renames the record to the sample alias.
5. **Outputs:** per-sample `{alias}/consensus/consensus.fastq` (FASTQ, optional); top-level
   **`all-consensus-seqs.fasta`** (+`.fai`) — **this multi-record FASTA is our Stage-3 input**. QC lives in
   `qc-summary.tsv`, `bamstats.tsv`, `per-window-depth.tsv.gz`, fastcat stats; user-facing numbers are in
   `wf-amplicon-report.html`.

**Don't look for** `{alias}/consensus/medaka.consensus.fasta` — that's the *variant-calling* consensus,
**not produced in de-novo mode**. `min_coverage` and `medaka_target_depth_per_strand` are **variant-only**
params (don't apply them to de-novo). Containers used (de-novo): `wfamplicon`, `medaka`, `wf_common`.

**De-novo gotchas:** `min_n_reads=40` floor silently drops low-yield samples; the default keep-longest-1500
downsampling can starve short products (docs suggest `--drop_frac_longest_reads 0 --take_longest_remaining_reads false`);
QC rejects a consensus if `mean_depth < 30` or `primary_ratio < 0.7`; a run can legitimately finish with
**zero** consensus files (all outputs are `optional`), so Stage 3 must handle empty/missing FASTA.

### 8b. SIF / build delta (Stage 0)

wf-amplicon has **no `base.config`** (404); SHAs are in `nextflow.config:67-69`. Add before the
`ENV NXF_OFFLINE=true` line in `.devcontainer/build/Dockerfile` (network must still be open):

```diff
+# --- wf-amplicon v1.2.2: ONE new SIF (medaka + wf-common already baked, same SHAs) ---
+# wf-amplicon has NO base.config (404) — SHA is in nextflow.config. Lean pattern: pull then
+# clean the OCI cache in THIS layer so duplicate blobs don't persist.
+ARG WF_AMPLICON_VERSION=v1.2.2
+RUN set -eux; \
+    curl -fsSL -o /tmp/amplicon.config \
+      "https://raw.githubusercontent.com/epi2me-labs/wf-amplicon/${WF_AMPLICON_VERSION}/nextflow.config"; \
+    amplicon=$(sed -n 's/^[[:space:]]*container_sha *= *"\(sha[0-9a-f]*\)".*/\1/p' /tmp/amplicon.config | head -n1); \
+    test "$amplicon" = "sha0ba67476938520e6f132759780d0a0e902925c59"; \
+    apptainer pull --force \
+      "/opt/sif-cache/ontresearch-wf-amplicon-${amplicon}.img" \
+      "docker://ontresearch/wf-amplicon:${amplicon}"; \
+    apptainer cache clean -f || true; \
+    rm -rf /root/.apptainer/cache "${APPTAINER_CACHEDIR:-/root/.apptainer/cache}" /tmp/* ; \
+    ls -la /opt/sif-cache
+RUN nextflow pull epi2me-labs/wf-amplicon -r "${WF_AMPLICON_VERSION}" \
+    && chown -R vscode:vscode /opt/nextflow
```

Resulting baked filename (must match Nextflow's singularity cache naming):
`/opt/sif-cache/ontresearch-wf-amplicon-sha0ba67476938520e6f132759780d0a0e902925c59.img`. No new ENV
needed (`NXF_SINGULARITY_CACHEDIR`/`NXF_HOME` already set). Also `COPY amplicon_validate.sh` (+ any new
post-step scripts) into `/opt/pcv/`.

**The one runtime-network risk — medaka model (auto-selected from the data).** wf-amplicon polishes with
`medaka inference --model <basecaller_cfg>:consensus`, where `<basecaller_cfg>` is **auto-detected from the
read headers** (MinKNOW sup embeds the basecaller id) unless pinned with `--override_basecaller_cfg`. So we
**use auto-selection by default** — no model to pick. The offline catch: auto-selection resolves the model
*name* from the data, but medaka still needs that model's *weights* baked in the SIF, else it downloads them
(fails offline). Confirmed input: **R10.4.1 E8.2 5 kHz sup** → `dna_r10.4.1_e8.2_400bps_sup@v5.x:consensus`
(current chemistry, very likely bundled; verify the exact `@vX.Y.Z`). The Dockerfile now prints the bundled
medaka models at build time (`medaka tools list_models`); if the sup model is absent, pin a bundled one via
`OVERRIDE_BASECALLER_CFG` (the wrapper exposes it). Also: don't strip FASTQ headers in pre-filtering, or
auto-detection breaks — another reason Mode A defaults to no pre-filter.

Everything in this section is **host/CI-only** — Docker Hub is unreachable in the sandbox.

### 8c. plannotate on a linear consensus (Stage 3)

Reuse the vendored `run_plannotate.py` inside the plannotate SIF. It takes a **directory** of FASTA files
(filename `<sample>.final.fasta`; it strips `.final` for the name) and reads **only the first record per
file**. The bundled DBs resolve via `--database Default` (fully offline).

**Exact invocation (host):**
```bash
SIF=/opt/sif-cache/ontresearch-plannotate-shae4901fb4353581a26049f564d279edd81fe38805.img
GLUE_BIN=/opt/nextflow/assets/epi2me-labs/wf-clone-validation/bin   # the workflow_glue package
WORK=$(mktemp -d); mkdir -p "$WORK/assemblies"
# split all-consensus-seqs.fasta into one <sample>.final.fasta per record (seqkit split -i), then:
apptainer exec --containall --no-home --pwd "$WORK" \
  --bind "$WORK":"$WORK" --bind "$GLUE_BIN":/glue:ro \
  --env PYTHONPATH=/glue --env MPLCONFIGDIR="$WORK/.mpl" \
  "$SIF" python /glue/workflow_glue/run_plannotate.py \
    --sequences "$WORK/assemblies" --database Default --linear
```

**Required patch — force linear.** The stock script tries circular first (which *doubles* the sequence →
spurious origin-spanning hits) and only falls back to linear on `IndexError`; it also writes a *circular*
GenBank regardless. For PCR products, add a `--linear` flag threaded through `run_plannotate()` →
`create_gbk(..., is_linear=True)` (small, ~10-line patch; agent gave the exact diff). This is needed in
both Phase 1 and Phase 2.

**Input prep:** convert `all-consensus-seqs.fasta` to one `<sample>.final.fasta` per record
(`seqkit split -i` then rename; sanitize any `.final` substring in record IDs). One record per file is
mandatory — multi-record files silently drop all but the first.

**Outputs:** `plannotate_report.json` (cleaned feature dataframe — the Stage-4 input), `feature_table.txt`,
`<sample>.annotations.{bed,gbk}`. The bokeh plot is embedded in JSON, not saved standalone; for Phase 1's
standalone map add `bokeh.io.save(plot, filename=..., resources=INLINE)` (INLINE = offline-safe).

**Edge cases:** no features found is handled (empty entry, no bed/gbk); outputs are append-mode so always
run in a fresh `--pwd` dir; very short / non-ACGT / multi-contig need the split + sanitize above.

### 8d. Combined HTML report (Stage 4) — SUPERSEDED by the Stage-5 splice

> **Note (2026-06-24):** What shipped is *not* this re-render. `combined_report.py` builds the
> **annotation-only** report (Stage 4); the combined "QC + annotation" report is produced by **splicing**
> the annotation section into the finished `wf-amplicon-report.html` (`merge_report.py`, Stage 5). The
> splice is robust precisely *because* both reports share the identical ezcharts build (byte-identical JS
> bundles), which this section already noticed — but it reuses wf-amplicon's own rendered QC instead of
> re-deriving it, sidestepping R1/R2 below. See `decision_log.md` (2026-06-24). The text below is retained
> as the rejected design.

**Approach: compose ezcharts — reuse both workflows' `report.py` code**, run in the
**wf-clone-validation SIF**. Both reports already share the identical `labs.LabsReport` skeleton + the
`epi2melabs` theme; the merge is "call both bodies into one report object + add the plannotate section."

Layout (one report, dropdown-tab per sample):
1. At-a-glance status cards (reads/bases/length/Q/consensus length, pass/fail badge).
2. **(a) Input read QC** — fastcat length/quality histograms + raw/filtered/trimmed table (reuse amplicon `preprocessing_section()`).
3. **(b) De-novo consensus QC** — per-contig method/length/depth (reuse amplicon `de_novo_qc_section()`).
4. **(b) Re-alignment summary** — reads aligned/unmapped/coverage (reuse amplicon `format_de_novo_summary_table()`).
5. **(d) Depth of coverage** — coverage-along-consensus line plot (extract amplicon's inline depth block into a function).
6. **(c) Plannotate linear feature map + annotation table** — lift clone-val's section (`report.py:111-148`),
   **forcing `get_bokeh(df, linear=True)`**; data from `plannotate_report.json`.
7. Versions/params footer (automatic).

**Reuse map:** amplicon `ReportDataSet`, `preprocessing_section`, `de_novo_qc_section`, the stats/progress
helpers, and clone-val `get_bokeh` + `format_badge` are reusable **as-is**. Needs adapting: extract the
depth block into a function; call section builders individually (don't call the monolithic `populate_report`
— it drags in variant-calling sections); merge the two argparsers; force linear in the plannotate plot.

**Risks:** (R1) ezcharts version skew — amplicon code was authored for 0.15.2, the cloneval SIF has 0.12.0;
every import/symbol was verified to resolve, but *behavioural* drift (e.g. `SeqSummary`/`lineplot` kwargs,
theme CSS) can only be confirmed by a real render on the host. Fallback: bake `plannotate==1.2.0` into the
wf-common SIF (0.15.2) and host the merge there instead. (R2) bokeh 2-vs-3 is already solved by the
dataframe-rebuild design — **don't** try to embed plannotate's native bokeh-2 plot. (R3) `bokeh_plot.py:97`
uses `df.append` (removed in pandas ≥2) — fine on the SIF's pandas 1.3.5, watch on any image bump.
(R4) sample-key alignment: ensure the plannotate stage and the QC stage use the **same** `sampleNN` alias
end-to-end so tabs line up. (R5) QC-file harvesting: `qc-summary.tsv` is staged internally by wf-amplicon
and may not be a published file — confirm on the host which QC inputs are published vs. need pulling from `work/`.

### 8e. `amplicon_validate.sh` wrapper (Stages 1-4 orchestration)

Mirrors `clone_validate.sh` conventions (`set -euo pipefail`, `usage()` awk header, `SCRIPT_DIR` sibling
resolution, `PROFILE` autodetect, `EXTRA_NF_ARGS`→array, the run-or-print fallback) but is **structurally
simpler** for Stage 2 and adds explicit Stage 3-4 post-steps.

**Signature** (third positional becomes the *pre-filter mode*, since amplicons have no single size):
```
./amplicon_validate.sh <raw_dir> <out_dir> [filter_mode] [min_len] [min_qual] [max_len]
    filter_mode : none (default) | minlen | window
    min_len  default 300    min_qual default 10    max_len optional (window only)
```

**Env:** `PROFILE` (autodetect, copy verbatim), `WF_VERSION` default **`v1.2.2`**, `EXTRA_NF_ARGS`,
optional `OVERRIDE_BASECALLER_CFG` (→ medaka model pin). **No** `--assembly_tool` default and **no**
`approx_size`/`FORCE` envelope guard (neither exists for de-novo amplicon — do not port them from the
plasmid wrapper).

**Steps:** arg-parse → (optional) pre-filter + reshape to `NF_IN/barcodeNN/reads.fastq.gz` →
`nextflow run epi2me-labs/wf-amplicon -r v1.2.2 --fastq NF_IN --out_dir … --min_read_length … --min_read_qual …
-profile $PROFILE "${EXTRA[@]}"` (**never** add `--reference`) → if nextflow present, run, else print the
command and stop → Stage 3 (`apptainer exec` plannotate, §8c) → Stage 4 (`apptainer exec` combined report,
§8d) → echo deliverable paths.

**De-novo guard:** reject a smuggled reference — `if [[ "${EXTRA_NF_ARGS:-}" == *"--reference"* ]]; then
echo "ERROR: de-novo only; drop --reference" >&2; exit 1; fi`.

**Pre-filter decision (important):** default **`none`** — let wf-amplicon's own fastcat do `min_read_length`/
`min_read_qual`. Reuse the generic `filter_nanopore_reads.sh` only as opt-in (`minlen`/`window`, e.g. to cap
concatemers via `max_len`). **Do NOT offer an AUTO mode / do NOT use `estimate_length_peak.sh`** — its
single-dominant-peak assumption (valid for full-length plasmid reads) is false for multi-size linear
amplicons and would silently drop non-dominant products. Defaults are **300 / Q10**, never clone-val's
5000 / Q20 (which would zero out amplicon reads).

---

## 8. Repo integration

| Path | Action | Covers |
|---|---|---|
| `amplicon_validate.sh` | **new** (root) | the wrapper (§8e); sibling to `clone_validate.sh` |
| `run_plannotate.py` (vendored copy) | **patch** | add `--linear` flag (§8c). Upstream this if it lands in a future workflow bump. |
| `combined_report.py` | **new** | Stage-4 merged report (§8d); ships into the wf-clone-validation SIF context |
| `filter_nanopore_reads.sh` / `estimate_length_peak.sh` | reuse / **not wired** | generic filter reused as opt-in; peak finder intentionally unused |
| `docs/amplicon_validate.md` | **new** | how-to: usage, de-novo-only stance, 300/Q10 defaults, no-AUTO rationale, output locations |
| `docs/amplicon_sif_cache.md` | **new** | wf-amplicon SIF manifest + cache-filename recipe (confirm by one online run) |
| `docs/decision_log.md` | **append** | the compose-not-fork decision (draft below) |
| `CLAUDE.md` | **edit** | new Locked-decisions + Critical-gotchas bullets (draft below) + docs-map entry |
| `README.md` | **edit** | add the script + docs to Contents / layout; short de-novo-amplicon subsection |
| `.devcontainer/build/Dockerfile` | **edit (host-only)** | SIF-bake block + `nextflow pull` + `COPY` (§8b) |

**Draft CLAUDE.md bullets**

Locked decisions:
- *Amplicon integration = a second pre-filter wrapper* (`amplicon_validate.sh`) over `wf-amplicon` v1.2.2 in
  **de-novo mode** (`reference=null`; never pass `--reference`), NOT a fork. wf-amplicon does only
  consensus + QC; **we add** the plannotate annotation (Stage 3) and the combined report (Stage 4).
- *No assembler lever, no `approx_size`, no envelope guard for amplicons* — de-novo has one assembly path
  and no re-clip rule; don't port those from the plasmid wrapper.

Critical gotchas:
- *Amplicon AUTO is intentionally absent* — `estimate_length_peak.sh` finds one full-length peak (RBK
  plasmid reads); multi-size linear amplicons are multi-modal, so AUTO would drop non-dominant products.
  Default = no pre-filter; defaults 300/Q10, not 5000/Q20.
- *wf-amplicon de-novo = ONE consensus per barcode* — multi-amplicon barcodes collapse to the highest-depth
  contig (and `mosdepthWindows` fails on >1 contig). Confirm one-amplicon-per-barcode.
- *wf-amplicon ships a different SIF set (1 new SIF) and has no `base.config`* — bake at host/CI (Docker Hub),
  read the SHA from `nextflow.config`, and confirm cache filenames from one online run. The **medaka model**
  is the one runtime-network risk — verify it's bundled / pin `--override_basecaller_cfg`.

**Draft `docs/decision_log.md` entry** — newest-first:
> **2026-06-23 — Amplicon support: compose wf-amplicon (de-novo) + reuse plannotate, not a fork.** Add
> `amplicon_validate.sh` over `wf-amplicon` v1.2.2 de-novo; reuse the plannotate SIF + clone-val's report
> engine for annotation + a combined report (new `combined_report.py`); default to no pre-filter; no AUTO
> mode (peak finder is single-peak by construction). Rejected: forking either workflow (drift/maintenance);
> an `amplicon` mode inside `clone_validate.sh` (different flags/SIFs — a fork-in-a-script); reference mode
> now (deferred). Consequence: a second SIF set (host-build only) + a `run_plannotate.py --linear` patch.

---

## 9. Testing strategy

**In-sandbox (no Docker Hub, no run) — all of this works now:**
- `bash -n amplicon_validate.sh` (+ `shellcheck`).
- **Dry-run command print** (run-or-print fallback with nextflow stubbed): assert the printed command has
  `-r v1.2.2`, `--min_read_length 300`, `--min_read_qual 10`, and **no `--reference`** (the de-novo invariant).
- Pre-filter + reshape path with the in-image **seqkit** on a tiny example → `NF_IN/barcodeNN/reads.fastq.gz`.
- De-novo guard (rejecting `--reference`).
- The `--linear` patch's Python parses (syntax/import check where the plannotate SIF isn't needed).
- All doc edits.

**Host / online only:**
- Pulling the wf-amplicon SIF, the full `nextflow run`, Stages 3-4 (`apptainer exec`), and the
  `combined-report.html`.
- Confirming the Nextflow SIF cache filenames (the #1 silent offline-breaker).
- Any `.devcontainer/build/` change.
- ✅ Example amplicon data + correctness target committed under `examples/amplicon/`
  (de-identified; 2 barcodes → 2 amplicons, ~2,156 & ~3,283 bp). Re-running it end-to-end through
  `amplicon_validate.sh` reproduces both consensuses + the combined report (validated 2026-06-24).

**Example data — committed, de-identified (status 2026-06-24).** The amplicon example mirrors the plasmid
layout — `examples/amplicon/raw/` (`barcode18/` + `barcode21/`, one concatenated `*.fastq.gz` each, + the
`amplicon_samplesheet_example.csv`) and a sibling `examples/amplicon/reference_run_wf-amplicon/` (the EPI2ME
reference run = the correctness target, the amplicon analogue of `examples/plasmid/reference_run_canu/`). It
is **two distinct amplicons** (~2,156 & ~3,283 bp), so it also exercises multi-barcode runs and (by mixing
the two barcodes) the reference-free Mode B / `SPLIT` path. An
earlier single-amplicon fixture was removed (its insert exposed unpublished work); this dataset replaces it.
The committed allowlist is the single `!examples/**` block in `.gitignore` (no per-fixture lines).
wf-amplicon's bundled `test_data/` is a data-free fallback for a smoke test. How a clean-room tester drives
it: [`amplicon_testing.md`](amplicon_testing.md) §0/§4.
> ✅ **De-identified for public release (2026-06-24).** Scrubbed across all kept files: the lab host/username
> (→ `/home/user`, `validation-host`), a project codename (incl. inside the raw FASTQ read headers), and the
> sample aliases (→ `sample01`/`sample02`). Heavy/incidental outputs were dropped (the `.bam`/index, the
> Nextflow `execution/` reports, `igv.json`, the report shim). The MinION run/flowcell ids (`MN24660`,
> `BCB599`) are **kept on purpose** — they're dataset identity and appear in the read headers (which medaka's
> auto-model reads). See `examples/amplicon/README.md`.

---

## 10. Open questions / risk register

| # | Item | Status / severity |
|---|---|---|
| ✅ Q1 | One vs many amplicons per barcode | resolved: Mode A (single, de-novo) now; Mode B (multiplex, reference) deferred — no data yet |
| ✅ Q2 | Amplicon size vs the 5 kb spoa cap | resolved: 1–3 kb, comfortably under |
| ✅ Q2b | Pooled amplicons distinct enough to separate by mapping? | resolved: distinct loci → yes (Mode B) |
| Q3 | R10.4.1 5 kHz sup model weights bundled in the medaka SIF? | host build — high (offline gate); build prints the model list; else pin `OVERRIDE_BASECALLER_CFG` |
| D1 | Mode B: reference-anchored (B1) vs de-novo-per-bin (B2) | deferred with Mode B (directions in §3) |
| R1 | ezcharts 0.12.0 vs 0.15.2 drift in the combined report | host render — medium |
| R2 | wf-amplicon QC files (`qc-summary.tsv`) harvesting for Stage 4 | host — medium |
| R3 | wf-amplicon SIF cache filenames must be confirmed online | host — high (silent offline break) |
| R4 | `-profile standard` (Docker) path for Stages 3-4 (bash assumes apptainer) | Phase 5 — low |

---

## 11. Source index (for whoever expands this)

- wf-amplicon v1.2.2: `nextflow.config:67-69` (SHAs/labels), `main.nf:384-444` (de-novo branch), `main.nf:508-511`
  (fastcat filter), `modules/local/de-novo.nf` (miniasm/racon/spoa/medaka/trim), `bin/workflow_glue/run_spoa.py`,
  `bin/workflow_glue/trim_and_qc.py`, `bin/workflow_glue/subset_reads.py`, `bin/workflow_glue/report.py`
  (+ `report_util.py`), `output_definition.json`. (No `base.config` — 404.)
- Vendored clone-val: `/opt/nextflow/assets/epi2me-labs/wf-clone-validation/bin/workflow_glue/run_plannotate.py`,
  `bokeh_plot.py`, `report.py` (+ `report_utils/`), `main.nf:351-352` (runPlannotate), `:521` (report).
- This repo: `clone_validate.sh`, `filter_nanopore_reads.sh`, `estimate_length_peak.sh`,
  `.devcontainer/build/Dockerfile`, `docs/sif_cache.md`, `docs/decision_log.md`, `docs/assembly_findings_2026-06-21.md`.
