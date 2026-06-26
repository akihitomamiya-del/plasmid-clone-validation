# Amplicon annotation — pLannotate-style BLAST features + HTML report

The annotation half of the amplicon pipeline: take the de-novo consensus from `wf-amplicon`
(see [`amplicon_plan.md`](amplicon_plan.md)), find **known elements** in it by BLAST/DIAMOND/Infernal
against pLannotate's bundled databases, render an annotation HTML report, and **splice that annotation
into the usual `wf-amplicon` report** to produce one combined report — all **fully offline** (every
database is baked into the SIF).

This is Stages 3–5 of [`amplicon_plan.md`](amplicon_plan.md), now **built**: pLannotate `--linear`
annotation (Stage 3), the annotation HTML report (Stage 4), and the optional merge into the
`wf-amplicon` report (Stage 5) — the latter is the single QC+annotation report the plan called the
PI's deliverable.

## What it produces

For each consensus record (one per barcode in de-novo mode):

| Output | What |
|---|---|
| `amplicon-report-with-annotation.html` | **the combined report** *(Stage 5; the headline deliverable)* — the usual `wf-amplicon-report.html` with the annotation section spliced in. Produced when the wf-amplicon report is passed to `annotate.sh` (arg 5); `amplicon_validate.sh` does this automatically. |
| `amplicon-annotation-report.html` | the **annotation-only** report — a per-sample **linear feature map** + **pLannotate map** + **annotation table** |
| `feature_table.txt` | CSV: feature, database, % identity, match length, description, start/end, strand |
| `<sample>.annotations.bed` | feature coordinates (BED) |
| `<sample>.annotations.gbk` | a **linear** GenBank record (topology `linear`, not `circular`) |
| `plannotate_report.json` | the raw annotation dataframe (drives the report) |

**Deliverables bundle.** After the report, `annotate.sh` also gathers the PI-facing files into one tidy
`<out>/deliverables/` folder (+ `deliverables.zip` + a plain-text `README.txt`): the combined report, the
wf-amplicon QC report, the consensus FASTA, `feature_table.txt`, and per-sample `<barcode>_<bp>bp.{gbk,bed,
consensus.fasta}` (copies — originals under `amplicon/`/`annotation/` are untouched). This is the folder to
hand to a collaborator. It is created in both entry modes (full pipeline and standalone `annotate.sh`).

## How it runs

`amplicon_validate.sh` calls it automatically after a successful `wf-amplicon` run (when a consensus was
produced and Apptainer is available):

```bash
# full pipeline: filter -> wf-amplicon de-novo -> annotation (linear) + combined HTML report
amplicon_validate.sh <raw_dir> <out_dir> none 300 15
#   -> <out_dir>/amplicon/         (wf-amplicon consensus + QC)
#   -> <out_dir>/annotation/amplicon-report-with-annotation.html  (combined = wf-amplicon + annotation)
#   -> <out_dir>/annotation/amplicon-annotation-report.html       (annotation-only report)
```

Or run it standalone on any `all-consensus-seqs.fasta` (inside the runtime image, which has Apptainer +
the baked SIFs). Pass the wf-amplicon report as the 5th arg to also get the **combined** report (Stage 5);
omit it to get just the annotation report:

```bash
amplicon_annotate/annotate.sh <consensus.fasta> <out_dir> [params.json] [versions.txt] [wf_amplicon_report.html]
```

## How it works (three post-steps: two required Apptainer steps + one optional merge, no Nextflow)

1. **Stage 3 — annotate.** Split the multi-record consensus into one `<sample>.final.fasta` per record,
   then run our patched `run_plannotate.py --linear` inside the **plannotate SIF** against
   `--database Default` (SnapGene→blastn, Swiss-Prot/fpbase→diamond, Rfam→infernal). Two small local
   changes to the vendored script: the `--linear` flag (see below), and — when a consensus has **no**
   annotatable features — keeping that sample in the report (with an empty table) instead of dropping it,
   so the report shows a "No known elements" tab rather than an empty dropdown.
