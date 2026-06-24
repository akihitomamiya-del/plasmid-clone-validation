# Amplicon example data

Drop a self-contained amplicon fixture here as its own dir, e.g. `myrun_example/`:

    examples/amplicon/<name>_example/
      barcodeNN/                *.fastq.gz      # raw reads (one barcode per amplicon)
      wf-amplicon_*/output/      …              # its EPI2ME wf-amplicon de-novo reference run
                                               #   (all-consensus-seqs.fasta(.fai) = the correctness target)

Run it:

    ./amplicon_validate.sh examples/amplicon/<name>_example runs/amp none 300 15

The wrapper picks up the `barcodeNN/` reads dir and warns-and-skips the sibling `wf-amplicon_*/`
run dir (not `barcodeNN`).

## Status — no committed example fixture right now

The previous committed example (a single ~3,249 bp amplicon) was **removed** pending replacement
with a new, non-sensitive dataset. Until that lands, the amplicon end-to-end test in
[`docs/amplicon_testing.md`](../../docs/amplicon_testing.md) §4 has no shipped input — use
wf-amplicon's own bundled `test_data/` de-novo demo as a data-free smoke test, or drop your own
`barcodeNN/*.fastq.gz` dir here. The new fixture is tracked automatically by `.gitignore` (no edits
needed) once it lands at `examples/amplicon/<name>_example/`.

> A local-only second amplicon (for Mode B / multi-amplicon testing) may exist on disk here and is
> intentionally **gitignored** — never commit it.
