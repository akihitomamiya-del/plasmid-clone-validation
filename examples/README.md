# Example & reference data

One home for all shipped test fixtures, for both pipelines. Point a wrapper at a directory
holding **one folder per barcode** (`barcodeNN/`, two-digit), each with `*.fastq.gz`:

    <dir>/
      barcode01/  *.fastq.gz
      barcode09/  *.fastq.gz

`clone_validate.sh <dir> …` and `amplicon_validate.sh <dir> …` both consume exactly this layout
(sibling non-`barcodeNN` dirs are warned-and-skipped).

## `plasmid/` — clone-validation
- `raw/barcode69/` — raw ONT concat (~765 reads); the input to `clone_validate.sh`.
- `raw/barcode69.len5kb-6kb_q20.fastq.gz` — the same reads pre-filtered to 5–6 kb, Q≥20 (**128 reads**).
- `reference_run_canu/` — EPI2ME canu reference output = the clone-validation **correctness target**
  (1 contig, **5,652 bp**, "Completed successfully"). See its own README.

## `amplicon/` — wf-amplicon + annotation
- See [`amplicon/README.md`](amplicon/README.md) — where an amplicon example fixture + its reference
  run live, and how to drop in a new one.
