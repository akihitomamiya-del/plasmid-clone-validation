#!/usr/bin/env bash
#
# amplicon_validate.sh
# --------------------
# Pre-filter wrapper for EPI2ME wf-amplicon -- the amplicon sibling of clone_validate.sh.
# It selects/concatenates Oxford Nanopore amplicon reads, reshapes them into the barcodeNN/
# layout wf-amplicon expects, then runs (or prints) the workflow.
#
# Modes:
#   * DE-NOVO (default)   one amplicon per barcode; wf-amplicon builds a single consensus per
#                         sample (no reference). This is the supported, tested path today.
#   * REFERENCE (FUTURE)  set REF=<multi.fasta> to pass --reference, so wf-amplicon variant-calls
#                         several DISTINCT-locus amplicons pooled in one barcode (separated by
#                         mapping). We have no data of this type yet -- kept as an off-by-default
#                         hook. See docs/amplicon_plan.md.
#
# Medaka model: by DEFAULT wf-amplicon AUTO-SELECTS the polishing model from the basecaller
#   config embedded in your reads (MinKNOW sup writes it into the FASTQ headers) -- you do not
#   specify it. Offline, that model's weights must be baked in the medaka SIF (the build prints
#   the bundled models so you can confirm). Set OVERRIDE_BASECALLER_CFG=<model> to pin one as a
#   fallback (e.g. if headers were stripped or the auto-picked model is not bundled).
#
# After wf-amplicon, this wrapper runs the annotation post-step (amplicon_annotate/annotate.sh)
#   when a consensus was produced and Apptainer is present -- Stages 3-5: pLannotate (linear)
#   annotation, the annotation-only HTML report, and a merge into the wf-amplicon report to produce
#   ONE COMBINED report (amplicon-report-with-annotation.html). See docs/amplicon_annotate.md.
#
# Usage:
#   ./amplicon_validate.sh <raw_dir> <out_dir> [filter_mode] [min_len] [min_qual] [max_len]
#     filter_mode : none (default) | minlen | window
#     min_len     default 300   (matches wf-amplicon --min_read_length)
#     min_qual    default 10    (matches wf-amplicon --min_read_qual)
#     max_len     optional      (window mode only)
#
# Env:
#   PROFILE                 nextflow profile; auto: "singularity" if only apptainer is present, else "standard"
#   WF_VERSION              wf-amplicon revision (default v1.2.2)
#   REF                     path to a multi-FASTA reference -> reference/variant-calling mode (FUTURE)
#   OVERRIDE_BASECALLER_CFG pin the medaka model (default: auto-detect from the reads)
#   EXTRA_NF_ARGS           extra nextflow flags, e.g. "--drop_frac_longest_reads 0"
#
# Examples:
#   ./amplicon_validate.sh example_amplicon runs/amp                  # de-novo, no pre-filter
#   ./amplicon_validate.sh example_amplicon runs/amp window 800 12 3500
#   OVERRIDE_BASECALLER_CFG=dna_r10.4.1_e8.2_400bps_sup@v5.0.0 \
#       ./amplicon_validate.sh example_amplicon runs/amp

set -euo pipefail
usage() { awk 'NR==1{next} /^#/{sub(/^# ?/,"");print;next} {exit}' "$0"; }

