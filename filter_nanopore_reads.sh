#!/usr/bin/env bash
#
# filter_nanopore_reads.sh
# ------------------------
# Concatenate per-barcode Oxford Nanopore FASTQs and select reads by
# length (min, and optional max) and minimum mean read quality (Q-score).
#
# For every  <barcode>/  subdirectory inside the input directory it:
#   1. concatenates all *.fastq.gz in that barcode  ->  <barcode>.concat.fastq.gz
#   2. keeps reads with  length >= MIN_LEN  (and <= MAX_LEN if given)  AND  mean Q >= MIN_QUAL
#                                            ->  <barcode>.len<L>_q<Q>.fastq.gz
#   3. verifies that no surviving read is outside the requested window
#
# Why seqkit: seqkit (v2.9+) computes each read's average quality as the
# Nanopore error-probability mean,  Q_read = -10*log10(mean(10^(-Q_base/10))),
# i.e. the same number Dorado / MinKNOW report. So `seqkit seq --min-qual`
# is the correct way to filter Nanopore reads by Q-score (a naive arithmetic
# mean of Phred values would over-estimate quality). All thresholds are inclusive.
#
# Usage:
#   ./filter_nanopore_reads.sh <input_dir> <output_dir> [min_len] [min_qual] [max_len]
#       min_len   default 5000   (bp)
#       min_qual  default 20      (mean read Q-score)
#       max_len   optional        (bp; omit for no upper bound)
#
# Optional environment variables:
#       THREADS         compression/IO threads for seqkit   (default 8)
#       REMOVE_CONCAT   "true" deletes the .concat.fastq.gz intermediates (default false)
#
# Examples:
#   # min-length only (>= 11 kb, Q>=20)
#   ./filter_nanopore_reads.sh plasmid_raw_260612 plasmid_filtered_260612 11000 20
#   # length window (5-6 kb, Q>=20)
#   ./filter_nanopore_reads.sh plasmid_raw_260618 plasmid_filtered_260618 5000 20 6000

set -euo pipefail

usage() { awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; }

# ---- arguments ------------------------------------------------------------
if [[ $# -lt 2 || "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

INPUT_DIR="$1"
OUTPUT_DIR="$2"
MIN_LEN="${3:-5000}"
MIN_QUAL="${4:-20}"
MAX_LEN="${5:-}"                       # empty = no upper bound
THREADS="${THREADS:-8}"
REMOVE_CONCAT="${REMOVE_CONCAT:-false}"

# ---- sanity checks --------------------------------------------------------
command -v seqkit >/dev/null 2>&1 || { echo "ERROR: seqkit not found on PATH" >&2; exit 1; }
[[ -d "$INPUT_DIR" ]] || { echo "ERROR: input dir not found: $INPUT_DIR" >&2; exit 1; }
if [[ -n "$MAX_LEN" && "$MAX_LEN" -lt "$MIN_LEN" ]]; then
    echo "ERROR: max_len ($MAX_LEN) is less than min_len ($MIN_LEN)" >&2; exit 1
fi

# bp -> human label for filenames: 5000->5kb, 6000->6kb, 5500->5500bp
len_label() { local n="$1"; if (( n % 1000 == 0 )); then echo "$((n / 1000))kb"; else echo "${n}bp"; fi; }
LABEL="len$(len_label "$MIN_LEN")"
[[ -n "$MAX_LEN" ]] && LABEL="${LABEL}-$(len_label "$MAX_LEN")"

mkdir -p "$OUTPUT_DIR"

if [[ -n "$MAX_LEN" ]]; then win="${MIN_LEN} <= length <= ${MAX_LEN} bp"; else win="length >= ${MIN_LEN} bp"; fi
echo "Input   : $INPUT_DIR"
echo "Output  : $OUTPUT_DIR"
echo "Keep    : ${win}  AND  mean Q >= ${MIN_QUAL}   (inclusive)"
echo "Threads : $THREADS"
echo

# ---- per-barcode loop -----------------------------------------------------
status=0
printf '%-14s %9s %7s %8s %9s %9s %6s\n' "barcode" "reads_in" "kept" "kept%" "shortest" "longest" "minQ"
printf '%-14s %9s %7s %8s %9s %9s %6s\n' "-------" "--------" "----" "-----" "--------" "-------" "----"

for bc_dir in "$INPUT_DIR"/*/; do
    [[ -d "$bc_dir" ]] || continue
    compgen -G "${bc_dir}*.fastq.gz" >/dev/null || continue   # skip dirs with no reads
    bc="$(basename "$bc_dir")"

    concat="$OUTPUT_DIR/${bc}.concat.fastq.gz"
    filt="$OUTPUT_DIR/${bc}.${LABEL}_q${MIN_QUAL}.fastq.gz"

    # 1. concatenate (concatenated gzip streams remain a valid gzip; seqkit reads it natively)
    cat "${bc_dir}"*.fastq.gz > "$concat"

    # 2. filter on length window AND mean quality in a single pass
    seqkit_args=(--min-len "$MIN_LEN" --min-qual "$MIN_QUAL")
    [[ -n "$MAX_LEN" ]] && seqkit_args+=(--max-len "$MAX_LEN")
    seqkit seq "${seqkit_args[@]}" -j "$THREADS" "$concat" -o "$filt" 2>/dev/null

    # 3. verify and gather numbers  (U=0 means "no upper bound")
    reads_in="$(seqkit stats -T "$concat" 2>/dev/null | awk 'NR==2{print $4}')"
    read -r kept shortest longest minq bad < <(
        seqkit fx2tab -q -l -i -n "$filt" 2>/dev/null \
        | awk -F'\t' -v L="$MIN_LEN" -v Q="$MIN_QUAL" -v U="${MAX_LEN:-0}" '
            NR==1 { sl=$2; ml=$2; sq=$3 }
            { n++; if($2<sl) sl=$2; if($2>ml) ml=$2; if($3<sq) sq=$3;
              if($2<L || $3<Q || (U>0 && $2>U)) bad++ }
            END   { printf "%d %d %d %.2f %d\n", n+0, sl+0, ml+0, sq+0, bad+0 }')
    pct="$(awk -v k="$kept" -v t="$reads_in" 'BEGIN{ if(t>0) printf "%.1f%%", 100*k/t; else print "NA" }')"

    printf '%-14s %9s %7s %8s %9s %9s %6s\n' "$bc" "$reads_in" "$kept" "$pct" "$shortest" "$longest" "$minq"
    if [[ "${bad:-0}" -ne 0 ]]; then
        echo "  !! ${bad} read(s) outside the requested window in $filt" >&2
        status=1
    fi
    [[ "$REMOVE_CONCAT" == "true" ]] && rm -f "$concat"
done

echo
if [[ "$status" -eq 0 ]]; then
    echo "OK - every kept read satisfies ${win} and mean Q >= ${MIN_QUAL}."
    echo "Filtered reads: $OUTPUT_DIR/*.${LABEL}_q${MIN_QUAL}.fastq.gz"
else
    echo "FAILED - some reads were outside the requested window (see warnings above)." >&2
fi
exit "$status"
