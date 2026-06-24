# Amplicon example data

A real, de-identified Oxford Nanopore amplicon run — **two barcodes, two distinct amplicons** — laid out
like the plasmid example (a `raw/` reads dir + a sibling `reference_run_*/`):

    examples/amplicon/
      raw/
        barcode18/barcode18.concat.fastq.gz    # amplicon ~2,156 bp (alias sample01)
        barcode21/barcode21.concat.fastq.gz    # amplicon ~3,283 bp (alias sample02)
        amplicon_samplesheet_example.csv        # barcode -> alias mapping (sample01/sample02)
      reference_run_wf-amplicon/                # the EPI2ME de-novo reference run = the correctness target:
        output/all-consensus-seqs.fasta(.fai)   #   sample01 = 2,156 bp, sample02 = 3,283 bp
        output/sampleNN/consensus/consensus.fastq
        output/wf-amplicon-report.html          #   the run's QC report

Run it through this repo's wrapper (point it at `raw/`; it reshapes the `barcodeNN/` dirs itself):

    ./amplicon_validate.sh examples/amplicon/raw runs/amp none 300 15

Expect **two consensuses (~2,156 bp + ~3,283 bp)**, each annotated, folded into a combined report +
a `deliverables/` bundle (see [`docs/amplicon_testing.md`](../../docs/amplicon_testing.md) §4). Mixing the
two barcodes into one and adding `SPLIT=1` recovers both amplicons (reference-free Mode B).

> **De-identified for public release.** Lab username/host/paths and a project codename were scrubbed
> (incl. the raw FASTQ read headers); the sample aliases were genericized to `sample01`/`sample02`; the reads
> were concatenated to one file per barcode; the heavy/incidental outputs (BAMs, `execution/`, the report
> shim, `igv.json`) were dropped. The MinION/flowcell ids (`MN24660`/`BCB599`) are kept on purpose.

## Adding another example

Same layout: drop a `barcodeNN/*.fastq.gz` set under `raw/` (+ optionally a `reference_run_*/`). It's tracked
automatically by `.gitignore` (no edits needed). **Only commit de-identified, non-sensitive data** — scrub
usernames/hosts/paths, project names (including from the raw read headers), and any identifying sample labels.
