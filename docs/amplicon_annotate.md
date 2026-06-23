# Amplicon annotation — pLannotate-style BLAST features + HTML report

The annotation half of the amplicon pipeline: take the de-novo consensus from `wf-amplicon`
(see [`amplicon_plan.md`](amplicon_plan.md)), find **known elements** in it by BLAST/DIAMOND/Infernal
against pLannotate's bundled databases, and render a **single HTML report** with a feature map + an
annotation table — all **fully offline** (every database is baked into the SIF).

This is Stages 3–4 of [`amplicon_plan.md`](amplicon_plan.md), now **built**.

## What it produces

For each consensus record (one per barcode in de-novo mode):

| Output | What |
|---|---|
| `amplicon-annotation-report.html` | the deliverable — a per-sample **linear feature map** + **annotation table** |
| `feature_table.txt` | CSV: feature, database, % identity, match length, description, start/end, strand |
| `<sample>.annotations.bed` | feature coordinates (BED) |
| `<sample>.annotations.gbk` | a **linear** GenBank record (topology `linear`, not `circular`) |
| `plannotate_report.json` | the raw annotation dataframe (drives the report) |

## How it runs

`amplicon_validate.sh` calls it automatically after a successful `wf-amplicon` run (when a consensus was
produced and Apptainer is available):

```bash
# full pipeline: filter -> wf-amplicon de-novo -> annotation report
amplicon_validate.sh <raw_dir> <out_dir> none 300 15
#   -> <out_dir>/amplicon/         (wf-amplicon consensus + QC)
#   -> <out_dir>/annotation/amplicon-annotation-report.html   (this feature)
```

Or run it standalone on any `all-consensus-seqs.fasta` (inside the runtime image, which has Apptainer +
the baked SIFs):

```bash
amplicon_annotate/annotate.sh <consensus.fasta> <out_dir> [params.json] [versions.txt]
```

## How it works (two `apptainer exec` post-steps, no Nextflow)

1. **Stage 3 — annotate.** Split the multi-record consensus into one `<sample>.final.fasta` per record,
   then run our patched `run_plannotate.py --linear` inside the **plannotate SIF** against
   `--database Default` (SnapGene→blastn, Swiss-Prot/fpbase→diamond, Rfam→infernal). The `--linear` flag
   (see below) is the only change from the vendored wf-clone-validation script.
2. **Stage 4 — report.** `combined_report.py` runs inside the **wf-clone-validation SIF** (it has
   ezcharts + bokeh + pLannotate), loads `plannotate_report.json`, rebuilds the feature plot from the
   dataframe, and writes one `LabsReport` HTML with a summary + the per-sample map + table.

Files: `amplicon_annotate/{annotate.sh, run_plannotate.py, combined_report.py}` (baked into the image at
`/opt/pcv/amplicon_annotate/`).

## The `--linear` patch (why)

The stock `run_plannotate.py` annotates **circular-first**: it doubles the sequence to catch
origin-spanning features and only falls back to linear on `IndexError`, and it always writes a *circular*
GenBank. For a **linear PCR amplicon** that doubling is wrong (spurious origin-spanning hits) and the
circular topology is misleading. Our vendored copy adds a `--linear` flag that annotates linearly up
front and writes a `linear` GenBank. The patch is minimal and threads one `force_linear` bool through
`run_plannotate → per_assembly → create_gbk(get_gbk(is_linear=True))`; default (no flag) behaviour is
unchanged, so it can be upstreamed.

## Caveat — the feature map is pLannotate's circular renderer

pLannotate's plot is a **circular** map (with an origin tick in linear mode); it does not draw a
left-to-right linear track. The **annotation table carries the precise linear coordinates** (start/end on
the 1..N bp amplicon), which is the authoritative view for a linear product. A native linear track is a
possible future enhancement.

## Offline / correctness

Validated on a host against the committed example (`amplicon_test_example/`, barcode09, 3,249 bp): the run
finds 5 elements — `IS1` (transposon), `attB2` (Gateway site), `insB1` (CDS) + 2 weak Swiss-Prot hits —
and the GenBank is `linear`. No network access is used; all BLAST databases ship in the SIF.
