# Arabidopsis-aware amplicon annotation — plan & runbook

Add the **AGI locus code, gene symbol, and functional description** to every amplicon
consensus by annotating it against a custom *Arabidopsis thaliana* protein database,
on top of pLannotate's stock DBs.

> **One-line status:** done, gated behind `ARAB_DB`, **validated offline end-to-end on a real
> host** (a full `amplicon_validate.sh` raw→deliverables run against the real TAIR10 proteome)
> and **baked into the runtime image** — `ARAB_DB` defaults to `/opt/pcv/arabidopsis_db`, so the
> published image annotates with Arabidopsis by default. Also extended to **plasmids** (§9). The
> only step that must run **outside** the firewalled devcontainer is building the DB (the proteome
> download is blocked inside); for the published image CI bakes it. `build_arabidopsis_db.sh` now
> auto-fetches a version-matched diamond, so a bare networked host needs nothing pre-installed.

---

## 1. Why — the gap in the current run

From the finished `runs/MT260625_amplicon` (81 consensuses, automated analysis):

- **75/81** barcodes got any annotation; **6** got **none** despite carrying a real ORF
  (barcode74, 75, 76, 77, 78, 83).
- Only **31/75 (41%)** carry a usable gene-symbol + function. **28** have a generic
  Arabidopsis label (organism + Swiss-Prot existence level, no function); **10** are
  labelled *only* by vector/cross-species artifacts (Gateway `attB2`, E. coli `tadA`,
  *Drosophila* `Adar`) — the real insert is invisible; **14** of the protein hits are a
  bare Swiss-Prot accession with no gene name.
- **0/81** carry any **AGI locus / TAIR** identifier — there is no link from any clone to
  the Arabidopsis genome.
- The inserts are a coherent family — chloroplast/mitochondrial **PPR / RNA-processing**
  genes (`PCMP-*`, MTERF, `CP29A/31A/31B/33`, `RNC1`, `ORRM2`, …) — exactly what Swiss-Prot
  covers only sporadically. A full-length TAIR/Araport proteome with AGI codes + curated
  names closes every one of these gaps.

## 2. Why it must be built outside the container

Egress reachability test from inside the sandbox (firewall `ok`):

| Host | Result |
|---|---|
| `www.arabidopsis.org` (TAIR) | **blocked** — `No route to host` |
| `ftp.ensemblgenomes.org` / `ftp.ebi.ac.uk` (Ensembl Plants) | **blocked** |
| `rest.uniprot.org` / `ftp.uniprot.org` | **blocked** |
| `ftp.ncbi.nlm.nih.gov` / `eutils.ncbi.nlm.nih.gov` | **blocked** |
| `github.com` (control) | reachable |

DNS resolves but the connection is dropped at the network layer — an egress IP allow-list
(only GitHub/npm/Anthropic), consistent with the project's containment model. **Conclusion:
the proteome download + DB build must happen on a networked host.** The DB artifacts are
then used fully offline (diamond runs inside the pinned plannotate SIF; no network, the
firewall and `NXF_OFFLINE=true` are unaffected).

## 3. Data source

**Primary: Ensembl Plants `Arabidopsis_thaliana.TAIR10.pep.all.fa.gz`** — the one file that
carries all three fields in every defline:

```
>AT1G01010.1 pep chromosome:TAIR10:1:3631:5899:1 gene:AT1G01010 transcript:AT1G01010.1 \
 gene_biotype:protein_coding gene_symbol:NAC001 description:NAC domain-containing protein 1 [Source:UniProtKB/Swiss-Prot;Acc:Q0WV96]
```

- **AGI locus** = `gene:` value (`AT1G01010`)
- **gene symbol** = `gene_symbol:` (`NAC001`; absent for un-named genes → we fall back to the AGI)
- **function** = text after `description:` minus the trailing `[Source:…]`

`gene_symbol`/`description` coverage is partial (curated genes only). To fill gaps with
authoritative TAIR names, see the **TAIR-join fallback** in §7.

---

## 4. Runbook

### Step 1 — build the DB (on a networked host, once)

```bash
# in a clone of this repo, on a host with internet + diamond (or apptainer + the plannotate SIF):
./build_arabidopsis_db.sh arabidopsis_db            # downloads Ensembl release 63 by default
#   --release 58       # use a specific Ensembl Plants release
#   --source FILE.fa.gz # use an already-downloaded proteome (fully offline build)
#   --keep-isoforms    # keep every splice isoform (default: one longest protein per gene)
```

Produces:

```
arabidopsis_db/arabidopsis.dmnd   # diamond protein DB (defline 1st token = AGI locus)
arabidopsis_db/arabidopsis.csv    # header: sseqid,Feature,Description = AGI, symbol, function
```

