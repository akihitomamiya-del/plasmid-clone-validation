# Testing the Arabidopsis annotation — outside the firewall

This is the **host-side** test runbook for the Arabidopsis annotation feature (branch
`feature/amplicon-arabidopsis-annotation`). Run it on a **networked machine with Docker**
(the same kind of host you use to build/publish the runtime image). It exists because the
two things that make this feature real **cannot be tested inside the sandbox**:

- the sandbox has **no Docker daemon** → it can't build the image, and
- the egress firewall **blocks Ensembl/TAIR/UniProt** → it can't fetch the real proteome.

Inside the container the integration was validated only with a *synthetic* one-protein DB.
The stages below validate the **real** DB build and the **real** image build, in increasing
cost — do them in order and stop to fix anything that fails before the expensive image build.

> Goal end-state (the choice you made): once these pass, tag a release so CI bakes the DB
> into the published `:latest`, and the PI just pulls it. The tag step is Stage 4.

---

## Prerequisites (host)

- Docker (with enough disk: the runtime image is ~6 GB), `git`.
- Network egress to GitHub, Docker Hub, and **Ensembl Plants** (`ftp.ensemblgenomes.org`
  or the `ftp.ebi.ac.uk` mirror).
- For *running* the built image (Stages 2b/3): `/dev/fuse`, and the one-time host AppArmor
  profile — `sudo bash .devcontainer/setup-host-apparmor.sh` (see `docs/host_userns_prereq.md`).
- `diamond` is **not** required on the host — `build_arabidopsis_db.sh` will fetch a matching
  static binary if it's missing, and the Dockerfile installs one during the image build.

```bash
git clone <repo> && cd plasmid-clone-validation
git checkout feature/amplicon-arabidopsis-annotation
```

---

## Stage 1 — DB builder smoke test (fast, ~2–5 min, no image build)

Proves the Ensembl fetch + defline normalisation + diamond build all work, before you spend
a multi-GB image build on them.

```bash
./build_arabidopsis_db.sh arabidopsis_db          # default: Ensembl Plants release 63
```

**Expect / check:**

```bash
ls -la arabidopsis_db/                              # arabidopsis.dmnd + arabidopsis.csv present
n=$(($(wc -l < arabidopsis_db/arabidopsis.csv) - 1)); echo "proteins: $n"   # ~27,000 (longest isoform/gene)
head -3 arabidopsis_db/arabidopsis.csv              # header sseqid,Feature,Description
grep -i -m1 AT1G01010 arabidopsis_db/arabidopsis.csv   # -> AT1G01010,NAC001,NAC domain-containing protein 1
```

- [ ] `arabidopsis.dmnd` and `arabidopsis.csv` both exist.
- [ ] protein count is in the tens of thousands (not 0, not a handful).
- [ ] the CSV is `AGI,symbol,function` and a spot-checked locus resolves to a sane gene/function.

**If it fails:** almost always the Ensembl release/filename. Re-run with a different release,
e.g. `./build_arabidopsis_db.sh arabidopsis_db --release 58`. (The image build takes the same
`--build-arg ARAB_ENSEMBL_RELEASE=…` — note whichever release works here.)

---

## Stage 2 — real annotation on real data (the biology proof)

Now confirm the DB actually improves the annotation. Two ways; 2a is lightest.

### 2a. Re-annotate one or more existing consensuses (needs apptainer + the plannotate SIF)

If this host has `apptainer` and the plannotate SIF (e.g. you ran the pipeline here before, or
have `/opt/sif-cache`), point `ARAB_DB` at the Stage-1 output and re-annotate — **no reassembly,
no image build:**

```bash
ARAB_DB="$PWD/arabidopsis_db" ./amplicon_annotate/annotate.sh \
    <some>/all-consensus-seqs.fasta  out_arab
cat out_arab/feature_table.txt
```

### 2b. Or run it through a built runtime image (after Stage 3)

```bash
ARAB_DB=/opt/pcv/arabidopsis_db amplicon_validate.sh <raw_dir> <out_dir>   # inside the image
```

**Expect / check (the whole point of the feature):**

- [ ] `feature_table.txt` has an **`Accession`** column populated with **AGI loci** (`AT#G#####`)
      for `Database=arabidopsis` rows; `Feature` = gene symbol; `Description` = function.
- [ ] the `.gbk` for an Arabidopsis hit shows `/label="<SYM> (AT#G#####)"` and `/database="arabidopsis"`.
- [ ] **improvement vs the SwissProt-only baseline** — e.g. on the MT260625 set:
      barcodes that were previously *vector-only* (e.g. `barcode09`) now carry their real
      Arabidopsis gene, and the 6 that produced **no** annotation (`barcode74,75,76,77,78,83`)
      now get a gene. Quick diff:

