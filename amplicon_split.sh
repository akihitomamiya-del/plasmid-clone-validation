#!/usr/bin/env bash
#
# amplicon_split.sh
# -----------------
# Reference-free read binning for the single-barcode / multiple-amplicon case (Mode B).
# Given ONE barcode's reads (several distinct-locus PCR amplicons pooled in one tube), it splits
# them into one bin per amplicon by ALL-VS-ALL read overlap -- no reference needed -- so each
# amplicon can then be assembled de-novo separately (wf-amplicon keeps only ONE consensus per
# sample, so a mixed barcode would otherwise collapse to a single product).
#
# This is the reference-FREE variant of Mode B's "B2" (docs/amplicon_plan.md §3): instead of
# binning reads by mapping to a reference, bin them by how they overlap each other.
#
# Method:  seqkit length-filter -> minimap2 -x ava-ont (in the wf-amplicon SIF) -> union-find
#   connected components (two reads are linked when they share an overlap >= MIN_OVERLAP bp).
#   Components with >= MIN_READS reads are emitted as clusters; smaller components and reads that
#   overlap nothing (fragments) are dropped and reported. A single-amplicon barcode yields ONE
#   cluster (all reads) -- so running this is safe even when there's only one product.
#
# CAVEAT: reliable only for DISTINCT-locus amplicons -- reads from different products must not
#   overlap. Amplicons sharing an identical stretch longer than MIN_OVERLAP will merge into one
#   cluster (use reference mode, REF=, for those). Validated: barcode09 (3.2 kb) + barcode39
#   (1.6 kb) mixed -> 2 clean clusters, 0 cross-amplicon overlaps, both recovered at 100% identity.
#
# Usage:
#   ./amplicon_split.sh <reads.fastq[.gz]> <out_dir> [min_reads] [min_overlap] [min_len]
#     min_reads    default 40   (a cluster must have >= this many reads to count as an amplicon;
#                                matches wf-amplicon's own min_n_reads floor)
#     min_overlap  default 400  (bp; the read-overlap length required to link two reads)
#     min_len      default 300  (bp; drop reads shorter than this before clustering -- fragments)
#   Writes <out_dir>/cluster01.fastq.gz, cluster02.fastq.gz, ... (largest first). FASTQ headers are
#   preserved (so medaka's auto basecaller-model detection still works downstream).
#
set -euo pipefail

READS="${1:?usage: amplicon_split.sh <reads.fastq[.gz]> <out_dir> [min_reads] [min_overlap] [min_len]}"
OUT="${2:?usage: amplicon_split.sh <reads.fastq[.gz]> <out_dir> [min_reads] [min_overlap] [min_len]}"
MIN_READS="${3:-40}"; MIN_OVL="${4:-400}"; MIN_LEN="${5:-300}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$READS" ]] || { echo "ERROR: reads not found: $READS" >&2; exit 1; }
command -v seqkit    >/dev/null 2>&1 || { echo "ERROR: seqkit not on PATH" >&2; exit 1; }
command -v apptainer >/dev/null 2>&1 || { echo "ERROR: apptainer required (wf-amplicon SIF provides minimap2)" >&2; exit 1; }
command -v python3   >/dev/null 2>&1 || { echo "ERROR: python3 required" >&2; exit 1; }
SIF_DIR="${NXF_SINGULARITY_CACHEDIR:-/opt/sif-cache}"
WFSIF="$(ls "$SIF_DIR"/ontresearch-wf-amplicon-*.img 2>/dev/null | head -1 || true)"
[[ -f "$WFSIF" ]] || { echo "ERROR: wf-amplicon SIF not found in $SIF_DIR" >&2; exit 1; }

mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"
WORK="$OUT/.split_work"; rm -rf "$WORK"; mkdir -p "$WORK"
THREADS="$(nproc 2>/dev/null || echo 4)"; (( THREADS > 8 )) && THREADS=8

# 1) drop tiny fragments (they can't form real overlaps and just add noise)
seqkit seq -m "$MIN_LEN" "$READS" -o "$WORK/reads.fastq.gz" 2>/dev/null
nreads="$(seqkit stats -T "$WORK/reads.fastq.gz" 2>/dev/null | awk 'NR==2{print $4+0}')"
echo "amplicon_split: $nreads reads >= ${MIN_LEN}bp; all-vs-all overlap (minimap2 ava-ont)..."
(( nreads >= MIN_READS )) || { echo "amplicon_split: < $MIN_READS reads -- emitting all as cluster01." >&2
    cp "$WORK/reads.fastq.gz" "$OUT/cluster01.fastq.gz"; rm -rf "$WORK"; exit 0; }

# 2) all-vs-all overlap inside the wf-amplicon SIF (minimap2)
apptainer exec --bind "$WORK" "$WFSIF" bash -lc \
  "minimap2 -x ava-ont -t$THREADS '$WORK/reads.fastq.gz' '$WORK/reads.fastq.gz' 2>/dev/null > '$WORK/ovl.paf'"

# 3) cluster reads by connected components -> one id list per cluster
seqkit seq -ni "$WORK/reads.fastq.gz" > "$WORK/all.ids"
python3 - "$WORK/ovl.paf" "$WORK/all.ids" "$WORK" "$MIN_READS" "$MIN_OVL" <<'PY'
import sys
from collections import defaultdict
paf, allids, work, min_reads, min_ovl = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), int(sys.argv[5])
parent = {}
def find(x):
    parent.setdefault(x, x); r = x
    while parent[r] != r: r = parent[r]
    while parent[x] != r: parent[x], x = r, parent[x]
    return r
def union(a, b):
    ra, rb = find(a), find(b)
    if ra != rb: parent[ra] = rb
nodes = [l.strip() for l in open(allids) if l.strip()]
for n in nodes: find(n)                       # seed singletons
for line in open(paf):
    f = line.split('\t')
    if len(f) < 11: continue
    q, t, aln = f[0], f[5], int(f[10])
    if q != t and aln >= min_ovl: union(q, t)
comp = defaultdict(list)
for n in nodes: comp[find(n)].append(n)
clusters = sorted((c for c in comp.values() if len(c) >= min_reads), key=len, reverse=True)
dropped = sum(len(c) for c in comp.values() if len(c) < min_reads)
for i, c in enumerate(clusters, 1):
    with open(f"{work}/cluster{i:02d}.ids", "w") as fh:
        fh.write("\n".join(c) + "\n")
print(f"amplicon_split: {len(clusters)} cluster(s) >= {min_reads} reads "
      f"(sizes {[len(c) for c in clusters]}); {dropped} reads dropped (small/unlinked).",
      file=sys.stderr)
PY

# 4) extract each cluster's reads -> cluster0N.fastq.gz
shopt -s nullglob
i=0
for idf in "$WORK"/cluster*.ids; do
    i=$((i + 1))
    seqkit grep -f "$idf" "$WORK/reads.fastq.gz" -o "$OUT/$(printf 'cluster%02d' "$i").fastq.gz" 2>/dev/null
done
if (( i == 0 )); then
    echo "amplicon_split: no cluster reached $MIN_READS reads -- emitting all reads as cluster01." >&2
    cp "$WORK/reads.fastq.gz" "$OUT/cluster01.fastq.gz"; i=1
fi
rm -rf "$WORK"
echo "amplicon_split: wrote $i cluster fastq(s) -> $OUT/cluster*.fastq.gz"