`diamond` is located in this order: (1) a host `diamond` on `PATH`; (2) else the plannotate
SIF's diamond when `PLAN_SIF=/path/to/ontresearch-plannotate-*.img` (or one under
`$NXF_SINGULARITY_CACHEDIR` / `/opt/sif-cache`) is available; (3) else a **version-matched static
binary the script auto-fetches** (`DIAMOND_VERSION`, default `2.1.15` to match the SIF so the
baked `.dmnd` stays readable there). So on a bare networked host with neither diamond nor a SIF
it just works. Self-checks (`diamond dbinfo`, CSV head) run automatically.

### Step 2 — move the DB to the pipeline host

Copy the `arabidopsis_db/` directory to the machine that runs the pipeline (the same place
you run `amplicon_validate.sh`). It is ~tens of MB. No other change is needed — the pipeline
code already supports it.

### Step 3 — run the annotation with the DB

```bash
ARAB_DB=/path/to/arabidopsis_db ./amplicon_validate.sh <raw_dir> <out_dir>
# or re-annotate an existing consensus set without re-assembling:
ARAB_DB=/path/to/arabidopsis_db ./amplicon_annotate/annotate.sh \
    <out_dir>/amplicon/all-consensus-seqs.fasta <out_dir>/annotation \
    <out_dir>/amplicon/params.json <out_dir>/amplicon/versions.txt \
    <out_dir>/amplicon/wf-amplicon-report.html
```

That's it. `ARAB_DB` unset → the pipeline behaves exactly as today (stock DBs only).

## 5. What changes in the output

When `ARAB_DB` is set, each amplicon is additionally searched (`diamond blastx`) against the
Arabidopsis proteome, and:

- **`feature_table.txt`** gains an **`Accession`** column = the **AGI locus** (e.g. `AT1G01010`)
  for Arabidopsis features; `Feature` = gene symbol, `Description` = function,
  `Database` = `arabidopsis`.
- **`<barcode>.annotations.gbk`** features from the Arabidopsis DB carry the AGI in the label,
  e.g. `/label="NAC001 (AT1G01010)"` with `/database="arabidopsis"`.
- **The HTML report** shows the `Accession` column in the feature table, an `AGI/accession`
  line in the linear-map hover, and a distinct colour for `arabidopsis` features.

Because the Arabidopsis DB is given `priority: 1`, a genuine Arabidopsis hit **outscores** the
generic Swiss-Prot / cross-species hit over the same span — so the inserts that were
previously labelled only `tadA`/`Adar` get their real gene, and the 6 zero-feature barcodes
get annotated.

### Validation already done (offline)
Using a synthetic single-entry DB built from barcode09's own 472-aa ORF (`AT1G09090 / TESTPPR9`),
the previously vector-only barcode09 was re-annotated and the AGI + gene + function appeared in
`feature_table.txt`, the `.gbk` label, **and** the HTML report; a control run with `ARAB_DB`
unset produced byte-identical schema to the current pipeline (no `Accession` column, no
arabidopsis features). The `build_arabidopsis_db.sh` normaliser was validated on a synthetic
Ensembl-format proteome (isoform-collapse to longest, symbol→AGI fallback, CSV comma-quoting).

---

## 6. How it works (for maintainers)

All changes are gated on `ARAB_DB` / `PLANNOTATE_ARAB_DB`; with them unset, behaviour is
unchanged.

| File | Change |
|---|---|
| `amplicon_annotate/annotate.sh` | Stage 3: if `$ARAB_DB` holds `arabidopsis.dmnd`+`arabidopsis.csv`, bind it read-only to `/opt/arab_db` and pass `--env PLANNOTATE_ARAB_DB=/opt/arab_db`. |
| `amplicon_annotate/run_plannotate.py` `make_yaml()` | If `$PLANNOTATE_ARAB_DB` is set, append an `arabidopsis:` diamond block to the generated `plannotate.yaml` (method `diamond` ⇒ `diamond blastx`; `priority 1`; `--id 40`; details CSV at `/opt/arab_db/arabidopsis.csv`). |
| `amplicon_annotate/run_plannotate.py` `clean_results()` | In Arabidopsis mode, restore `sseqid` → an **`Accession`** column (the AGI locus). |
| `amplicon_annotate/run_plannotate.py` `create_gbk()` | In Arabidopsis mode, fold the AGI into the GenBank `/label` for `db=="arabidopsis"` features. |
| `amplicon_annotate/combined_report.py` | `arabidopsis` track colour + conditional `AGI/accession` hover line. |

Key facts behind the design (verified live in the SIF):
- The pipeline uses the **runtime-generated `plannotate.yaml`**, *not* the SIF's bundled
  `databases.yml` — so the DB is added in `make_yaml()`, not by editing the SIF.
- pLannotate's only translated-search path is `method: diamond` → `diamond blastx`; a protein DB
  **must** be a `.dmnd` (NCBI `blastx`/`tblastn` exist in the SIF but are never called).