if [[ $# -lt 2 || "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then usage; exit 0; fi

RAW="$1"; OUT="$2"; FILTER_MODE="${3:-none}"
MINLEN="${4:-300}"; MINQ="${5:-10}"; MAXLEN="${6:-}"

# PROFILE: auto-pick singularity inside the Apptainer-only runtime, else standard (Docker host).
if [[ -z "${PROFILE:-}" ]]; then
    if command -v apptainer >/dev/null 2>&1 && ! command -v docker >/dev/null 2>&1; then
        PROFILE=singularity
    else
        PROFILE=standard
    fi
fi
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILTER="$SCRIPT_DIR/filter_nanopore_reads.sh"

[[ -d "$RAW" ]] || { echo "ERROR: raw dir not found: $RAW" >&2; exit 1; }

# Resolve OUT to an ABSOLUTE path now. We 'cd "$OUT"' before launching Nextflow (step 3) so its
# launch-dir scratch (work/, .nextflow/, .nextflow.log) lands somewhere writable -- a standalone
# `docker run` starts in CWD '/', which the non-root runtime user cannot write, aborting the run
# before it starts. Absolute OUT keeps the relative "$OUT/..." paths below valid after the cd.
mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"

# --- Mode selection: REF=<multi.fasta> -> reference/variant-calling (FUTURE); else de-novo ---
REF="${REF:-}"
if [[ -n "$REF" ]]; then
    [[ -f "$REF" ]] || { echo "ERROR: REF not found: $REF" >&2; exit 1; }
    MODE="reference"
    echo "WARNING: reference/multiplex mode is a FUTURE, untested path (no data of this type yet)." >&2
else
    MODE="de-novo"
    # de-novo is selected by the ABSENCE of --reference; reject a smuggled one (it would switch modes).
    if [[ "${EXTRA_NF_ARGS:-}" == *"--reference"* ]]; then
        echo "ERROR: de-novo mode: don't put --reference in EXTRA_NF_ARGS (use REF=<fasta> for reference mode)." >&2
        exit 1
    fi
fi

read -r -a EXTRA <<< "${EXTRA_NF_ARGS:-}"
# Pin the medaka model only if asked; otherwise wf-amplicon auto-detects it from the read headers.
if [[ -n "${OVERRIDE_BASECALLER_CFG:-}" ]]; then
    EXTRA+=(--override_basecaller_cfg "${OVERRIDE_BASECALLER_CFG}")
fi

NF_IN="$OUT/nf_input"; rm -rf "$NF_IN"; mkdir -p "$NF_IN"
shopt -s nullglob

echo "== amplicon_validate =="
echo "raw=$RAW  out=$OUT  mode=$MODE  filter=$FILTER_MODE  minLen=$MINLEN  minQ=$MINQ  maxLen=${MAXLEN:-none}  profile=$PROFILE"

# 1) prepare reads into NF_IN/barcodeNN/reads.fastq.gz
n=0
if [[ "$FILTER_MODE" == "none" ]]; then
    # No pre-filter: concat raw reads per barcode (preserves FASTQ headers -> medaka auto-model works).
    for bc_dir in "$RAW"/*/; do
        compgen -G "${bc_dir}*.fastq.gz" >/dev/null || continue
        bc="$(basename "$bc_dir")"
        if [[ ! "$bc" =~ ^barcode[0-9][0-9]+$ ]]; then
            echo "WARNING: subdir '$bc' is not in barcodeNN format -- skipping." >&2; continue
        fi
        mkdir -p "$NF_IN/$bc"
        cat "${bc_dir}"*.fastq.gz > "$NF_IN/$bc/reads.fastq.gz"
        n=$((n + 1))
    done
else
    # Optional pre-filter via the shared generic length/Q filter (filter_nanopore_reads.sh).
    [[ -x "$FILTER" ]] || { echo "ERROR: $FILTER not found/executable" >&2; exit 1; }
    case "$FILTER_MODE" in
        minlen) "$FILTER" "$RAW" "$OUT/filtered" "$MINLEN" "$MINQ" ;;
        window) [[ -n "$MAXLEN" ]] || { echo "ERROR: window mode needs max_len (arg 6)." >&2; exit 1; }
                "$FILTER" "$RAW" "$OUT/filtered" "$MINLEN" "$MINQ" "$MAXLEN" ;;
        *)      echo "ERROR: filter_mode must be none|minlen|window (got '$FILTER_MODE')." >&2; exit 1 ;;
    esac
    for f in "$OUT/filtered"/*.len*_q*.fastq.gz; do
        bc="$(basename "$f")"; bc="${bc%%.*}"     # barcodeNN
        mkdir -p "$NF_IN/$bc"
        cp "$f" "$NF_IN/$bc/reads.fastq.gz"
        n=$((n + 1))
    done
fi
(( n > 0 )) || { echo "ERROR: no barcodeNN samples prepared under $RAW" >&2; exit 1; }
echo "Prepared $n sample(s) -> $NF_IN/"

# 2) build the nextflow command (de-novo: NO --reference; reference mode adds it)
NF_CMD=(nextflow run epi2me-labs/wf-amplicon -r "${WF_VERSION:-v1.2.2}"
        --fastq "$NF_IN"
        --min_read_length "$MINLEN" --min_read_qual "$MINQ"
        --out_dir "$OUT/amplicon" -profile "$PROFILE")
[[ "$MODE" == "reference" ]] && NF_CMD+=(--reference "$REF")
NF_CMD+=("${EXTRA[@]}")

# 3) run (or print) nextflow.  Launch from $OUT (absolute, above) so Nextflow writes work/,
#    .nextflow/ and .nextflow.log into a writable dir -- the container CWD is '/' (not writable by
#    the non-root runtime user), which would otherwise abort the run before it starts.
if command -v nextflow >/dev/null 2>&1; then
    echo "+ ${NF_CMD[*]}"
    ( cd "$OUT" && "${NF_CMD[@]}" )
    echo
    echo "== outputs =="
    echo "  workflow report : $OUT/amplicon/wf-amplicon-report.html"
    echo "  consensus (all) : $OUT/amplicon/all-consensus-seqs.fasta"
    echo "  per-sample      : $OUT/amplicon/<alias>/consensus/consensus.fastq"
    # Stage 3-5: pLannotate (linear) BLAST annotation, its HTML report, and a
    #            COMBINED report = the wf-amplicon report with the annotation spliced in.
    CONS="$OUT/amplicon/all-consensus-seqs.fasta"
    if [[ -s "$CONS" ]] && command -v apptainer >/dev/null 2>&1; then
        echo
        echo "== annotation (pLannotate, linear) =="
        if "$SCRIPT_DIR/amplicon_annotate/annotate.sh" "$CONS" "$OUT/annotation" \
               "$OUT/amplicon/params.json" "$OUT/amplicon/versions.txt" \
               "$OUT/amplicon/wf-amplicon-report.html"; then
            COMBINED="$OUT/annotation/amplicon-report-with-annotation.html"
            if [[ -f "$COMBINED" ]]; then
                echo "  combined report  : $COMBINED   <- wf-amplicon report + annotation"
            fi
            echo "  annotation report: $OUT/annotation/amplicon-annotation-report.html"
        else
            echo "WARNING: annotation step failed; wf-amplicon consensus/QC remain in $OUT/amplicon." >&2
        fi
    elif [[ -s "$CONS" ]]; then
        echo "Consensus ready; annotation needs Apptainer (skipped on this host) -- see docs/amplicon_plan.md."
    else
        echo "No consensus produced -> skipping annotation."
    fi
else
    echo
    echo "nextflow not found here (expected inside the runtime image / devcontainer)."
    echo "Reshaped input is ready at: $NF_IN"
    echo "Run this where Nextflow + Apptainer (or Docker) are available:"
    echo "  ${NF_CMD[*]}"
fi
