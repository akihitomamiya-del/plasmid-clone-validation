#!/usr/bin/env bash
#
# validate_against_reference.sh
# -----------------------------
# "Does my clone match the intended construct?" -- align a pipeline consensus FASTA
# to a USER-SUPPLIED reference (.gbk or .fasta) and flag every discrepancy
# (substitutions, insertions, deletions, 5'/3' truncations), noting whether each
# one lands inside an annotated reference feature.
#
# This is the reference-comparison companion to amplicon_annotate/annotate.sh:
# where annotate.sh DISCOVERS features de-novo (pLannotate BLAST), this script
# CHECKS the consensus against a construct map you already have in hand.
#
# Pipeline (every heavy tool runs inside the baked SIFs via `apptainer exec`;
# nothing is fetched from the network):
#   1. If the reference is GenBank, dump its ORIGIN to FASTA (variant_parser.py
#      --gbk2fasta) so the aligner has a target.
#   2. minimap2 -a --cs -x asm10  <ref.fasta> <consensus.fasta>   (wf-amplicon SIF).
#   3. variant_parser.py --reference <ref> --sam aln.sam --out <out_dir>  (a python
#      SIF) -> variants_vs_reference.csv + variant_summary.txt.
#
# Usage:
#   ./validate_against_reference.sh <consensus.fasta> <reference.gbk|fasta> <out_dir>
#
# Env:
#   NXF_SINGULARITY_CACHEDIR  directory holding the baked SIFs (default /opt/sif-cache)
#
# On a Docker-only host (no Apptainer) this no-ops with a clear message -- the heavy
# stages are Apptainer-only, matching the rest of the repo.
#
# Examples:
#   ./validate_against_reference.sh runs/amp/amplicon/all-consensus-seqs.fasta \
#       my_construct.gbk runs/amp/reference_check
#   ./validate_against_reference.sh clone.fasta intended.fasta out/

set -euo pipefail
usage() { awk 'NR==1{next} /^#/{sub(/^# ?/,"");print;next} {exit}' "$0"; }

