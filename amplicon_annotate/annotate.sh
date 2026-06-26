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
# Env:
#   CIRCULAR=1     annotate as a CIRCULAR plasmid (OMIT --linear); default = linear amplicon.
#                  Used by clone_validate.sh to annotate wf-clone-validation plasmid consensuses.
#   ARAB_DB=<dir>  also diamond-blastx vs a custom A. thaliana proteome -> AGI + gene + function
#                  (dir holding arabidopsis.dmnd + arabidopsis.csv; see below + the plan doc).
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

# Topology: by DEFAULT the input is LINEAR (amplicons / linear constructs) -> pass --linear so
# plannotate skips the circular sequence-doubling and writes a linear GenBank. Set CIRCULAR=1 to
# annotate a CIRCULAR plasmid instead: that OMITS --linear, so run_plannotate does its native
# circular (origin-spanning) annotation + a circular GenBank. Default (CIRCULAR unset) keeps
# --linear -> the amplicon path is byte-for-byte unchanged (same flag AND same log text).
LINEAR_FLAG=(--linear); TOPO="linear"
if [[ -n "${CIRCULAR:-}" ]]; then LINEAR_FLAG=(); TOPO="circular"; fi
echo "Stage 3: annotating $n consensus record(s) with pLannotate ($TOPO)..."

# --- 2) Stage 3: run_plannotate.py --linear in the plannotate SIF ---
# Optional custom Arabidopsis thaliana protein DB. If $ARAB_DB names a directory
# holding arabidopsis.dmnd + arabidopsis.csv (built offline; see
# docs/arabidopsis_annotation_plan.md), bind it read-only to /opt/arab_db and signal
# run_plannotate via $PLANNOTATE_ARAB_DB. Unset/invalid -> stock DBs only (unchanged).
ARAB_BIND=()
if [[ -n "${ARAB_DB:-}" ]]; then
  if [[ -f "$ARAB_DB/arabidopsis.dmnd" && -f "$ARAB_DB/arabidopsis.csv" ]]; then
    ARAB_ABS="$(cd "$ARAB_DB" && pwd)"
    ARAB_BIND=(--bind "$ARAB_ABS":/opt/arab_db:ro --env PLANNOTATE_ARAB_DB=/opt/arab_db)
    echo "  + Arabidopsis DB: $ARAB_ABS -> /opt/arab_db (diamond blastx; adds AGI + gene + function)"
  else
    echo "WARNING: ARAB_DB set ($ARAB_DB) but arabidopsis.dmnd/arabidopsis.csv not found there -- using stock DBs only." >&2
  fi
fi
apptainer exec --containall --no-home --pwd "$WORK/out" \
  --bind "$WORK" --bind "$WORK/glue":/glue:ro \
  ${ARAB_BIND[@]+"${ARAB_BIND[@]}"} \
  --env PYTHONPATH=/glue --env MPLCONFIGDIR="$WORK/.mpl" \
  --env XDG_CACHE_HOME="$WORK/.cache" \
  "$PLAN_SIF" python -m workflow_glue.run_plannotate \
    --sequences "$WORK/assemblies" --database Default ${LINEAR_FLAG[@]+"${LINEAR_FLAG[@]}"}

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

