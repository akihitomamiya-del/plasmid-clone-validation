#!/usr/bin/env bash
#
# clone_validate.sh
# -----------------
# Integration "option 1" (pre-filter wrapper): select Nanopore reads by length window +
# mean Q-score, then run EPI2ME wf-clone-validation on the filtered reads.
#
# Two sizing modes:
#   * MANUAL  <approx_size> [min_len] [min_qual] [max_len]  -- one length window for all samples.
#   * AUTO    approx_size = "auto"                           -- per-sample, data-driven (no
#       hand-picked numbers): runs estimate_length_peak.sh on each barcode to find the
#       full-length read-length peak, filters that barcode to peak +/-15% (+ min Q), and feeds
#       each sample's peak as its own approx_size via a generated sample sheet.
#
# Assembler: defaults to **canu** -- validated as the robust choice for full-length plasmid reads;
# flye auto-picks a min-overlap > the read length and crashes (SIGFPE) on RBK reads. Override with
# EXTRA_NF_ARGS="--assembly_tool flye".  See docs/assembly_findings_2026-06-21.md.
#
# Steps:
#   1. select reads (length window + Q)  -- MANUAL: filter_nanopore_reads.sh (one window for all)
#                                           AUTO:   estimate_length_peak.sh per barcode (own window)
#   2. reshape into the barcodeNN/ layout that `nextflow --fastq` expects
#   3. nextflow run epi2me-labs/wf-clone-validation ...   (or print the command if nextflow isn't here)
#
# A MANUAL-only approx_size envelope guard stops wf-clone-validation's own length bounds
# (0.5-1.5x approx_size at fastcat; <=1.2x at the assembler) from silently re-clipping your window:
# keep ceil(max_len/1.2) <= approx_size <= 2*min_len.  AUTO is always in-envelope (window = peak
# +/-15%, approx_size = peak).
#
# Usage:
#   ./clone_validate.sh <raw_dir> <out_dir> <approx_size|auto> [min_len] [min_qual] [max_len]
#
# Env:
#   PROFILE   nextflow profile; auto: "singularity" if only apptainer is present, else "standard"
#   FORCE=1   bypass the approx_size guard (MANUAL only)
#   EXTRA_NF_ARGS  extra nextflow flags, e.g. "--assembly_tool flye --assm_coverage 60"
#   WF_VERSION     workflow revision (default v1.8.4)
#
# Examples:
#   # AUTO (recommended): data-driven per-sample sizing + canu
#   ./clone_validate.sh examples/plasmid/raw runs/cv_auto auto
#   ./clone_validate.sh examples/plasmid/raw runs/cv_auto auto "" 20      # set min Q (arg 5)
#   # MANUAL window (canu is still the default assembler)
#   ./clone_validate.sh examples/plasmid/raw runs/cv 5500 5000 20 6000
#   # force flye instead of the canu default
#   EXTRA_NF_ARGS="--assembly_tool flye" ./clone_validate.sh examples/plasmid/raw runs/cv 5500 5000 20 6000

set -euo pipefail
usage() { awk 'NR==1{next} /^#/{sub(/^# ?/,"");print;next} {exit}' "$0"; }