if [[ $# -lt 1 || "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then usage; exit 0; fi

CONSENSUS="${1:?usage: validate_against_reference.sh <consensus.fasta> <reference.gbk|fasta> <out_dir>}"
REFERENCE="${2:?usage: validate_against_reference.sh <consensus.fasta> <reference.gbk|fasta> <out_dir>}"
OUT="${3:?usage: validate_against_reference.sh <consensus.fasta> <reference.gbk|fasta> <out_dir>}"

# Resolve our own location so the parser is found whether launched from the repo
# root or from /opt/pcv inside the image (same idiom as annotate.sh's HERE).
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARSER_DIR="$HERE/amplicon_annotate"
PARSER="$PARSER_DIR/variant_parser.py"
[[ -f "$PARSER" ]] || { echo "ERROR: variant_parser.py not found at $PARSER" >&2; exit 1; }

# Fatal input checks (mirror annotate.sh's "not found" errors).
[[ -f "$CONSENSUS" ]] || { echo "ERROR: consensus FASTA not found: $CONSENSUS" >&2; exit 1; }
[[ -f "$REFERENCE" ]] || { echo "ERROR: reference not found: $REFERENCE" >&2; exit 1; }

# Apptainer drives minimap2 (and python) from the baked SIFs. Without it we cannot
# run -- but rather than fail, no-op with a clear note, the same contract the
# amplicon pipeline uses for its Apptainer-only stages on a Docker-only host.
if ! command -v apptainer >/dev/null 2>&1; then
  echo "NOTE: validate_against_reference needs Apptainer (minimap2 + python live in"
  echo "      the baked SIFs); none is on PATH, so this step is SKIPPED on this host."
  echo "      Run it inside the runtime image / devcontainer. See docs/amplicon_annotate.md."
  exit 0
fi

mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"

# Detect the SIFs (same globbing convention as annotate.sh / amplicon_split.sh).
SIF_DIR="${NXF_SINGULARITY_CACHEDIR:-/opt/sif-cache}"
WFAMP_SIF="$(ls "$SIF_DIR"/ontresearch-wf-amplicon-*.img 2>/dev/null | head -1 || true)"   # minimap2
# python (with pysam, though we parse the SAM as text) lives in BOTH the
# wf-clone-validation and plannotate SIFs -- either runs variant_parser.py.
PY_SIF="$(ls "$SIF_DIR"/ontresearch-wf-clone-validation-*.img 2>/dev/null | head -1 || true)"
[[ -n "$PY_SIF" ]] || PY_SIF="$(ls "$SIF_DIR"/ontresearch-plannotate-*.img 2>/dev/null | head -1 || true)"
[[ -f "$WFAMP_SIF" ]] || { echo "ERROR: wf-amplicon SIF (minimap2) not found in $SIF_DIR" >&2; exit 1; }
[[ -f "$PY_SIF"    ]] || { echo "ERROR: no wf-clone-validation / plannotate SIF (python) found in $SIF_DIR" >&2; exit 1; }

# Stage everything in one work dir so the Apptainer binds stay simple (annotate.sh
# does the same). Originals are untouched; outputs land in $OUT.
WORK="$OUT/_work"; rm -rf "$WORK"; mkdir -p "$WORK"
REF_EXT="$(printf '%s' "${REFERENCE##*.}" | tr '[:upper:]' '[:lower:]')"
cp "$CONSENSUS" "$WORK/consensus.fasta"
cp "$REFERENCE" "$WORK/reference.$REF_EXT"

echo "== validate_against_reference =="
echo "consensus = $CONSENSUS"
echo "reference = $REFERENCE  (type=$REF_EXT)"
echo "out       = $OUT"
echo "minimap2 SIF = $(basename "$WFAMP_SIF")"
echo "python SIF   = $(basename "$PY_SIF")"

# 1) Reference FASTA target for the aligner. GenBank -> dump ORIGIN; FASTA -> as-is.
if [[ "$REF_EXT" == "gbk" || "$REF_EXT" == "gb" || "$REF_EXT" == "genbank" ]]; then
  echo "Step 1: GenBank reference -> FASTA (ORIGIN) for the aligner..."
  apptainer exec --containall --no-home --pwd "$WORK" \
    --bind "$WORK" --bind "$PARSER_DIR":/glue:ro \
    "$PY_SIF" python /glue/variant_parser.py --gbk2fasta "$WORK/reference.$REF_EXT" \
    > "$WORK/ref.fasta"
  [[ -s "$WORK/ref.fasta" ]] || { echo "ERROR: GenBank ORIGIN produced no sequence" >&2; exit 1; }
else
  cp "$WORK/reference.$REF_EXT" "$WORK/ref.fasta"
fi

# 2) Align consensus -> reference.
#    -x asm10 (NOT map-ont): the consensus is a polished, near-finished sequence, so
#    we want ONE long colinear assembly-to-assembly alignment at high identity
#    (within ~10% divergence). map-ont is tuned for noisy raw reads and would
#    fragment / over-clip a clean consensus, manufacturing spurious "variants".
#    --cs emits the unambiguous difference string variant_parser.py walks.
echo "Step 2: minimap2 -a --cs -x asm10 (assembly-to-assembly alignment)..."
apptainer exec --containall --no-home --pwd "$WORK" --bind "$WORK" \
  "$WFAMP_SIF" bash -lc \
  "minimap2 -a --cs -x asm10 '$WORK/ref.fasta' '$WORK/consensus.fasta' 2>/dev/null > '$WORK/aln.sam'"
[[ -s "$WORK/aln.sam" ]] || { echo "ERROR: minimap2 produced no SAM" >&2; exit 1; }

# 3) Call variants + annotate feature overlap. variant_parser.py is stdlib-only
#    (parses the SAM as text), but we still run it inside the python SIF for parity
#    with annotate.sh -- binding the work dir (inputs/outputs) and the script dir as
#    /glue (PYTHONPATH), exactly like the pLannotate stage.
echo "Step 3: variant_parser.py (stdlib SAM walk + feature overlap)..."
apptainer exec --containall --no-home --pwd "$WORK" \
  --bind "$WORK" --bind "$OUT" --bind "$PARSER_DIR":/glue:ro \
  --env PYTHONPATH=/glue \
  "$PY_SIF" python /glue/variant_parser.py \
    --reference "$WORK/reference.$REF_EXT" --sam "$WORK/aln.sam" --out "$OUT"

CSV="$OUT/variants_vs_reference.csv"
SUMMARY="$OUT/variant_summary.txt"
[[ -f "$CSV" ]] || { echo "ERROR: variant_parser produced no CSV ($CSV)" >&2; exit 1; }
rm -rf "$WORK"

# One-line PASS / discrepancy headline (the per-consensus table was printed by the
# parser above). Count = CSV data rows.
NVAR=0
if [[ -f "$CSV" ]]; then NVAR=$(( $(wc -l < "$CSV") - 1 )); (( NVAR < 0 )) && NVAR=0; fi
echo
echo "== outputs =="
echo "  variants CSV : $CSV"
echo "  summary      : $SUMMARY"
echo
if (( NVAR == 0 )); then
  echo "RESULT: PASS -- consensus matches the reference (0 discrepancies flagged)."
else
  echo "RESULT: $NVAR discrepancy/ies flagged -- see $SUMMARY for per-consensus"
  echo "        counts (substitutions / indels / truncations) + identity% + verdict."
fi