2. **Stage 4 — annotation report.** `combined_report.py` runs inside the **wf-clone-validation SIF** (it
   has ezcharts + bokeh + pLannotate), loads `plannotate_report.json`, rebuilds the feature plot from the
   dataframe, and writes one `LabsReport` HTML (`amplicon-annotation-report.html`) with a summary + the
   per-sample **linear feature track** + pLannotate map + table.
3. **Stage 5 — merge (optional).** If the `wf-amplicon` report is passed (`annotate.sh` arg 5),
   `merge_report.py` splices the Stage-4 annotation section into that report and writes one **combined**
   report, `amplicon-report-with-annotation.html`. It is **pure stdlib** — preferring the host `python3`,
   with `python` inside the wf-clone-validation SIF as a fallback (no Nextflow, no extra SIF needed). The
   splice is safe because both reports are built by the same ezcharts version and embed byte-identical
   bokeh/echarts/datatables bundles, so the base report's JS runtime is reused (no library duplication,
   UUID element ids ⇒ no collisions). See the [combined report](#the-combined-report-stage-5) note below.

Files: `amplicon_annotate/{annotate.sh, run_plannotate.py, combined_report.py, merge_report.py}` (baked
into the image at `/opt/pcv/amplicon_annotate/`).

## The combined report (Stage 5)

The headline deliverable is one self-contained HTML — the usual `wf-amplicon-report.html` with the
annotation added as an extra **"Annotation"** section (linear feature map + pLannotate map + feature
table) plus a matching nav entry. It opens offline, renders both the wf-amplicon QC plots and the
annotation plots, and works for multi-barcode runs (one consensus + one annotation per barcode, all
folded into the per-sample dropdown). `amplicon_validate.sh` produces it automatically;
`annotate.sh <consensus> <out> [params] [versions] <wf-amplicon-report.html>` produces it standalone.

## The `--linear` patch (why)

The stock `run_plannotate.py` annotates **circular-first**: it doubles the sequence to catch
origin-spanning features and only falls back to linear on `IndexError`, and it always writes a *circular*
GenBank. For a **linear PCR amplicon** that doubling is wrong (spurious origin-spanning hits) and the
circular topology is misleading. Our vendored copy adds a `--linear` flag that annotates linearly up
front and writes a `linear` GenBank. The patch is minimal and threads one `force_linear` bool through
`run_plannotate → per_assembly → create_gbk(get_gbk(is_linear=True))`; default (no flag) behaviour is
unchanged, so it can be upstreamed.

**Circular plasmids reuse the same lever.** `annotate.sh` honours an opt-in `CIRCULAR=1` that simply
**omits** `--linear`, restoring pLannotate's native circular (origin-spanning) annotation + a `circular`
GenBank — this is how the plasmid pipeline annotates against the Arabidopsis DB
(`clone_validate.sh`, see [`arabidopsis_annotation_plan.md`](arabidopsis_annotation_plan.md) §9).
Default (`CIRCULAR` unset) keeps `--linear`, so the amplicon path here is byte-for-byte unchanged.

## The two feature maps (linear track + pLannotate map)

Each annotation section shows **two complementary views**:

1. **Linear feature track** — a left-to-right backbone diagram (`linear_feature_map()` in
   `combined_report.py`): forward (+) features above the backbone, reverse (−) below, overlapping
   features packed into lanes, hover for details. This is the primary view for a linear PCR amplicon.
2. **pLannotate map** — the tool's native (circular) renderer in linear mode, with an origin tick.
   Unfilled features are incomplete (match covers <95 % of the database feature).

The **annotation table** carries the precise linear coordinates (start/end on the 1..N bp amplicon) and is
the authoritative tabular view. (Earlier docs called the linear track a "future enhancement" — it is now
built; this section supersedes that note.)

## Offline / correctness

Validated on a host against the committed example
([`examples/amplicon/`](../examples/amplicon/README.md), two amplicons ~2,156 &
~3,283 bp): each consensus is annotated (Gateway recombination sites plus gene / promoter / terminator
elements, against the bundled SnapGene/Swiss-Prot/fpbase/Rfam DBs), the GenBank is `linear`, and each
per-sample **combined report** (`amplicon-report-with-annotation.html`) renders the
wf-amplicon QC plots plus the annotation's two maps + table in one self-contained file. No network access
is used; all BLAST databases ship in the SIF.
