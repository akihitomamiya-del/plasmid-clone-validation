# Amplicon example data

## `amplicon_test_example/` — the shipped fixture (correctness target)

A real, de-identified Oxford Nanopore amplicon run: **two barcodes, two distinct amplicons**, with its
committed EPI2ME `wf-amplicon` reference run (the amplicon analogue of
`examples/plasmid/reference_run_canu/`).

    amplicon_test_example/
      barcode18/  *.fastq.gz                  # 24 fastq.gz  (alias sample01 in the run)
      barcode21/  *.fastq.gz                  # 24 fastq.gz  (alias sample02 in the run)
      amplicon_samplesheet_example.csv        # barcode -> alias mapping (sample01/sample02)
      wf-amplicon_*/output/                    # the EPI2ME de-novo reference run:
        all-consensus-seqs.fasta(.fai)         #   sample01 = 2,156 bp, sample02 = 3,283 bp  ← the target
        sampleNN/consensus/consensus.fastq     #   per-sample polished consensus
        wf-amplicon-report.html                #   the run's QC report

Run it through this repo's wrapper (which reshapes the `barcodeNN/` dirs itself and warns-and-skips the
sibling `wf-amplicon_*/` reference-run dir):

    ./amplicon_validate.sh examples/amplicon/amplicon_test_example runs/amp none 300 15

Expect **two consensuses (~2,156 bp + ~3,283 bp)**, each annotated, folded into one combined report +
a `deliverables/` bundle (see [`docs/amplicon_testing.md`](../../docs/amplicon_testing.md) §4).

> **De-identified for public release.** Lab username/host/paths and a project codename were scrubbed
> (incl. the raw FASTQ read headers); the MinION/flowcell ids and the sample aliases were genericized to
> `sample01`/`sample02`. The heavy/incidental outputs (BAMs, `execution/`, the report shim) were dropped.

## Adding another fixture

Drop a self-contained dir alongside, `examples/amplicon/<name>_example/` (a `barcodeNN/*.fastq.gz` reads
dir + optionally its `wf-amplicon_*/output/` reference run). It is tracked automatically by `.gitignore`
(no edits needed). **Only commit de-identified, non-sensitive data** — scrub usernames/hosts/paths,
project names (including from the raw read headers), and any identifying sample labels first.