if [[ $# -lt 3 || "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then usage; exit 0; fi

RAW="$1"; OUT="$2"; APPROX="$3"
MINLEN="${4:-5000}"; MINQ="${5:-15}"; MAXLEN="${6:-6000}"
# PROFILE: auto-pick singularity inside the Apptainer-only devcontainer, else standard (Docker host).
if [[ -z "${PROFILE:-}" ]]; then
    if command -v apptainer >/dev/null 2>&1 && ! command -v docker >/dev/null 2>&1; then
        PROFILE=singularity
    else
        PROFILE=standard
    fi
fi
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILTER="$SCRIPT_DIR/filter_nanopore_reads.sh"
PEAKFINDER="$SCRIPT_DIR/estimate_length_peak.sh"

[[ -d "$RAW" ]] || { echo "ERROR: raw dir not found: $RAW" >&2; exit 1; }

# Resolve OUT to an ABSOLUTE path now. We 'cd "$OUT"' before launching Nextflow (step 3) so its
# launch-dir scratch (work/, .nextflow/, .nextflow.log) lands somewhere writable -- a standalone
# `docker run` starts in CWD '/', which the non-root runtime user cannot write, aborting the run
# before it starts. Absolute OUT keeps the relative "$OUT/..." paths below valid after the cd.
mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"

# --- Assembler default: canu (override via EXTRA_NF_ARGS="--assembly_tool flye") ---
# Canu reliably assembles full-length plasmid reads in every condition tested; flye auto-picks a
# min-overlap > the ~read length -> zero overlaps -> SIGFPE. See docs/assembly_findings_2026-06-21.md.
if [[ "${EXTRA_NF_ARGS:-}" != *"--assembly_tool"* ]]; then
    EXTRA_NF_ARGS="--assembly_tool canu ${EXTRA_NF_ARGS:-}"
fi
read -r -a EXTRA <<< "${EXTRA_NF_ARGS:-}"

NF_IN="$OUT/nf_input"; rm -rf "$NF_IN"; mkdir -p "$NF_IN"
shopt -s nullglob

if [[ "${APPROX,,}" == "auto" ]]; then
    # ===== AUTO: per-sample data-driven peak -> window + approx_size (via sample sheet) =====
    [[ -x "$PEAKFINDER" ]] || { echo "ERROR: $PEAKFINDER not found/executable" >&2; exit 1; }
    command -v seqkit >/dev/null 2>&1 || { echo "ERROR: seqkit not found on PATH (AUTO needs it)" >&2; exit 1; }
    SHEET="$OUT/sample_sheet.csv"
    CONCAT_DIR="$OUT/concat"; rm -rf "$CONCAT_DIR"; mkdir -p "$CONCAT_DIR"
    echo "barcode,alias,approx_size" > "$SHEET"
    echo "== clone_validate (AUTO: data-driven per-sample sizing) =="
    echo "raw=$RAW  out=$OUT  minQ=$MINQ  profile=$PROFILE  assembler args=[${EXTRA[*]}]"
    printf '%-14s %8s %8s %8s  %-12s\n' "barcode" "peak" "lo" "hi" "alias"
    n=0
    for bc_dir in "$RAW"/*/; do
        compgen -G "${bc_dir}*.fastq.gz" >/dev/null || continue
        bc="$(basename "$bc_dir")"
        # the wf-clone-validation sample sheet requires barcode like 'barcodeNN' (>=2 digits, all same length)
        if [[ ! "$bc" =~ ^barcode[0-9][0-9]+$ ]]; then
            echo "WARNING: subdir '$bc' is not in barcodeNN format the sample sheet requires -- skipping." >&2
            continue
        fi
        alias="sample${bc#barcode}"          # sample-sheet aliases must NOT start with 'barcode'
        concat="$CONCAT_DIR/${bc}.concat.fastq.gz"
        cat "${bc_dir}"*.fastq.gz > "$concat"
        mkdir -p "$NF_IN/$bc"
        # one call finds the peak AND writes the window-filtered (+ min Q) reads
        read -r _ PEAK LO HI < <("$PEAKFINDER" "$concat" --min-qual "$MINQ" -o "$NF_IN/$bc/reads.fastq.gz" 2>/dev/null | tail -1)
        [[ -n "${PEAK:-}" ]] || { echo "ERROR: peak estimation failed for $bc" >&2; exit 1; }
        printf '%-14s %8s %8s %8s  %-12s\n' "$bc" "$PEAK" "$LO" "$HI" "$alias"
        echo "${bc},${alias},${PEAK}" >> "$SHEET"
        n=$((n + 1))
    done
    (( n > 0 )) || { echo "ERROR: no barcodeNN samples found under $RAW" >&2; exit 1; }
    echo "Wrote sample sheet ($n sample(s)) -> $SHEET   (outputs are named by alias: sampleNN)"
    NF_CMD=(nextflow run epi2me-labs/wf-clone-validation -r "${WF_VERSION:-v1.8.4}"
            --fastq "$NF_IN" --sample_sheet "$SHEET" --min_quality "$MINQ"
            --out_dir "$OUT/cloneval" -profile "$PROFILE" "${EXTRA[@]}")
else
    # ===== MANUAL: one length window for all samples =====
    [[ -x "$FILTER" ]] || { echo "ERROR: $FILTER not found/executable" >&2; exit 1; }
    # approx_size envelope guard
    lo=1
    [[ -n "$MAXLEN" ]] && lo=$(( (10*MAXLEN + 11) / 12 ))   # ceil(max_len / 1.2)
    hi=$(( 2 * MINLEN ))
    if (( APPROX < lo || APPROX > hi )); then
        echo "WARNING: approx_size=$APPROX may let wf-clone-validation re-clip your [${MINLEN},${MAXLEN}] window." >&2
        echo "         Recommended approx_size range: [${lo}, ${hi}] (~ your true construct size, or use 'auto')." >&2
        if [[ "${FORCE:-0}" != "1" ]]; then
            echo "         Refusing to continue; re-run with FORCE=1 to override." >&2
            exit 1
        fi
    fi
    echo "== clone_validate =="
    echo "raw=$RAW  out=$OUT  approx_size=$APPROX  window=[${MINLEN},${MAXLEN}]  minQ=$MINQ  profile=$PROFILE"
    # 1) filter
    FILT="$OUT/filtered"
    "$FILTER" "$RAW" "$FILT" "$MINLEN" "$MINQ" "$MAXLEN"
    # 2) reshape filtered files -> barcodeNN/reads.fastq.gz
    n=0
    for f in "$FILT"/*.len*_q*.fastq.gz; do
        bc="$(basename "$f")"; bc="${bc%%.*}"     # barcodeNN
        mkdir -p "$NF_IN/$bc"
        cp "$f" "$NF_IN/$bc/reads.fastq.gz"
        n=$((n + 1))
    done
    (( n > 0 )) || { echo "ERROR: no filtered FASTQs produced" >&2; exit 1; }
    echo "Reshaped $n sample(s) into $NF_IN/"
    NF_CMD=(nextflow run epi2me-labs/wf-clone-validation -r "${WF_VERSION:-v1.8.4}"
            --fastq "$NF_IN" --approx_size "$APPROX" --min_quality "$MINQ"
            --out_dir "$OUT/cloneval" -profile "$PROFILE" "${EXTRA[@]}")
fi

# 3) run (or print) nextflow.  WF_VERSION pins the workflow release; EXTRA_NF_ARGS adds flags.
# Launch from $OUT (absolute, above) so Nextflow writes work/, .nextflow/ and .nextflow.log into a
# writable dir -- a standalone `docker run` starts in CWD '/', not writable by the non-root user.
if command -v nextflow >/dev/null 2>&1; then
    echo "+ ${NF_CMD[*]}"
    ( cd "$OUT" && "${NF_CMD[@]}" )

    # --- optional: Arabidopsis-aware annotation of the assembled plasmid(s) (opt-in) ---
    # A complete NO-OP unless ARAB_DB is set -> existing plasmid runs are unchanged. wf-clone-validation
    # already runs stock-DB pLannotate; this post-step ADDS custom A. thaliana proteome hits (AGI locus +
    # gene symbol + function) to each assembled plasmid consensus, mirroring the amplicon pipeline. Gated
    # on Apptainer too (the annotation is Apptainer-only), like amplicon_validate.sh's `command -v
    # apptainer` annotation gate. Runs annotate.sh with CIRCULAR=1 (plasmids are circular) into a SEPARATE
    # $OUT/annotation dir, so it never collides with the workflow's own cloneval/feature_table.txt.
    # See docs/arabidopsis_annotation_plan.md.
    if [[ -n "${ARAB_DB:-}" ]]; then
        if command -v apptainer >/dev/null 2>&1; then
            echo
            echo "== Arabidopsis annotation (pLannotate, circular) =="
            # Gather every assembled per-sample consensus (wf-clone-validation writes one
            # <alias>.final.fasta per successfully assembled sample under cloneval/) into one
            # multi-record FASTA; annotate.sh re-splits it by record header (= alias).
            ANNOT_FA="$OUT/annotation_input.fasta"; : > "$ANNOT_FA"; nfa=0
            for fa in "$OUT/cloneval"/*.final.fasta; do
                [[ -e "$fa" ]] || continue          # nullglob is on; guard is belt-and-suspenders
                cat "$fa" >> "$ANNOT_FA"; nfa=$((nfa + 1))
            done
            if (( nfa > 0 )); then
                echo "  annotating $nfa assembled plasmid consensus record(s) from $OUT/cloneval/"
                if CIRCULAR=1 ARAB_DB="$ARAB_DB" \
                       "$SCRIPT_DIR/amplicon_annotate/annotate.sh" "$ANNOT_FA" "$OUT/annotation"; then
                    echo
                    echo "  Arabidopsis-aware annotation -> $OUT/annotation/"
                    echo "    feature table : $OUT/annotation/feature_table.txt"
                    echo "    per-sample    : $OUT/annotation/<alias>.annotations.{gbk,bed}  (AGI folded into /label)"
                    echo "    HTML report   : $OUT/annotation/amplicon-annotation-report.html"
                else
                    echo "WARNING: Arabidopsis annotation failed; wf-clone-validation outputs in $OUT/cloneval are intact." >&2
                fi
            else
                rm -f "$ANNOT_FA"
                echo "  NOTE: no assembled consensus (*.final.fasta) under $OUT/cloneval -- nothing to annotate."
                echo "        (Check $OUT/cloneval/sample_status.txt for per-sample assembly status.)"
            fi
        else
            echo
            echo "  NOTE: ARAB_DB set, but Arabidopsis annotation needs Apptainer (skipped on this host)."
            echo "        Run inside the Apptainer runtime image to add AGI locus + gene + function."
        fi
    fi
else
    echo
    echo "nextflow not found here (expected inside the sandboxed devcontainer)."
    echo "Filtered + reshaped input is ready at: $NF_IN"
    echo "Run this where Docker/Apptainer + nextflow are available:"
    echo "  ${NF_CMD[*]}"
fi
