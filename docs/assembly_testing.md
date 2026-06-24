# Testing assembly parameters (canu vs flye)

How to sweep `wf-clone-validation` assembly parameters on the example data, and why canu often
succeeds where flye fails on small/low-coverage plasmid amplicons. Param names/defaults are from
`wf-clone-validation` **v1.8.4** (`nextflow.config`, `nextflow_schema.json`, the assembly modules).

## Selecting the assembler

| | value | source |
|---|---|---|
| Param | `--assembly_tool` | `nextflow_schema.json` (enum `['canu','flye']`) |
| **Default** | **`flye`** | `nextflow.config` (`assembly_tool = "flye"`) |
| Wiring | `main.nf` includes `canu_assembly.nf` or `flye_assembly.nf` as `assembleCore` by this param | `main.nf:7-11` |

ONT's own guidance (README): *"Flye is our default… If Flye fails to assemble you may wish to try
Canu."* — exactly the situation on this dataset.

## Parameters worth sweeping (defaults)

| Param | Default | Effect |
|---|---|---|
| `approx_size` | 7000 | Construct size; drives **all** length bounds (see the gotcha). For ~5–6 kb constructs use **~5500**. Settable per-sample via the sample sheet. |
| `min_quality` | 9 | `seqkit seq -Q` mean-Q floor before assembly. Our reads are pre-filtered to Q≥18–20, so 9 removes nothing extra. |
| `assm_coverage` | 60 | Downsampling target driver. `rasusa` target = `assm_coverage*3` (=180×); trycycler subsample floor = `(assm_coverage/3)*2` (=40×). |
| `flye_quality` | `nano-hq` | flye read-quality mode (`nano-hq`/`nano-corr`/`nano-raw`). `nano-hq` = correct for SUP/Q20 data. **flye only.** |
| `non_uniform_coverage` | false | Adds flye `--meta`; can rescue uneven amplicon depth. **flye only.** |
| `canu_fast` | false | Adds canu `-fast`. **canu only.** Negligible quality cost at 5 kb. |
| `trim_length` | 0 | Hard end-trim (bp) via `seqkit subseq`. Leave 0 for amplicons. |
| `large_construct` | false | For 50–300 kb (BACs); changes the min-length floor to 200 bp. Leave false for plasmids. |

### ⚠️ The read-sufficiency gate (can silently DROP a sample)

`checkIfEnoughReads` (`main.nf:53-83`) runs **before** assembly. It re-filters reads to
`[0.5×, 1.5×]×approx_size` and requires **≥ `assm_coverage*0.8` reads** (=48 at the default 60),
else the sample is dropped as `"Failed due to insufficient reads"`. **Trap:** raising
`assm_coverage` to 300 makes the floor 240 — barcode69's ~128–207 reads would be dropped. Keep
`assm_coverage` modest (≤60) on thin samples.

### ⚠️ The `approx_size` gotcha

`approx_size` sets the per-read max length (`approx_size*1.2` at the assembler) and the fastcat
window (`0.5–1.5×`). If it's wrong it silently re-clips your reads or mis-sizes the assembly. Keep
`ceil(max_len/1.2) ≤ approx_size ≤ 2×min_len` (the wrapper enforces this; see `clone_validate.sh`).
For a 5–6 kb window, `approx_size ∈ [5000, 10000]`; use ≈ the true construct size (~5500).

## Why flye fails but canu succeeds here

**Validated 2026-06-21** — controlled factorial + run-log evidence in
`docs/assembly_findings_2026-06-21.md`. Both assemblers share the same upstream flow: trim → `rasusa`
downsample → `trycycler subsample` into 3 sets → assemble each ×3 → deconcatenate → `trycycler`
reconcile → medaka polish.

