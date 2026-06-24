# examples/plasmid/reference_run_canu — correctness target for the build

The output of an **EPI2ME Desktop** run (`epi2melabs/5.3.1`) of `wf-clone-validation` on the example
data using the **canu** assembler. Use it as the expected result when validating the sandboxed
container build (`docs/archive/setup_and_plan.md` §7 Phase 4) — a fresh run should reproduce this.

## Input
`barcode69.len5kb-6kb_q20.fastq.gz` — the example reads filtered to **5–6 kb, mean Q ≥ 20** (128 reads).
This is the same set our pipeline produces from `examples/plasmid/raw/barcode69/` (the raw ~765-read concat).

## Exact parameters (from `params.json`)
| param | value |
|---|---|
| `assembly_tool` | **canu** |
| `approx_size` | **5000** |
| `assm_coverage` | 60 |
| `min_quality` | 9 (input already Q≥20-filtered, so moot) |
| `trim_length` | 0 |
| `large_construct` | false |
| `flye_quality` | nano-hq (unused for canu) |
| `threads` | 16 |

## Expected result (the reference)
- **Status: `Completed successfully`** (`output/sample_status.txt`).
- **1 contig, `>barcode69`, 5,652 bp** (`output/barcode69.final.fasta`), medaka mean-Q ~56.
- Annotations (`output/feature_table.txt`): **AmpR**, **ori** (ColE1/pUC), **attL2**, and a **PGR3**
  (PP344_ARATH, *Arabidopsis*) insert — i.e. a ~5.65 kb plasmid with an Arabidopsis insert.

## Key files
- `output/barcode69.final.fasta` — the assembled plasmid (**primary comparison target**).
- `output/sample_status.txt`, `output/barcode69.assembly_stats.tsv` — status + length.
- `output/wf-clone-validation-report.html` — the full report.
- `output/feature_table.txt`, `output/barcode69.annotations.{gbk,bed}` — plannotate annotations.
- `params.json`, `launch.json`, `nextflow.log` — exactly how it was run (EPI2ME GUI metadata).

## Reproduce it with our wrapper
```bash
# raw -> filtered (same 128 reads) -> canu, matching the reference params:
EXTRA_NF_ARGS="--assembly_tool canu --assm_coverage 60" PROFILE=singularity \
  ./clone_validate.sh examples/plasmid/raw runs/cv_canu 5000 5000 20 6000
```
**Pass criteria:** status `Completed successfully`, one contig of ~5,652 bp (deconcatenation accepts
`0.8–1.2×approx_size`), and the same core annotations. (flye on the same data is expected to fail —
see `docs/assembly_testing.md`.)

> Produced on another machine via EPI2ME Desktop; absolute paths in `params.json`/logs are that host's.