# --- 5) Deliverables: gather the PI-facing files into one tidy folder (+ README + zip) ---
#     COPIES only (originals under amplicon/ and annotation/ are untouched). Per-sample files
#     are named <sample>_<bp>bp.<ext>; run-level files keep descriptive names. Runs in both
#     entry modes (full pipeline and standalone annotate.sh); never fails the run on a hiccup.
DELIV_DIR=""; DELIV_ZIP=""
build_deliverables() {
    local run_root deliv amp fai samples sample bp slice main_report
    # Run-root = the user's <out>: parent of annotation/ when called from the pipeline
    # (sibling amplicon/ present); else fall back to $OUT itself (standalone annotate.sh).
    if [[ "$(basename "$OUT")" == "annotation" && -d "$(dirname "$OUT")/amplicon" ]]; then
        run_root="$(dirname "$OUT")"
    else
        run_root="$OUT"
    fi
    deliv="$run_root/deliverables"; rm -rf "$deliv"; mkdir -p "$deliv"
    amp="$run_root/amplicon"; fai="$amp/all-consensus-seqs.fasta.fai"

    bp_for() {  # $1 = sample -> length in bp (".fai" first, gbk LOCUS fallback, else NA)
        local n=""
        [[ -f "$fai" ]] && n="$(awk -v s="$1" '$1==s{print $2; exit}' "$fai")"
        [[ -z "$n" && -f "$OUT/$1.annotations.gbk" ]] && n="$(awk '/^LOCUS/{print $3; exit}' "$OUT/$1.annotations.gbk")"
        printf '%s' "${n:-NA}"
    }

    # run-level files (span all samples). Prefer the combined report; else the annotation-only one.
    main_report=""
    if [[ -n "$MERGED" && -f "$MERGED" ]]; then
        cp -f "$MERGED" "$deliv/amplicon-report-with-annotation.html"; main_report="amplicon-report-with-annotation.html"
    elif [[ -f "$REPORT" ]]; then
        cp -f "$REPORT" "$deliv/amplicon-annotation-report.html";      main_report="amplicon-annotation-report.html"
    fi
    [[ -f "$CONSENSUS" ]]             && cp -f "$CONSENSUS"             "$deliv/all-consensus-seqs.fasta"
    [[ -f "$OUT/feature_table.txt" ]] && cp -f "$OUT/feature_table.txt" "$deliv/feature_table.txt"
    [[ -n "$BASE_REPORT" && -f "$BASE_REPORT" ]] && cp -f "$BASE_REPORT" "$deliv/wf-amplicon-QC-report.html"

    # per-sample files: one {.gbk,.bed,.consensus.fasta} trio per >record in the consensus FASTA
    samples="$(awk '/^>/{n=substr($1,2); sub(/[ \t].*/,"",n); print n}' "$CONSENSUS")"
    while IFS= read -r sample; do
        [[ -n "$sample" ]] || continue
        bp="$(bp_for "$sample")"
        [[ -f "$OUT/$sample.annotations.gbk" ]] && cp -f "$OUT/$sample.annotations.gbk" "$deliv/${sample}_${bp}bp.gbk"
        [[ -f "$OUT/$sample.annotations.bed" ]] && cp -f "$OUT/$sample.annotations.bed" "$deliv/${sample}_${bp}bp.bed"
        slice="$deliv/${sample}_${bp}bp.consensus.fasta"
        awk -v s="$sample" '/^>/{keep=(substr($1,2)==s)} keep{print}' "$CONSENSUS" > "$slice"
        [[ -s "$slice" ]] || rm -f "$slice"
    done <<< "$samples"

    # README.txt: plain-text index, generated to match what actually got copied
    {
        echo "Amplicon clone validation -- deliverables"
        echo "Run output: $run_root"
        echo
        echo "START HERE"
        if [[ "$main_report" == amplicon-report-with-annotation.html ]]; then
            echo "  amplicon-report-with-annotation.html"
            echo "      *** MAIN REPORT *** wf-amplicon QC + annotation in one page. Open in a web browser."
        elif [[ -n "$main_report" ]]; then
            echo "  $main_report"
            echo "      Annotation report (the combined report was not produced). Open in a web browser."
        fi
        echo
        echo "FILES"
        [[ -f "$deliv/wf-amplicon-QC-report.html" ]] && echo "  wf-amplicon-QC-report.html   ONT wf-amplicon QC report. Web browser."
        [[ -f "$deliv/all-consensus-seqs.fasta" ]]   && echo "  all-consensus-seqs.fasta     Consensus sequence(s), one per barcode. SnapGene / text editor."
        [[ -f "$deliv/feature_table.txt" ]]          && echo "  feature_table.txt            All annotated features (CSV). Excel / spreadsheet."
        echo
        echo "PER SAMPLE (barcode_lengthbp)"
        while IFS= read -r sample; do
            [[ -n "$sample" ]] || continue
            bp="$(bp_for "$sample")"
            echo "  ${sample} (${bp} bp):"
            [[ -f "$deliv/${sample}_${bp}bp.gbk" ]]            && echo "      ${sample}_${bp}bp.gbk             GenBank annotation. SnapGene / Benchling / ApE."
            [[ -f "$deliv/${sample}_${bp}bp.bed" ]]            && echo "      ${sample}_${bp}bp.bed             Feature intervals (BED). IGV / genome browsers."
            [[ -f "$deliv/${sample}_${bp}bp.consensus.fasta" ]] && echo "      ${sample}_${bp}bp.consensus.fasta  This barcode's consensus only."
        done <<< "$samples"
    } > "$deliv/README.txt"

    # single ZIP bundle for emailing (best-effort; never fail the run on this)
    local zip_path="$run_root/deliverables.zip"; rm -f "$zip_path"
    if command -v zip >/dev/null 2>&1; then
        ( cd "$run_root" && zip -q -r "deliverables.zip" "deliverables" )
    elif command -v python3 >/dev/null 2>&1; then
        ( cd "$run_root" && python3 -m zipfile -c "deliverables.zip" "deliverables" )
    else
        echo "NOTE: neither 'zip' nor python3 found -- deliverables/ folder is ready, ZIP skipped." >&2; zip_path=""
    fi
    DELIV_DIR="$deliv"; DELIV_ZIP="$zip_path"
}
build_deliverables || echo "WARNING: deliverables packaging failed; per-file outputs under $OUT are intact." >&2

echo
echo "== annotation outputs =="
if [[ -n "$MERGED" ]]; then
    echo "  combined report : $MERGED   <- wf-amplicon report + annotation"
fi
echo "  annotation report: $REPORT"
echo "  feature table   : $OUT/feature_table.txt"
echo "  per-record files: $OUT/<sample>.annotations.{bed,gbk}, plannotate_report.json"
if [[ -n "$DELIV_DIR" ]]; then
    echo
    echo "== deliverables (hand these to the PI) =="
    echo "  folder : $DELIV_DIR/   (README.txt explains every file)"
    if [[ -n "$DELIV_ZIP" ]]; then
        echo "  bundle : $DELIV_ZIP"
    fi
fi