**Flye — its auto minimum-overlap exceeds the read length → divide-by-zero crash.** Flye overlaps
*raw* reads and **auto-selects** a minimum overlap (≈ read **N90** rounded up to a round number). The
workflow does **not** override this for our sizes — `flye_assembly.nf:27` sets `--min-overlap 1000`
only when `approx_size ≤ 3000` (with the prescient comment *"assembly with same size as overlap will
likely fail"*). RBK full-length plasmid reads are ~5.6 kb, so flye picks **min-overlap 6000 — longer
than the reads** — no two reads can overlap → flye dies with `SIGFPE` (divide-by-zero on zero
overlaps): `flye-modules assemble … --min-ovlp 6000 … died with <Signals.SIGFPE: 8>`
(`Reads N50/N90: 5634/5616`). After 4 deterministic retries → `Failed to assemble using Flye`, 0
contigs. Because min-overlap is **read-driven, not `approx_size`-driven**, changing approx_size
(5000↔7000) doesn't help, and length-/quality-selecting (which strip short reads → raise N90) makes
it **worse**. Flye only assembles when the read pool keeps enough short reads to drop N90 below ~5000
(→ min-overlap 5000 ≤ read length); on the unfiltered Q20 set (N90 4969) it succeeded.

**Canu — error-correct first, seed-overlaps → robust.** Canu's pipeline is correction (mhap) → trim
corrected reads → assemble: it corrects raw reads before assembly (tolerates noisy/raw input) and
uses k-mer seed overlaps with no "min-overlap ≥ read length" rule (tolerates uniform full-length
reads). It emitted the correct 1-contig / 5,652 bp plasmid in **every** condition tested — raw,
Q-only, length-only, length+Q, and even at the wrong `approx_size=7000`. **The decisive factor is the
assembler, not the read filtering.**

## Test matrix (~6 runs on the example data)

**Wrapper limitation:** `clone_validate.sh` now passes extra Nextflow args via the `EXTRA_NF_ARGS`
env var (added for exactly this). The example raw input is `examples/plasmid/raw/barcode69/` (the
unfiltered ~765-read concat); filtering to 5–6 kb/Q20 yields ~128 reads (matching the shipped
reference `examples/plasmid/raw/barcode69.len5kb-6kb_q20.fastq.gz`). Use `PROFILE=singularity` inside the
devcontainer, `PROFILE=standard` on a Docker host.

```bash
RAW=examples/plasmid/raw; W="5000 20 6000"   # min_len=5000 min_qual=20 max_len=6000

# 1. canu baseline (known-good)
EXTRA_NF_ARGS="--assembly_tool canu --assm_coverage 60" \
  ./clone_validate.sh $RAW runs/m1_canu 5500 $W
# 2. flye, same settings (reproduce the failure)
EXTRA_NF_ARGS="--assembly_tool flye --assm_coverage 60" \
  ./clone_validate.sh $RAW runs/m2_flye 5500 $W
# 3. flye, lower coverage target (does shrinking the subsample target help?)
EXTRA_NF_ARGS="--assembly_tool flye --assm_coverage 30" \
  ./clone_validate.sh $RAW runs/m3_flye_cov30 5500 $W
# 4. flye + --non_uniform_coverage (adds --meta)
EXTRA_NF_ARGS="--assembly_tool flye --non_uniform_coverage true" \
  ./clone_validate.sh $RAW runs/m4_flye_meta 5500 $W
# 5. approx_size too large (default 7000 → mis-sized assembly even if reads pass)
EXTRA_NF_ARGS="--assembly_tool flye" \
  ./clone_validate.sh $RAW runs/m5_flye_approx7000 7000 $W
# 6. canu at approx_size 7000 (isolate "assembler" vs "sizing" effects)
EXTRA_NF_ARGS="--assembly_tool canu" \
  ./clone_validate.sh $RAW runs/m6_canu_approx7000 7000 $W
```
(Optional drop-demo: `--assm_coverage 300` makes the gate floor 240 → barcode69 dropped.)

### What to compare across runs
- **Per-sample status** — `<out>/cloneval/sample_status.txt` and the HTML report's status table:
  `Completed successfully` vs `Failed to assemble using Flye` / `Completed but failed to reconcile`
  / `Failed due to insufficient reads`.
- **Assembled length** vs the ~5.5 kb expected (deconcatenation only accepts `0.8–1.2×approx_size`).
- **# contigs / circularity** — `grep -c '^>' <out>/cloneval/<alias>.final.fasta`; clean plasmid = 1.
- **Expected-assembly tick** — only if you pass `--insert_reference`/`--full_reference`.
- The report states which assembler ran, so canu/flye runs are self-labeling.

Expected pattern: **#1 canu PASS; #2 flye FAIL/"failed to reconcile"; #3/#4 test whether
lower-coverage / meta-mode rescue flye; #5/#6 show approx_size mis-sizing.**

## Resources / runtime (single barcode, ~5 kb)
- Per-process memory is hard-coded: **flye 4 GB, canu 7 GB**, medaka 4 GB, plannotate 2 GB. Size the
  executor for **7 GB** when testing canu.
- `--threads` default 4 is plenty here.
- **Failing flye runs take ~5× longer** — the assembly process retries 4× (deterministically) before
  giving up. Budget for it when running the flye cells.
