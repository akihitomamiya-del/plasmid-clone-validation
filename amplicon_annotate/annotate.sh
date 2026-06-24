#!/usr/bin/env bash
#
# annotate.sh -- pLannotate-style BLAST annotation of amplicon consensuses
#                + a combined HTML report. The "annotation" half of the amplicon
#                pipeline (Stages 3-4 in docs/amplicon_plan.md). Runs INSIDE the
#                runtime image (Apptainer + the baked plannotate / wf-clone-
#                validation SIFs). amplicon_validate.sh calls it after the
#                wf-amplicon run; you can also run it standalone on any
#                all-consensus-seqs.fasta.
#
# Usage:
#   annotate.sh <consensus.fasta> <out_dir> [params.json] [versions.txt] [wf_amplicon_report.html]
#
# Stage 3: split the multi-record FASTA -> one <record>.final.fasta per record,
#          then run run_plannotate.py --linear (our patched copy) in the
#          plannotate SIF against the bundled Default DBs (SnapGene/Swiss-Prot/
#          fpbase/Rfam) -> per-record bed/gbk/feature_table + plannotate_report.json.
# Stage 4: combined_report.py in the wf-clone-validation SIF -> one HTML with a
#          per-sample linear feature map + annotation table.
# Stage 5: (optional, only if the wf-amplicon report is passed as arg 5) splice the
#          annotation section into THAT report -> one combined report = the usual
#          wf-amplicon report with the annotation added. Pure-stdlib merge_report.py
#          (host python3, or the wf-clone-validation SIF as a fallback).
#
# All BLAST databases are baked in the SIF -- no network access is used.
#
set -euo pipefail

CONSENSUS="${1:?usage: annotate.sh <consensus.fasta> <out_dir> [params.json] [versions.txt] [wf_amplicon_report.html]}"
OUT="${2:?usage: annotate.sh <consensus.fasta> <out_dir> [params.json] [versions.txt] [wf_amplicon_report.html]}"
PARAMS_IN="${3:-}"; VERSIONS_IN="${4:-}"; BASE_REPORT="${5:-}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$CONSENSUS" ]] || { echo "ERROR: consensus FASTA not found: $CONSENSUS" >&2; exit 1; }
command -v apptainer >/dev/null 2>&1 || { echo "ERROR: apptainer not on PATH (run inside the runtime image)" >&2; exit 1; }
mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"

SIF_DIR="${NXF_SINGULARITY_CACHEDIR:-/opt/sif-cache}"
PLAN_SIF="$(ls "$SIF_DIR"/ontresearch-plannotate-*.img 2>/dev/null | head -1 || true)"
CV_SIF="$(ls "$SIF_DIR"/ontresearch-wf-clone-validation-*.img 2>/dev/null | head -1 || true)"
GLUE="${NXF_HOME:-/opt/nextflow}/assets/epi2me-labs/wf-clone-validation/bin"
[[ -f "$PLAN_SIF" ]] || { echo "ERROR: plannotate SIF not found in $SIF_DIR" >&2; exit 1; }
[[ -f "$CV_SIF"   ]] || { echo "ERROR: wf-clone-validation SIF not found in $SIF_DIR" >&2; exit 1; }
[[ -d "$GLUE"     ]] || { echo "ERROR: workflow_glue not found at $GLUE" >&2; exit 1; }

WORK="$OUT/_work"; rm -rf "$WORK"; mkdir -p "$WORK/assemblies" "$WORK/glue" "$WORK/out" "$WORK/.mpl" "$WORK/.cache"

echo "== amplicon_annotate =="
echo "consensus=$CONSENSUS  out=$OUT"
echo "plannotate=$(basename "$PLAN_SIF")  cloneval=$(basename "$CV_SIF")"

# --- params / versions for the report header (synthesize minimal if absent) ---
PARAMS="$WORK/params.json"; VERSIONS="$WORK/versions.txt"
if [[ -n "$PARAMS_IN"   && -f "$PARAMS_IN"   ]]; then cp "$PARAMS_IN"   "$PARAMS";   else echo '{}' > "$PARAMS"; fi
if [[ -n "$VERSIONS_IN" && -f "$VERSIONS_IN" ]]; then cp "$VERSIONS_IN" "$VERSIONS"; else printf 'plannotate,1.2.2\n' > "$VERSIONS"; fi

# --- patched glue overlay: the original workflow_glue + our run_plannotate.py ---
cp -a "$GLUE"/. "$WORK/glue/"
cp "$HERE/run_plannotate.py" "$WORK/glue/workflow_glue/run_plannotate.py"

