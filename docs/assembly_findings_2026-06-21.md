# Read filtering & assembler choice — experimental findings (2026-06-21)

A controlled experiment on `example_rawdata/barcode69` (~5,652 bp plasmid, RBK library) to answer:
**which lever actually decides whether the plasmid assembles — read length-selection, quality
filtering, or the assembler (canu vs flye)?** Plus the data-driven peak finder
(`estimate_length_peak.sh`), the canu-vs-flye mechanism, and an inside-vs-outside-the-container check.

Runs used `wf-clone-validation v1.8.4`, `approx_size=5000`, `assm_coverage=60`, unless noted. Each
factor is controlled at exactly one place: **length** via a seqkit window, **quality** via the
workflow's `--min_quality` (7≈off vs 20), **assembler** via `--assembly_tool`.

---

## TL;DR — the assembler is the critical lever, not the filtering

1. **Choose canu.** Canu produced the correct 1-contig / 5,652 bp plasmid in **every** condition
   tested (raw, Q-only, length-only, length+Q; and even at the *wrong* `approx_size=7000`). Flye gave
   a **wrong length on raw (4,460 bp)** and **failed outright (0 contigs) on every length-selected
   set** — including the exact len+Q20 input we normally use.
2. **Length-selection is *not* what rescues the assembly** — canu already succeeds without it, and
   length-selection actively **breaks flye** (see mechanism). Its real value is (a) giving a clean,
   data-driven `approx_size` and (b) tightening canu's consensus to byte-identical with the reference.
3. **Quality filtering** is a secondary refinement: it sharpens canu's consensus (byte-exact only with
   Q20) and can rescue flye on unfiltered data — but you shouldn't be using flye here anyway.
4. **Net recipe (robust + cleanest):** data-driven length window (peak ±10%) **+ Q20 + canu**, with
   `approx_size ≈ the peak`. The load-bearing choice is **canu**; the filtering makes the consensus
   pristine and feeds a correct `approx_size`.

---

## 1. The data: a bimodal length distribution with a clean full-length peak

`barcode69.concat.fastq.gz` = **765 reads**, sharply **bimodal**:

| mode | ~length | reads | what it is |
|---|---|---|---|
| junk | < 1,500 bp | ~400 | adapter/fragment/partial reads |
| **full-length plasmid** | **5,500–5,999 bp** | **265** | RBK linearised full-length construct (≈ 5,652 bp reference) |
| concatemers | 10–18 kb | ~4 | multimers |

RBK (Rapid Barcoding) linearises the plasmid, so the dominant molecule is one full-length ~5.6 kb
read — which is exactly the read population that (a) we want and (b) breaks flye (§3).

## 2. `estimate_length_peak.sh` — data-driven peak & window (no hand-picked threshold)

The new script locates the full-length mode and derives a window automatically. Because the signal is
bimodal, it **yield-weights** the histogram (reads × length) so the full-length molecule — which
dominates sequenced bases — wins even though short fragments dominate read *count*; a min-length floor
+ smoothing finish the job.

On `barcode69` (`--report-only`):

| rule | peak | window | reads kept |
|---|---|---|---|
| `pct:10` (default) | **5,623 bp** | 5,061 – 6,185 | 274 / 765 |
| `fwhm` | 5,623 bp | 5,350 – 5,900 | 268 |
| `valley` | 5,623 bp | 5,300 – 5,800 | 268 |

Peak 5,623 vs reference 5,652 (−0.5%, expected — reads carry indels). The default window reproduces
our manual 5–6 kb choice **automatically**. **End-to-end validated:** `estimate_length_peak.sh →
clone_validate.sh → canu` gives `Completed successfully / 1 contig / 5,652 bp`.

## 3. The factorial: canu robust, flye fragile

8 runs = {raw, Q20, len5-6kb, len+Q20} × {flye, canu}, plus robustness probes:

| input (→) | flye | canu |
|---|---|---|
| **raw** (all lengths, Q≈off) | 1 contig, **4,460 bp** ✗ wrong | 1 contig, **5,652** ✓ |
| **Q20** (all lengths) | 1 contig, **5,652** ✓ | 1 contig, **5,652** ✓ |
| **len 5–6 kb** (Q≈off) | **FAILED, 0 contigs** ✗ | 1 contig, **5,652** ✓ |
| **len 5–6 kb + Q20** | **FAILED, 0 contigs** ✗ | 1 contig, **5,652**, **md5 = reference** ✓ |
| raw, `approx_size=7000` (probe) | (GUI-default emul.) **FAILED** ✗ | 1 contig, **5,652** ✓ |

- **canu: 5/5 correct**, robust to read filtering *and* to a wrong `approx_size`.
- **flye: wrong on raw, fails on every length-selected set.** Length-selection — the thing we thought
  was helping — is what *kills* flye.

## 4. Mechanism — why canu succeeds and flye fails (validated from the run logs)