- A diamond hit's `sseqid` (first defline token, after an optional `sp|…|…` split) is the join
  key into the details CSV (`sseqid,Feature,Description`). That is why the build script makes the
  **AGI the first token** and writes a matching CSV.

## 7. Tuning & options

- **Permanent default (no env var) — DONE.** `.devcontainer/build/Dockerfile` builds the DB at
  image-build time into `/opt/pcv/arabidopsis_db` (a host diamond installed for that one layer)
  and sets `ENV ARAB_DB=/opt/pcv/arabidopsis_db`, so the published image annotates with
  Arabidopsis by default — still offline; the DB is bind-mounted, no plannotate-SIF rebuild.
  Override per-run with `ARAB_DB=…`; for the stock-only baseline run with `env -u ARAB_DB`.
  Release pin: `--build-arg ARAB_ENSEMBL_RELEASE=63` (keep it equal to whatever release you
  validated with `build_arabidopsis_db.sh`).
- **Sensitivity (`--id`)**: the block uses `--id 40` (permissive — catches indel-degraded ONT
  ORFs). Raise toward `50–60` to reduce paralog hits; lower to catch more-divergent homologs.
- **Frameshift-aware** (helps the largest PPR genes, where ONT indels break frame): add
  `--frameshift 15` to the `arabidopsis` `parameters` in `make_yaml()`. Left off by default
  pending validation that pLannotate's hit-table parsing handles frameshifted alignments.
- **`priority`**: `1` lets Arabidopsis win over Swiss-Prot on overlapping spans. If you ever see
  it override a legitimate vector feature, set it to `2` (fills only what Swiss-Prot doesn't claim).
- **Isoforms**: default keeps one longest protein per gene (bare AGI display). `--keep-isoforms`
  keeps all splice forms (ids become `AT#G#####.N`).
- **TAIR-join fallback** (authoritative symbols/functions where Ensembl left them blank): build
  AGI→symbol and AGI→function maps from TAIR `gene_aliases*.txt` (TSV: `locus_name,symbol,full_name`)
  and `Araport11_functional_descriptions*.txt` (TSV keyed by `AGI.model`), available without a TAIR
  login from the TAIR Zenodo deposits, and rewrite the deflines before `diamond makedb`. (The
  build script's normaliser is structured so this is a drop-in pre-step.)

## 8. Caveats

- Confirm the exact Ensembl Plants release/filename before an unattended build (release 63 is
  current as of 2026-06; 58 is a valid archive). The pep filename itself has no release number.
- `gene_symbol`/`description` coverage in Ensembl is partial; un-named genes display the AGI as
  the gene symbol until you apply the TAIR-join.
- These are same-organism, full-length cloned CDSs, so real hits are high-identity; `--id 40` is
  a safety margin, not a necessity. Spurious paralog hits, if any, are the main thing to watch
  when you first inspect a real run.

---

## 9. Plasmids too (`CIRCULAR` mode)

The same Arabidopsis DB now annotates **plasmid** assemblies, not just amplicons. The plasmid
pipeline (`clone_validate.sh` → wf-clone-validation) runs pLannotate *inside* the Nextflow
workflow with stock DBs only, so Arabidopsis is added as a **post-step** (the locked
"wrapper, not a fork" pattern), mirroring the amplicon path:

- `amplicon_annotate/annotate.sh` gained an opt-in **`CIRCULAR=1`** that omits `--linear`, so
  `run_plannotate` does its native circular (origin-spanning) annotation and writes a **circular**
  GenBank. Default (unset) keeps `--linear` ⇒ the amplicon path is byte-for-byte unchanged.
- `clone_validate.sh` gained an **`ARAB_DB`-gated** (and Apptainer-gated) post-step that, after
  the workflow, re-annotates the assembled `<out>/cloneval/*.final.fasta` with `CIRCULAR=1` into a
  separate `<out>/annotation/` dir (no collision with the workflow's own `feature_table.txt`).
  Complete **no-op when `ARAB_DB` is unset** — existing plasmid runs are unchanged.

```bash
ARAB_DB=/path/to/arabidopsis_db ./clone_validate.sh <raw_dir> <out_dir> auto
#   -> <out_dir>/cloneval/      wf-clone-validation assembly + its own stock annotation
#   -> <out_dir>/annotation/    Arabidopsis-aware: feature_table.txt (AGI), *.annotations.gbk, report
```

Validated: `CIRCULAR=1` on the example consensus yields a `circular` GenBank plus the AGI/gene
annotation (`RPF3`/AT1G62930, `CRS1`/AT5G16180); the default path still passes `--linear`. The
remaining maintainer check is a full plasmid raw→assembly→annotation run.

> Related: to **check** an assembled clone against an intended sequence (rather than discover
> features), see [`reference_validation.md`](reference_validation.md) — `validate_against_reference.sh`
> flags substitutions / indels / truncations vs a user `.gbk`/`.fasta`.