# --- 1) split the multi-record consensus into one <record>.final.fasta each ---
#     run_plannotate reads only the first record per file and strips ".final".
awk -v d="$WORK/assemblies" '
  /^>/ { name=substr($1,2); sub(/[ \t].*/,"",name); f=d"/"name".final.fasta" }
  { print > f }
' "$CONSENSUS"
n=$(ls -1 "$WORK/assemblies"/*.final.fasta 2>/dev/null | wc -l)
(( n > 0 )) || { echo "ERROR: no FASTA records found in $CONSENSUS" >&2; exit 1; }
echo "Stage 3: annotating $n consensus record(s) with pLannotate (linear)..."

# --- 2) Stage 3: run_plannotate.py --linear in the plannotate SIF ---
apptainer exec --containall --no-home --pwd "$WORK/out" \
  --bind "$WORK" --bind "$WORK/glue":/glue:ro \
  --env PYTHONPATH=/glue --env MPLCONFIGDIR="$WORK/.mpl" \
  --env XDG_CACHE_HOME="$WORK/.cache" \
  "$PLAN_SIF" python -m workflow_glue.run_plannotate \
    --sequences "$WORK/assemblies" --database Default --linear

[[ -f "$WORK/out/plannotate_report.json" ]] || { echo "ERROR: Stage 3 produced no plannotate_report.json" >&2; exit 1; }

cp "$WORK/out"/*.annotations.bed "$WORK/out"/*.annotations.gbk \
   "$WORK/out"/feature_table.txt "$WORK/out"/plannotate_report.json \
   "$OUT/" 2>/dev/null || true

# --- 3) Stage 4: combined_report.py in the wf-clone-validation SIF ---
echo "Stage 4: building the annotation HTML report..."
REPORT="$OUT/amplicon-annotation-report.html"
apptainer exec --containall --no-home --pwd "$WORK/out" \
  --bind "$WORK" --bind "$OUT" --bind "$HERE":/scripts:ro --bind "$GLUE":/glue:ro \
  --env PYTHONPATH=/glue --env MPLCONFIGDIR="$WORK/.mpl" \
  --env XDG_CACHE_HOME="$WORK/.cache" \
  "$CV_SIF" python /scripts/combined_report.py \
    --plannotate_json "$WORK/out/plannotate_report.json" \
    --params "$PARAMS" --versions "$VERSIONS" \
    --output "$REPORT"

[[ -f "$REPORT" ]] || { echo "ERROR: Stage 4 produced no report" >&2; exit 1; }
rm -rf "$WORK"

# --- 4) Stage 5 (optional): splice the annotation into the wf-amplicon report ---
#     Produces ONE combined report. merge_report.py is pure stdlib, so prefer the
#     host python3; fall back to python3 in the wf-clone-validation SIF if absent.
MERGED=""
if [[ -n "$BASE_REPORT" ]]; then
    if [[ -f "$BASE_REPORT" ]]; then
        echo
        echo "Stage 5: merging the annotation into the wf-amplicon report..."
        MERGED="$OUT/amplicon-report-with-annotation.html"
        if command -v python3 >/dev/null 2>&1; then
            python3 "$HERE/merge_report.py" \
                --base "$BASE_REPORT" --annotation "$REPORT" --output "$MERGED"
        else
            BASE_DIR="$(cd "$(dirname "$BASE_REPORT")" && pwd)"; BASE_BN="$(basename "$BASE_REPORT")"
            apptainer exec --containall --no-home --pwd "$OUT" \
              --bind "$OUT" --bind "$BASE_DIR":/base:ro --bind "$HERE":/scripts:ro \
              "$CV_SIF" python /scripts/merge_report.py \
                --base "/base/$BASE_BN" --annotation "$REPORT" --output "$MERGED"
        fi
        [[ -f "$MERGED" ]] || { echo "WARNING: Stage 5 produced no combined report (standalone annotation report is intact)." >&2; MERGED=""; }
    else
        echo "WARNING: wf-amplicon report not found ($BASE_REPORT) -- skipping the combined report." >&2
    fi
fi

echo
echo "== annotation outputs =="
if [[ -n "$MERGED" ]]; then
    echo "  combined report : $MERGED   <- wf-amplicon report + annotation"
fi
echo "  annotation report: $REPORT"
echo "  feature table   : $OUT/feature_table.txt"
echo "  per-record files: $OUT/<sample>.annotations.{bed,gbk}, plannotate_report.json"