```bash
# count barcodes that now carry an AGI locus (was 0 before):
grep -c ',arabidopsis,' out_arab/feature_table.txt
# the inserts are organellar PPR / RNA-processing genes — sanity-check a few symbols look real
cut -d, -f2,3,7 out_arab/feature_table.txt | grep -i -E 'PPR|ORRM|MTERF|CP2|CP3|RNC|pentatricopeptide' | head
```

> Heads-up on biology, not a bug: with `priority: 1` an Arabidopsis hit wins over a generic
> SwissProt/cross-species hit on the same span (that's intended — it's what replaces the
> spurious `tadA`/`Adar` labels). If you ever see it override a *legitimate* vector feature,
> drop the block to `priority: 2` in `run_plannotate.py:make_yaml` (see the plan doc).

---

## Stage 3 — the actual image build (what CI will publish)

Build the runtime image exactly as CI does, and confirm the DB is baked in. This is the
expensive step (~6 GB, pulls all SIFs + fetches the proteome). Pass the release that worked
in Stage 1.

```bash
docker build \
  -f .devcontainer/build/Dockerfile \
  --build-arg ARAB_ENSEMBL_RELEASE=63 \
  -t pcv-runtime:arabtest .
```

**Expect / check:**

- [ ] build succeeds; the Arabidopsis layer's `ls -la /opt/pcv/arabidopsis_db` (it's in the
      `RUN`) shows `arabidopsis.dmnd` + `arabidopsis.csv` in the build log.
- [ ] the DB is baked and `ARAB_DB` is set in the image:

```bash
docker run --rm --device /dev/fuse --cap-add SYS_ADMIN \
  --security-opt apparmor=pcv-apptainer pcv-runtime:arabtest \
  bash -lc 'echo "ARAB_DB=$ARAB_DB"; ls -la "$ARAB_DB"; \
            apptainer exec "$(ls /opt/sif-cache/ontresearch-plannotate-*.img)" \
              diamond dbinfo -d "$ARAB_DB/arabidopsis" | grep -iE "sequences|version"'
```

- [ ] (optional, end-to-end) run `amplicon_validate.sh` on a small barcode dir inside that
      container and confirm AGI/gene/function in the deliverables — this is the exact path the
      PI will hit, just with a locally-built instead of pulled image.

---

## Stage 4 — publish so the PI just pulls

Once Stages 1–3 pass:

```bash
git push origin feature/amplicon-arabidopsis-annotation     # (merge to main per your workflow)
git tag vX.Y.Z && git push origin vX.Y.Z                     # triggers .github/workflows/docker-publish.yml
```

CI builds `.devcontainer/build/Dockerfile` (with the Arabidopsis step) and pushes `:latest`.
Verify the published image the same way as Stage 3, then the PI's flow is just:

```
clone repo → (one-time) sudo bash .devcontainer/setup-host-apparmor.sh → Reopen in Container
  → pulls :latest (Arabidopsis baked) → ./amplicon_validate.sh <raw> <out>  → AGI + gene + function
```

> If you bumped `ARAB_ENSEMBL_RELEASE` in Stage 1, set the same value in CI — either change the
> `ARG ARAB_ENSEMBL_RELEASE` default in `.devcontainer/build/Dockerfile` or pass it as a build-arg
> in `docker-publish.yml`.

---

## Pass/fail checklist

| Stage | Pass criterion |
|---|---|
| 1 | `arabidopsis.{dmnd,csv}` built; ~tens-of-thousands proteins; CSV = AGI,symbol,function |
| 2 | real consensuses gain an `Accession` (AGI) column + `arabidopsis` features with real gene/function; previously vector-only / unannotated barcodes now annotated |
| 3 | image builds; `/opt/pcv/arabidopsis_db` baked; `ARAB_DB` set; `diamond dbinfo` reads it in-image |
| 4 | published `:latest` verified like Stage 3; PI pull-and-run produces AGI/gene/function |

## Troubleshooting

- **Ensembl 404 / connection** → wrong/old release. Try `--release 58`; or download the pep
  FASTA manually and use `build_arabidopsis_db.sh --source <file.fa.gz>` (fully offline build).
- **`diamond: not found` on the host** → the script auto-fetches a static 2.1.15 binary; if your
  host blocks that, `conda install -c bioconda diamond` or set `PLAN_SIF=/path/to/plannotate.img`.
- **DB unreadable in-image** → diamond version skew. The Dockerfile pins `DIAMOND_VERSION=2.1.15`
  to match the SIF; keep them equal (verified: a 2.1.15-built DB reads in the SIF's diamond).
- **Container won't start (apparmor)** → run the one-time `setup-host-apparmor.sh` (host prereq,
  pre-existing — not specific to this feature).

See also: `docs/arabidopsis_annotation_plan.md` (design + how it works; §9 = plasmids via `CIRCULAR`),
`docs/amplicon_annotate.md`, and `docs/reference_validation.md` (check a consensus against an intended
`.gbk`/`.fasta`).
