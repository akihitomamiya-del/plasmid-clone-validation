# Reference validation — flag consensus-vs-reference mutations

"**Does my clone match the intended construct?**" Where the annotation step
([`amplicon_annotate.md`](amplicon_annotate.md)) *discovers* features de-novo, this step
**checks** a pipeline consensus against a construct map you already have in hand: align the
consensus to a **user-supplied reference** (`.gbk` or `.fasta`) and flag every discrepancy —
substitutions, insertions, deletions, and 5′/3′ truncations — noting whether each one lands
inside an annotated reference feature.

Entrypoint: `validate_against_reference.sh` (+ `amplicon_annotate/variant_parser.py`). It runs
**fully offline** inside the runtime image (minimap2 + the parser run in the baked SIFs via
`apptainer exec`); on a Docker-only host it no-ops with a clear message, like the rest of the
annotation steps.

## How to run

```bash
./validate_against_reference.sh <consensus.fasta> <reference.gbk|fasta> <out_dir>

# e.g. against the consensus a run already produced:
./validate_against_reference.sh \
    runs/amp/amplicon/all-consensus-seqs.fasta  my_construct.gbk  runs/amp/reference_check
```

- `<consensus.fasta>` — any consensus FASTA the pipeline emits (multi-record is fine; one
  variant report per record). Works for both amplicon and plasmid consensuses.
- `<reference.gbk|fasta>` — your intended sequence. A **GenBank** reference also gives
  **feature localisation** (each variant is tagged with the feature it falls in); a plain
  **FASTA** reference still reports all variants, just without feature names.

## What it produces (in `<out_dir>`)

| File | What |
|---|---|
| `variants_vs_reference.csv` | one row per discrepancy: `Consensus_ID, Ref_Pos, Type, Ref, Alt, Length, In_Feature, Feature, Feature_Type` |
| `variant_summary.txt` | one row per consensus: `n_subs, n_ins, n_del, trunc_5p_bp, trunc_3p_bp, identity%, verdict` (`MATCH` / `DISCREPANT` / `UNMAPPED`) |

`Ref_Pos` is 1-based on the reference (GenBank convention). `In_Feature` is `yes`/`no`;
`Feature`/`Feature_Type` name the overlapping GenBank feature (e.g. `RPF3 (AT1G62930)`, `CDS`).

## How it works

1. **GenBank → FASTA** (if needed): `variant_parser.py --gbk2fasta` dumps the reference ORIGIN
   so the aligner has a target.
2. **Align**: `minimap2 -a --cs -x asm10 <ref.fasta> <consensus.fasta>` in the **wf-amplicon SIF**.
   `asm10` is the assembly-to-assembly preset (clean, near-full-length alignment of one finished
   sequence to another) — not the noisy-read `map-ont` preset; the `--cs` tag makes the
   per-base differences unambiguous.
3. **Call variants**: `variant_parser.py` walks each primary alignment's `cs` tag (falling back
   to CIGAR+MD), emits subs/indels and end soft-clips as 5′/3′ truncations, tracks reference
   coordinates, and tags each variant by interval-overlap with the GenBank FEATURES table.

`variant_parser.py` is **stdlib-only** (SAM parsed as text — no pysam; GenBank parsed by a small
purpose-built parser — no BioPython), so the same file runs unchanged inside the SIF and on a
bare host. `variant_parser.py --selftest` self-checks the parser (a planted sub/insertion/
deletion/truncation) with nothing but `python3` — no Apptainer needed.

## Validation

Tested end-to-end in the runtime image against the committed example: a substitution planted
**inside the `RPF3` CDS** and a 3 bp deletion in the backbone of the ~2,156 bp consensus were both
flagged at the correct reference coordinates (the substitution carried `In_Feature=RPF3
(AT1G62930), CDS`), with `identity% = 99.81` and verdict `DISCREPANT`. `--selftest` passes
host-side. No network access is used; minimap2 and the parser run inside the baked SIFs.

See also: [`amplicon_annotate.md`](amplicon_annotate.md) (de-novo annotation, the complementary
"what's in it" step) and [`arabidopsis_annotation_plan.md`](arabidopsis_annotation_plan.md).