### Flye: minimum-overlap exceeds the read length → divide-by-zero crash
Flye is a repeat-graph assembler that overlaps **raw** reads. It **auto-selects a minimum-overlap**
by rounding the read-length **N90** up to a round number. The workflow does **not** override this for
our sizes — `modules/local/flye_assembly.nf:27`:
```groovy
// min_overlap normally auto calculated but with a lower limit of 3000
// assembly with same size as overlap will likely fail
def min_overlap = meta.approx_size.toInteger() <= 3000 ? '--min-overlap 1000' : ''
```
So for `approx_size > 3000` (i.e. 5000 **and** 7000) flye picks min-overlap itself. With RBK
full-length reads (~5,634 bp), it lands on **6,000 bp — longer than the reads** — so **no two reads
can overlap**, the overlap graph is empty, and flye dies computing coverage stats:
```
flye-modules assemble ... --genome-size 5000 --min-ovlp 6000 ... died with <Signals.SIGFPE: 8>
Reads N50/N90: 5634 / 5616 | Minimum overlap set to 6000
```
`SIGFPE` (signal 8) = floating-point exception = **divide-by-zero on zero overlaps**. The workflow
retries 4× (deterministic → same crash) → `Failed to assemble using Flye`, 0 contigs.

**Why flye sometimes works:** on the *unfiltered* Q20 set, shorter reads pull **N90 down to 4,969**,
so flye picks **min-overlap 5,000 ≤ read length** → overlaps exist → it assembles (5,652). The decider
is the read-length distribution (N90), **not** `approx_size`. That is why **changing approx_size
5000↔7000 doesn't help, and why length-selecting or quality-filtering (which strip the short reads,
raising N90) makes it *worse*** — exactly the GUI behaviour reported.

### Canu: error-correct first, seed-overlaps → robust
Canu is an OLC assembler with an explicit 3-stage pipeline (from its log):
```
BEGIN CORRECTION → OVERLAPPER (mhap) (correction) → trim corrected reads → assemble corrected+trimmed
```
It (1) **error-corrects** raw Nanopore reads before assembly (so it tolerates noisy/raw input — why
`R-canu` works where `R-flye` is wrong), and (2) uses **k-mer seed overlaps** with no
"min-overlap ≥ read length" rule (so uniform full-length reads are fine — why `L/LQ-canu` work where
flye crashes). `genomeSize` only guides coverage; canu still nails the ~5.6 kb circle.

### Why the EPI2ME **GUI** flye run failed (and at any size you tried)
Same mechanism. The GUI default is **flye** + `approx_size 7000`, no pre-filter. The reads are
RBK full-length ~5.6 kb → flye auto-min-overlap 6,000 > reads → **SIGFPE** (reproduced exactly here,
`Reads N50/N90: 5627/5583, min-ovlp 6000`). Since min-overlap is flye's **read-driven** auto-pick
(not a workflow/GUI parameter for `approx_size>3000`), **dropping to size 5000, size-selecting, or
quality-filtering can't fix it** — those keep (or raise) the read length, so min-overlap stays 6,000.
The only in-pipeline escape would be `approx_size ≤ 3000` (forces `--min-overlap 1000`), but that
clips your 5.6 kb reads to ≤3.6 kb and mis-sizes the construct. **→ use canu.**

## 5. Inside vs. outside the container — identical science, different ergonomics

The same canu config was run **inside** (devcontainer, Apptainer, `-profile singularity`, offline SIF
cache) and **outside** (host Docker, `-profile standard`, local EPI2ME images):

| | consensus md5 | result |
|---|---|---|
| inside (Apptainer) | `2b78d8db…7538c` | 5,652 ✓ |
| outside (host Docker) | `2b78d8db…7538c` | 5,652 ✓ |
| EPI2ME reference | `2b78d8db…7538c` | 5,652 ✓ |

**Byte-identical.** The runtime does not affect the assembly — it's fixed by (workflow version +
container images + reads + params). So choose by ergonomics, not correctness:

- **Inside (recommended for this repo):** reproducible + offline (baked SIF cache) + firewalled
  (safe for yolo Claude) + no host pollution. Cost: one-time devcontainer build + the Apptainer
  nesting setup.
- **Outside:** simplest *if* you already have Docker + nextflow + seqkit and don't need the sandbox;
  it pulls images/workflow and writes work dirs on the host. Fine for a quick one-off on a trusted
  workstation. See README "Running outside the container".

## 6. Recommendation

`clone_validate.sh` now **defaults to canu** and has an **AUTO** mode that does the data-driven sizing
per sample (peak → window + per-sample `approx_size` via a generated sample sheet):

```bash
./clone_validate.sh example_rawdata runs/cv auto      # per-sample peak sizing + canu (the default)
```
Equivalent manual form (one sample): `estimate_length_peak.sh <reads> --report-only` → feed
`PEAK LO HI` as `approx_size min_len … max_len`. Critical: the **assembler (canu)**. Helpful: the
peak-derived window + Q20 (clean consensus + correct per-sample `approx_size`). Avoid flye on RBK
full-length plasmid reads. **Validated 2026-06-21:** AUTO on a 2-barcode run → both samples
`Completed successfully / 1 contig / 5,652 bp`.

## 7. Reproduce
The factorial driver + per-run logs live under the throwaway experiment container; the key commands
are the two above plus `--assembly_tool flye` to see the SIGFPE. Flye logs:
`work/*/.command.err` → grep `min-ovlp|SIGFPE|Reads N50`.
